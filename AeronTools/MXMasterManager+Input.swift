import AppKit
import CoreGraphics
import Carbon.HIToolbox

extension MXMasterManager {
    // MARK: - Device-Exclusive Input (HID++ Diversion)
    //
    // Every MX input feature is diverted to this app over HID++: the mouse sends those controls to Aeron Tools
    // instead of to macOS, and the app acts on them. Nothing is intercepted system-wide, so other mice are never
    // affected, and a control left at its default isn't diverted at all.

    private var divertsWheel: Bool {
        config.standardVerticalScroll || config.smoothScrolling || config.scrollSpeedMultiplier != 1.0
    }

    private var divertsThumbwheel: Bool {
        config.invertThumbwheel || config.thumbwheelAction != .horizontalScroll
    }

    /// Pushes the current settings to the mouse. Called when its features are resolved, when it reconnects,
    /// after wake, and whenever the settings change. Every packet is idempotent.
    func applyInputDiversion() {
        configureDivertedButtonsIfNeeded()
        if let index = featureTable[HIDPPProtocol.featureHiResWheel] {
            sendHIDPPPacket(HIDPPProtocol.setWheelModePacket(
                deviceIndex: activeDeviceIndex, featureIndex: index, diverted: divertsWheel
            ))
        }
        if let index = featureTable[HIDPPProtocol.featureThumbwheel] {
            sendHIDPPPacket(HIDPPProtocol.setThumbwheelReportingPacket(
                deviceIndex: activeDeviceIndex, featureIndex: index, diverted: divertsThumbwheel
            ))
        }
    }

    /// Hands every control back to macOS so the mouse works normally once the app has quit.
    func releaseInputDiversion() {
        configureDivertedButtonsIfNeeded(releasingAll: true)
        if let index = featureTable[HIDPPProtocol.featureHiResWheel] {
            sendHIDPPPacket(HIDPPProtocol.setWheelModePacket(deviceIndex: activeDeviceIndex, featureIndex: index, diverted: false))
        }
        if let index = featureTable[HIDPPProtocol.featureThumbwheel] {
            sendHIDPPPacket(HIDPPProtocol.setThumbwheelReportingPacket(deviceIndex: activeDeviceIndex, featureIndex: index, diverted: false))
        }
        releaseGestureHoldIfNeeded()
    }

    /// Clears a stuck hold (e.g. the mouse disconnected mid-gesture).
    func releaseGestureHoldIfNeeded() {
        guard isGestureButtonHeld else { return }
        isGestureButtonHeld = false
        gestureTriggeredDuringHold = false
        gestureAccumulatedDelta = .zero
    }

    // MARK: - Diverted Wheel

    /// macOS applies natural scrolling to real wheel events but not to events an app posts, so the direction
    /// is chosen here: standard when requested, otherwise whatever the system is set to.
    private var scrollDirectionSign: Double {
        if config.standardVerticalScroll { return 1 }
        let natural = UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
        return natural ? -1 : 1
    }

    /// One wheel movement from the mouse, in notches; positive = rolled away from the user.
    func handleDivertedWheel(notches: Int) {
        guard notches != 0 else { return }
        let ticks = Double(notches) * scrollDirectionSign * config.scrollSpeedMultiplier
        if config.smoothScrolling {
            enqueueSmoothScroll(verticalTicks: ticks)
        } else {
            postLineScroll(verticalTicks: ticks)
        }
    }

    /// Non-smooth scrolling: whole lines, carrying fractional ticks (from the speed multiplier) to the next notch.
    private func postLineScroll(verticalTicks: Double) {
        pendingLineScroll += verticalTicks
        let lines = Int32(pendingLineScroll.rounded(.towardZero))
        guard lines != 0 else { return }
        pendingLineScroll -= Double(lines)
        postScrollEvent(units: .line, vertical: lines, horizontal: 0)
    }

    private func enqueueSmoothScroll(verticalTicks: Double) {
        // Each notch adds pixel velocity, decayed smoothly at 120 Hz; the timer stops as soon as it settles.
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
        if stepPixels != 0 {
            postScrollEvent(units: .pixel, vertical: stepPixels, horizontal: 0)
        }
    }

