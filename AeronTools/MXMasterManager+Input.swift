import AppKit
import CoreGraphics
import Carbon.HIToolbox

extension MXMasterManager {
    // MARK: - Event Tap (Scrolling, Thumbwheel, Buttons & Hold-Drag Gestures)

    private var needsEventTap: Bool {
        config.standardVerticalScroll
            || config.smoothScrolling
            || config.invertThumbwheel
            || config.thumbwheelAction != .horizontalScroll
            || config.middleButtonAction != .systemDefault
            || config.backButtonAction != .systemDefault
            || config.forwardButtonAction != .systemDefault
            || config.gestureButtonClickAction != .systemDefault
            || config.gesturesEnabled
    }

    func updateEventTapState() {
        if needsEventTap {
            startEventTapIfNeeded()
        } else {
            stopEventTap()
        }
    }

    private func startEventTapIfNeeded() {
        guard eventTap == nil else { return }
        // Started again from the permission change handler once the user grants access.
        guard AccessibilityPermission.shared.isGranted else { return }

        let mask: CGEventMask =
            (1 << CGEventType.scrollWheel.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mxMasterEventTapCallback,
            userInfo: nil
        ) else {
            dlog("Failed to create MX Master event tap")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.eventTap = tap
        self.runLoopSource = source

        let gestureMask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)
        if let gestureTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: gestureMask,
            callback: mxMasterEventTapCallback,
            userInfo: nil
        ) {
            CGEvent.tapEnable(tap: gestureTap, enable: false)
            let gestureSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gestureTap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), gestureSource, .commonModes)
            self.gestureTap = gestureTap
            self.gestureRunLoopSource = gestureSource
        }
    }

    private func setGestureTapEnabled(_ enabled: Bool) {
        if let gestureTap {
            CGEvent.tapEnable(tap: gestureTap, enable: enabled)
        }
    }

    /// Clears a stuck hold (e.g. the mouse disconnected mid-gesture) so the cursor is never left frozen.
    func releaseGestureHoldIfNeeded() {
        guard isGestureButtonHeld else { return }
        isGestureButtonHeld = false
        gestureTriggeredDuringHold = false
        gestureAccumulatedDelta = .zero
        setGestureTapEnabled(false)
    }

    func stopEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let gestureTap {
            CGEvent.tapEnable(tap: gestureTap, enable: false)
        }
        if let gestureRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), gestureRunLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        gestureTap = nil
        gestureRunLoopSource = nil
        isGestureButtonHeld = false
    }

    fileprivate func reenableTapAfterTimeout() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        setGestureTapEnabled(isGestureButtonHeld && config.gesturesEnabled)
    }

    // MARK: - Event Handling Logic

    private static let syntheticEventMarker: Int64 = 0x4D58_4D34 // 'MXM4'

    fileprivate func handleCGEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        // Never re-process synthetic events posted by our own smooth scroller or button synthesizer
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return passThrough
        }

        switch type {
        case .scrollWheel:
            return handleScrollWheelEvent(event)

        case .otherMouseDown, .otherMouseUp:
            let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
            let isDown = (type == .otherMouseDown)
            return handleOtherMouseButton(buttonNumber: Int(buttonNumber), isDown: isDown, event: event)

        case .otherMouseDragged, .mouseMoved:
            if isGestureButtonHeld && config.gesturesEnabled {
                let dx = CGFloat(event.getDoubleValueField(.mouseEventDeltaX))
                let dy = CGFloat(event.getDoubleValueField(.mouseEventDeltaY))
                processGestureDragDelta(dx: dx, dy: dy)
                return nil // Freeze cursor while performing a hold-and-drag gesture
            }
            return passThrough

        default:
            return passThrough
        }
    }

    private func handleScrollWheelEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        // Continuous scroll events come from the built-in Trackpad or Magic Mouse; only transform discrete wheel ticks!
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        guard !isContinuous else { return passThrough }

        var axis1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1) // Vertical wheel
        var axis2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2) // Horizontal thumbwheel

        // 1. Handle Horizontal Thumbwheel
        if axis2 != 0 {
            if config.invertThumbwheel {
                axis2 = -axis2
            }

            switch config.thumbwheelAction {
            case .horizontalScroll:
                event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: axis2)
                let ptX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
                if ptX != 0 && config.invertThumbwheel {
                    event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: -ptX)
                }

            case .displayBrightness:
                let key: MediaKey = axis2 > 0 ? .brightnessUp : .brightnessDown
                if let displayID = NSScreen.underPointer?.displayID {
                    _ = DisplayStateModel.shared.handleMediaKey(key, on: displayID)
                }
                if axis1 == 0 { return nil }

            case .displayVolume:
                let key: MediaKey = axis2 > 0 ? .volumeUp : .volumeDown
                if let displayID = NSScreen.underPointer?.displayID {
                    _ = DisplayStateModel.shared.handleMediaKey(key, on: displayID)
                }
                if axis1 == 0 { return nil }

            case .switchSpaces:
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastSpaceOrTabSwitchTime > 0.28 {
                    lastSpaceOrTabSwitchTime = now
                    performButtonAction(axis2 > 0 ? .spaceRight : .spaceLeft)
                }
                if axis1 == 0 { return nil }

            case .switchTabs:
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastSpaceOrTabSwitchTime > 0.16 {
                    lastSpaceOrTabSwitchTime = now
                    // ⇧⌘] (next tab) or ⇧⌘[ (previous tab)
                    let keyCode = UInt16(axis2 > 0 ? kVK_ANSI_RightBracket : kVK_ANSI_LeftBracket)
                    postKeyCombo(keyCode: keyCode, flags: [.maskCommand, .maskShift])
                }
                if axis1 == 0 { return nil }

            case .zoom:
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastSpaceOrTabSwitchTime > 0.12 {
                    lastSpaceOrTabSwitchTime = now
                    let keyCode = UInt16(axis2 > 0 ? kVK_ANSI_Equal : kVK_ANSI_Minus)
                    postKeyCombo(keyCode: keyCode, flags: [.maskCommand])
                }
                if axis1 == 0 { return nil }
            }
        }

        // 2. Handle Vertical Scroll Wheel (Direction & Smooth Scrolling)
        if axis1 != 0 {
            if config.standardVerticalScroll {
                axis1 = -axis1
            }

            if config.smoothScrolling {
                enqueueSmoothScroll(verticalTicks: Double(axis1) * config.scrollSpeedMultiplier)
                return nil
            } else {
                let scaled = Int64((Double(axis1) * config.scrollSpeedMultiplier).rounded())
                let finalAxis1 = scaled == 0 ? (axis1 > 0 ? 1 : -1) : scaled
                event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: finalAxis1)
                let ptY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
                if ptY != 0 {
                    let sign: Double = config.standardVerticalScroll ? -1.0 : 1.0
                    event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: ptY * sign * config.scrollSpeedMultiplier)
                }
            }
        }

        return passThrough
    }

    private func enqueueSmoothScroll(verticalTicks: Double) {
        // Each discrete mouse notch adds pixel velocity (~26 px per tick) decayed smoothly at 120 Hz
        smoothScrollVelocityY += verticalTicks * 9.5
        guard smoothScrollTimer == nil else { return }

        smoothScrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stepSmoothScroll()
            }
        }
    }

    private func stepSmoothScroll() {
        if abs(smoothScrollVelocityY) < 0.45 {
            smoothScrollVelocityY = 0
            smoothScrollTimer?.invalidate()
            smoothScrollTimer = nil
            return
        }

        let stepPixels = Int32(smoothScrollVelocityY.rounded())
        smoothScrollVelocityY *= 0.84 // Smooth exponential momentum decay

        guard stepPixels != 0,
              let src = CGEventSource(stateID: .hidSystemState),
              let scrollEvent = CGEvent(
                  scrollWheelEvent2Source: src,
                  units: .pixel,
                  wheelCount: 1,
                  wheel1: stepPixels,
                  wheel2: 0,
                  wheel3: 0
              ) else { return }

        scrollEvent.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        scrollEvent.post(tap: .cgSessionEventTap)
    }

    private func handleOtherMouseButton(buttonNumber: Int, isDown: Bool, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        switch buttonNumber {
        case 2: // Middle Button (Wheel click)
            guard config.middleButtonAction != .systemDefault else { return passThrough }
            if isDown {
                performButtonAction(config.middleButtonAction)
            }
            return nil

        case 3: // Back Button
            guard config.backButtonAction != .systemDefault else { return passThrough }
            if isDown {
                performButtonAction(config.backButtonAction)
            }
            return nil

        case 4: // Forward Button
            guard config.forwardButtonAction != .systemDefault else { return passThrough }
            if isDown {
                performButtonAction(config.forwardButtonAction)
            }
            return nil

        case 5, 6: // Thumb / Gesture Button (when exposed as standard HID button 5/6)
            if config.gesturesEnabled {
                handleDivertedGestureButtonState(isDown: isDown)
                return nil
            }
            guard config.gestureButtonClickAction != .systemDefault else { return passThrough }
            if isDown {
                performButtonAction(config.gestureButtonClickAction)
            }
            return nil

        default:
            return passThrough
        }
    }

    func handleDivertedGestureButtonState(isDown: Bool) {
        if isDown {
            isGestureButtonHeld = true
            gestureTriggeredDuringHold = false
            gestureAccumulatedDelta = .zero
            setGestureTapEnabled(config.gesturesEnabled)
        } else {
            let wasHeld = isGestureButtonHeld
            let didDrag = gestureTriggeredDuringHold
            isGestureButtonHeld = false
            gestureTriggeredDuringHold = false
            gestureAccumulatedDelta = .zero
            setGestureTapEnabled(false)

            if wasHeld && !didDrag {
                performButtonAction(config.gestureButtonClickAction)
            }
        }
    }

    private func processGestureDragDelta(dx: CGFloat, dy: CGFloat) {
        guard !gestureTriggeredDuringHold else { return }
        gestureAccumulatedDelta.x += dx
        gestureAccumulatedDelta.y += dy

        let absX = abs(gestureAccumulatedDelta.x)
        let absY = abs(gestureAccumulatedDelta.y)
        guard max(absX, absY) >= gestureDragThreshold else { return }

        gestureTriggeredDuringHold = true
        if absY >= absX {
            // Screen coordinates: negative dy is moving mouse UP, positive dy is moving mouse DOWN
            if gestureAccumulatedDelta.y < 0 {
                performButtonAction(config.gestureUpAction)
            } else {
                performButtonAction(config.gestureDownAction)
            }
        } else {
            if gestureAccumulatedDelta.x < 0 {
                performButtonAction(config.gestureLeftAction)
            } else {
                performButtonAction(config.gestureRightAction)
            }
        }
    }

    // MARK: - Action Execution

    public func performButtonAction(_ action: MXButtonAction) {
        switch action {
        case .systemDefault:
            break
        case .missionControl:
            openSystemAction(appNamed: "Mission Control", fallbackKeyCode: UInt16(kVK_UpArrow), fallbackFlags: [.maskControl])
        case .appExpose:
            postSymbolicHotKey(SymbolicHotKey.appExpose, fallbackKeyCode: UInt16(kVK_DownArrow), fallbackFlags: [.maskControl])
        case .showDesktop:
            postSymbolicHotKey(SymbolicHotKey.showDesktop, fallbackKeyCode: UInt16(kVK_F11), fallbackFlags: [])
        case .launchpad:
            openSystemAction(appNamed: "Launchpad", fallbackKeyCode: UInt16(kVK_F4), fallbackFlags: [])
        case .spaceLeft:
            postSymbolicHotKey(SymbolicHotKey.moveLeftASpace, fallbackKeyCode: UInt16(kVK_LeftArrow), fallbackFlags: [.maskControl])
        case .spaceRight:
            postSymbolicHotKey(SymbolicHotKey.moveRightASpace, fallbackKeyCode: UInt16(kVK_RightArrow), fallbackFlags: [.maskControl])
        case .navigateBack:
            postKeyCombo(keyCode: UInt16(kVK_ANSI_LeftBracket), flags: [.maskCommand])
        case .navigateForward:
            postKeyCombo(keyCode: UInt16(kVK_ANSI_RightBracket), flags: [.maskCommand])
        case .playPause:
            postMediaKey(nxKeyType: 16) // NX_KEYTYPE_PLAY
        case .mutePointerDisplay:
            if let displayID = NSScreen.underPointer?.displayID {
                _ = DisplayStateModel.shared.handleMediaKey(.mute, on: displayID)
            }
        case .toggleMacBookScreen:
            DisplayStateModel.shared.toggleBuiltinDisplay()
        case .toggleCaffeine:
            DisplayStateModel.shared.toggleCaffeine()
        case .toggleWheelMode:
            toggleWheelMode()
        case .copy:
            postKeyCombo(keyCode: UInt16(kVK_ANSI_C), flags: [.maskCommand])
        case .paste:
            postKeyCombo(keyCode: UInt16(kVK_ANSI_V), flags: [.maskCommand])
        }
    }

    private func openSystemAction(appNamed: String, fallbackKeyCode: UInt16, fallbackFlags: CGEventFlags) {
        let path = "/System/Applications/\(appNamed).app"
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else {
            postKeyCombo(keyCode: fallbackKeyCode, flags: fallbackFlags)
        }
    }

    /// IDs of Mission Control shortcuts in `com.apple.symbolichotkeys` (System Settings → Keyboard Shortcuts).
    private enum SymbolicHotKey {
        static let appExpose = 33
        static let showDesktop = 36
        static let moveLeftASpace = 79
        static let moveRightASpace = 81
    }

    /// Posts the shortcut the user has actually assigned to a system action, since WindowServer only reacts to
    /// the configured combination. Falls back to the macOS default when the entry has never been customized.
    private func postSymbolicHotKey(_ id: Int, fallbackKeyCode: UInt16, fallbackFlags: CGEventFlags) {
        let hotKeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        guard let entry = hotKeys?[String(id)] as? [String: Any] else {
            postKeyCombo(keyCode: fallbackKeyCode, flags: fallbackFlags)
            return
        }
        // A disabled shortcut can't be triggered at all; WindowServer would ignore any synthesized keystroke.
        if let enabled = entry["enabled"] as? Bool, !enabled {
            dlog("MX Master: system shortcut \(id) is disabled in Keyboard Shortcuts")
            return
        }
        // parameters = (character, virtual key code, modifier mask using NSEvent/CGEventFlags bit positions)
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Int],
              parameters.count >= 3,
              parameters[1] != 0xFFFF else {
            postKeyCombo(keyCode: fallbackKeyCode, flags: fallbackFlags)
            return
        }
        postKeyCombo(keyCode: UInt16(parameters[1]), flags: CGEventFlags(rawValue: UInt64(parameters[2])))
    }

    private func postKeyCombo(keyCode: UInt16, flags: CGEventFlags) {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
            return
        }
        // Real arrow key presses carry the Fn + NumericPad flags; without them the WindowServer ignores
        // synthesized ⌃← / ⌃→ / ⌃↓ (Space switching, App Exposé).
        let arrowKeys: Set<Int> = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
        var effectiveFlags = flags
        if arrowKeys.contains(Int(keyCode)) {
            effectiveFlags.formUnion([.maskSecondaryFn, .maskNumericPad])
        }
        down.flags = effectiveFlags
        up.flags = effectiveFlags
        down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postMediaKey(nxKeyType: Int) {
        for isDown in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: isDown ? 0xA00 : 0xB00)
            let data1 = (nxKeyType << 16) | (isDown ? (0xA << 8) : (0xB << 8))
            if let nsEvent = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) {
                nsEvent.cgEvent?.post(tap: .cghidEventTap)
            }
        }
    }
}

// MARK: - Event Tap C Callback

private nonisolated func mxMasterEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated {
            MXMasterManager.shared.reenableTapAfterTimeout()
        }
        return Unmanaged.passUnretained(event)
    }

    return MainActor.assumeIsolated {
        MXMasterManager.shared.handleCGEvent(type: type, event: event)
    }
}
