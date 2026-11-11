import AppKit
import CoreGraphics
import Carbon.HIToolbox

// MARK: - Accessory Button Actions

/// Action assignable to an accessory's buttons (or an MX Master's hold-and-drag gestures). Raw values are
/// persisted in each accessory's settings, so they must never change.
public enum AccessoryButtonAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case systemDefault
    case missionControl
    case appExpose
    case showDesktop
    case launchpad
    case spaceLeft
    case spaceRight
    case navigateBack
    case navigateForward
    case playPause
    case mutePointerDisplay
    case toggleMacBookScreen
    case toggleCaffeine
    case toggleWheelMode
    case copy
    case paste

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .systemDefault: return "System Default"
        case .missionControl: return "Mission Control"
        case .appExpose: return "App Exposé"
        case .showDesktop: return "Show Desktop"
        case .launchpad: return "Launchpad"
        case .spaceLeft: return "Move a Space Left"
        case .spaceRight: return "Move a Space Right"
        case .navigateBack: return "Back (⌘[)"
        case .navigateForward: return "Forward (⌘])"
        case .playPause: return "Play / Pause Media"
        case .mutePointerDisplay: return "Mute Display Under Pointer"
        case .toggleMacBookScreen: return "Toggle MacBook Screen"
        case .toggleCaffeine: return "Toggle Caffeine"
        case .toggleWheelMode: return "Toggle Ratchet / Free-Spin"
        case .copy: return "Copy (⌘C)"
        case .paste: return "Paste (⌘V)"
        }
    }
}

extension AccessoryButtonAction {
    /// Actions any accessory can offer; the wheel-mode toggle needs an MX Master.
    static let general: [AccessoryButtonAction] = allCases.filter { $0 != .toggleWheelMode }
}

/// Performs button actions for every accessory by posting the system shortcut each action maps to.
/// Shared code only: each accessory still decides which of its own buttons trigger which action.
enum AccessoryActions {
    static func perform(_ action: AccessoryButtonAction) {
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
            // Device-specific: handled by the accessory that has a wheel mode.
            break
        case .copy:
            postKeyCombo(keyCode: UInt16(kVK_ANSI_C), flags: [.maskCommand])
        case .paste:
            postKeyCombo(keyCode: UInt16(kVK_ANSI_V), flags: [.maskCommand])
        }
    }

    static func openSystemAction(appNamed: String, fallbackKeyCode: UInt16, fallbackFlags: CGEventFlags) {
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
    static func postSymbolicHotKey(_ id: Int, fallbackKeyCode: UInt16, fallbackFlags: CGEventFlags) {
        let hotKeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        guard let entry = hotKeys?[String(id)] as? [String: Any] else {
            postKeyCombo(keyCode: fallbackKeyCode, flags: fallbackFlags)
            return
        }
        // A disabled shortcut can't be triggered at all; WindowServer would ignore any synthesized keystroke.
        if let enabled = entry["enabled"] as? Bool, !enabled {
            dlog("Accessory action: system shortcut \(id) is disabled in Keyboard Shortcuts")
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

    static func postKeyCombo(keyCode: UInt16, flags: CGEventFlags) {
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

    static func postMediaKey(nxKeyType: Int) {
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