    private func postScrollEvent(units: CGScrollEventUnit, vertical: Int32, horizontal: Int32) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                  scrollWheelEvent2Source: source,
                  units: units,
                  wheelCount: 2,
                  wheel1: vertical,
                  wheel2: horizontal,
                  wheel3: 0
              ) else { return }
        event.post(tap: .cgSessionEventTap)
    }

    // MARK: - Diverted Thumbwheel

    /// Pixels of horizontal scroll per unit of diverted thumbwheel rotation.
    private static let thumbwheelPixelsPerUnit: Int = 2

    func handleDivertedThumbwheel(rotation: Int) {
        guard rotation != 0 else { return }
        let delta = config.invertThumbwheel ? -rotation : rotation
        let now = CFAbsoluteTimeGetCurrent()

        switch config.thumbwheelAction {
        case .horizontalScroll:
            postScrollEvent(units: .pixel, vertical: 0, horizontal: Int32(delta * Self.thumbwheelPixelsPerUnit))

        case .displayBrightness:
            if let displayID = NSScreen.underPointer?.displayID {
                _ = DisplayStateModel.shared.handleMediaKey(delta > 0 ? .brightnessUp : .brightnessDown, on: displayID)
            }

        case .displayVolume:
            if let displayID = NSScreen.underPointer?.displayID {
                _ = DisplayStateModel.shared.handleMediaKey(delta > 0 ? .volumeUp : .volumeDown, on: displayID)
            }

        case .switchSpaces:
            guard now - lastSpaceOrTabSwitchTime > 0.28 else { return }
            lastSpaceOrTabSwitchTime = now
            performButtonAction(delta > 0 ? .spaceRight : .spaceLeft)

        case .switchTabs:
            guard now - lastSpaceOrTabSwitchTime > 0.16 else { return }
            lastSpaceOrTabSwitchTime = now
            // ⇧⌘] (next tab) or ⇧⌘[ (previous tab)
            postKeyCombo(keyCode: UInt16(delta > 0 ? kVK_ANSI_RightBracket : kVK_ANSI_LeftBracket), flags: [.maskCommand, .maskShift])

        case .zoom:
            guard now - lastSpaceOrTabSwitchTime > 0.12 else { return }
            lastSpaceOrTabSwitchTime = now
            postKeyCombo(keyCode: UInt16(delta > 0 ? kVK_ANSI_Equal : kVK_ANSI_Minus), flags: [.maskCommand])
        }
    }

    // MARK: - Diverted Buttons & Hold-Drag Gestures

    func handleDivertedGestureButtonState(isDown: Bool) {
        if isDown {
            isGestureButtonHeld = true
            gestureTriggeredDuringHold = false
            gestureAccumulatedDelta = .zero
        } else {
            let wasHeld = isGestureButtonHeld
            let didDrag = gestureTriggeredDuringHold
            releaseGestureHoldIfNeeded()
            if wasHeld && !didDrag {
                performButtonAction(config.gestureButtonClickAction)
            }
        }
    }

    /// Pointer motion while the gesture button is held. The mouse diverts it (raw XY) instead of moving the
    /// cursor, so only this mouse's motion ever reaches here. Positive dy = moved toward the user.
    func handleDivertedRawXY(dx: Int, dy: Int) {
        guard isGestureButtonHeld, config.gesturesEnabled, !gestureTriggeredDuringHold else { return }
        gestureAccumulatedDelta.x += CGFloat(dx)
        gestureAccumulatedDelta.y += CGFloat(dy)

        let absX = abs(gestureAccumulatedDelta.x)
        let absY = abs(gestureAccumulatedDelta.y)
        guard max(absX, absY) >= gestureDragThreshold else { return }

        gestureTriggeredDuringHold = true
        if absY >= absX {
            performButtonAction(gestureAccumulatedDelta.y < 0 ? config.gestureUpAction : config.gestureDownAction)
        } else {
            performButtonAction(gestureAccumulatedDelta.x < 0 ? config.gestureLeftAction : config.gestureRightAction)
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
