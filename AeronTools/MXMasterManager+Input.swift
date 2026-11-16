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
        gestureTracker.cancel()
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

        // Scheduled on the main run loop, so each tick runs on the main actor directly, without a task per tick.
        smoothScrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
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

    // MARK: - Hold-Drag Gestures

    /// Raw XY reports sensor counts at the current DPI, so the drag distance is set in travel (about 3 mm):
    /// a click with a little wobble stays a click at any DPI.
    private var gestureDragThreshold: Int {
        max(36, Int(Double(config.dpi) * 0.12))
    }

    /// Press/release of a control that can start a hold-and-drag gesture (the thumb button or the haptic panel).
    /// The gesture is decided on release, from the whole drag; releasing without dragging runs `clickAction`.
    func handleGestureControl(_ cid: UInt16, isDown: Bool, clickAction: AccessoryButtonAction) {
        guard !isDown else {
            gestureTracker.press(cid)
            return
        }
        switch gestureTracker.release(cid, threshold: gestureDragThreshold) {
        case .click:
            performButtonAction(clickAction)
        case .gesture(.up):
            performButtonAction(config.gestureUpAction)
        case .gesture(.down):
            performButtonAction(config.gestureDownAction)
        case .gesture(.left):
            performButtonAction(config.gestureLeftAction)
        case .gesture(.right):
            performButtonAction(config.gestureRightAction)
        case .none:
            break
        }
    }

    /// Pointer motion while a gesture control is held. The mouse diverts it (raw XY) instead of moving the cursor,
    /// so only this mouse's motion ever reaches here.
    func handleGestureMotion(dx: Int, dy: Int) {
        guard config.gesturesEnabled else { return }
        gestureTracker.move(dx: dx, dy: dy)
    }

    // MARK: - Action Execution

    /// Runs a button action. Everything except the wheel-mode toggle is shared with other accessories.
    public func performButtonAction(_ action: AccessoryButtonAction) {
        if action == .toggleWheelMode {
            toggleWheelMode()
        } else {
            AccessoryActions.perform(action)
        }
    }

    func postKeyCombo(keyCode: UInt16, flags: CGEventFlags) {
        AccessoryActions.postKeyCombo(keyCode: keyCode, flags: flags)
    }
}
