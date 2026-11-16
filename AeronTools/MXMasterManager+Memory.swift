import Foundation

extension MXMasterManager {
    // MARK: - Saving to the Mouse
    //
    // The MX Master has no onboard profiles: gestures and most actions only exist while the app runs. What the
    // mouse can keep is a remap of one of its controls onto another, so a button set to an action with a native
    // equivalent (Back, Forward, the wheel-mode toggle) is remapped to that control. While the app runs, the
    // diverted button still goes to the app; once it quits, the remap takes over.

    public enum MouseSaveState: Equatable {
        case idle
        case saving
        /// Saved; lists the buttons that keep their action without the app.
        case saved([String])
        case failed(String)
    }

    /// Each remappable button, its name, and the action configured for it.
    nonisolated static func buttonActions(_ config: MXMasterConfig) -> [(cid: UInt16, name: String, action: AccessoryButtonAction)] {
        [
            (HIDPPProtocol.cidMiddleButton, "Middle Button", config.middleButtonAction),
            (HIDPPProtocol.cidBackButton, "Back Button", config.backButtonAction),
            (HIDPPProtocol.cidForwardButton, "Forward Button", config.forwardButtonAction),
            (HIDPPProtocol.cidGestureThumbButton, "Thumb Button", config.gestureButtonClickAction),
            (HIDPPProtocol.cidModeShiftButton, "Button Behind Wheel", config.modeShiftButtonAction),
            (HIDPPProtocol.cidHapticPanelButton, "Haptic Panel", config.hapticPanelButtonAction)
        ]
    }

    /// The mouse control that performs an action natively, if there is one.
    nonisolated static func nativeControl(for action: AccessoryButtonAction) -> UInt16? {
        switch action {
        case .navigateBack: return HIDPPProtocol.cidBackButton
        case .navigateForward: return HIDPPProtocol.cidForwardButton
        case .toggleWheelMode: return HIDPPProtocol.cidModeShiftButton
        default: return nil
        }
    }

    /// Saves a few seconds after the last change, so trying out actions writes the mouse once.
    func scheduleMouseSave() {
        guard featureTable[HIDPPProtocol.featureReprogControlsV4] != nil else { return }
        mouseSaveTask?.cancel()
        mouseSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            await self.saveToMouse()
        }
    }

    /// Clears what's known about the connected mouse's controls (a different device, or it went away).
    func resetMouseMemory() {
        mouseSaveTask?.cancel()
        controlInfos.removeAll()
    }

    private func saveToMouse() async {
        guard let index = featureTable[HIDPPProtocol.featureReprogControlsV4],
              let session = identitySession, session.deviceIndex == activeDeviceIndex else { return }
        mouseSaveState = .saving

        if controlInfos.isEmpty {
            controlInfos = await readControlInfos(session: session, index: index)
        }
        guard !controlInfos.isEmpty else {
            mouseSaveState = .failed("Couldn't read the mouse's buttons.")
            return
        }

        var kept: [String] = []
        var forgotten = false
        for button in Self.buttonActions(config) {
            guard !Task.isCancelled else { return }
            guard let info = controlInfos[button.cid] else { continue }
            var target = button.cid
            if savesToMouse, let native = Self.nativeControl(for: button.action), let nativeInfo = controlInfos[native],
               info.canRemap(to: nativeInfo) {
                target = native
            }

            guard let reply = await session.request(featureIndex: index, function: 0x02,
                                                    params: [UInt8(button.cid >> 8), UInt8(button.cid & 0xFF)]),
                  let current = HIDPPProtocol.parseControlRemap(reply, controlID: button.cid) else { continue }
            if let saved = savedRemaps[button.cid], saved != button.cid, current != saved {
                forgotten = true
            }

            if current != target {
                _ = await session.request(packet: HIDPPProtocol.setControlRemapPacket(
                    deviceIndex: activeDeviceIndex, featureIndex: index, controlID: button.cid, target: target
                ))
                // Read back: an unsupported remap is acknowledged by some firmware without taking effect.
                guard let check = await session.request(featureIndex: index, function: 0x02,
                                                        params: [UInt8(button.cid >> 8), UInt8(button.cid & 0xFF)]),
                      HIDPPProtocol.parseControlRemap(check, controlID: button.cid) == target else {
                    mouseSaveState = .failed("The mouse didn't accept the \(button.name) change.")
                    dlog(String(format: "MX Master: remap 0x%04X → 0x%04X didn't verify", button.cid, target))
                    return
                }
            }
            savedRemaps[button.cid] = target
            if target != button.cid || (savesToMouse && Self.nativeControl(for: button.action) == button.cid) {
                kept.append(button.name)
            }
        }

        if forgotten {
            mouseSaveState = .failed("The mouse forgot its saved buttons when it reconnected, so they don't last without Aeron Tools.")
        } else {
            mouseSaveState = savesToMouse ? .saved(kept) : .idle
        }
    }

    /// `getCount` (function 0), then `getCidInfo` (function 1) for each control.
    private func readControlInfos(session: HIDPPSession, index: UInt8) async -> [UInt16: HIDPPProtocol.ControlInfo] {
        guard let countReply = await session.request(featureIndex: index, function: 0x00) else { return [:] }
        var infos: [UInt16: HIDPPProtocol.ControlInfo] = [:]
        for slot in 0..<countReply[4] {
            guard let reply = await session.request(featureIndex: index, function: 0x01, params: [slot]),
                  let info = HIDPPProtocol.parseControlInfo(reply) else { continue }
            infos[info.cid] = info
            dlog(String(format: "MX Master: control 0x%04X flags 0x%02X group %d mask 0x%02X",
                        info.cid, info.flags, info.group, info.groupMask))
        }
        return infos
    }
}
