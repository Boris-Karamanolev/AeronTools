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

    /// Shortcuts the Keychron stores on the mouse. Matches the old `buttonActions` list.
    static let keychron: [AccessoryButtonAction] = [
        .systemDefault,
        .navigateBack,
        .navigateForward,
        .missionControl,
        .appExpose,
        .showDesktop,
        .spaceLeft,
        .spaceRight,
        .copy,
        .paste,
    ]
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
        static let missionControl = 32
        static let appExpose = 33
        static let showDesktop = 36
        static let moveLeftASpace = 79
        static let moveRightASpace = 81
    }

    /// Posts the shortcut the user has actually assigned to a system action, since WindowServer only reacts to
    /// the configured combination. Falls back to the macOS default when the entry has never been customized.
    static func postSymbolicHotKey(_ id: Int, fallbackKeyCode: UInt16, fallbackFlags: CGEventFlags) {
        guard let shortcut = symbolicHotKey(id, fallbackKeyCode: fallbackKeyCode, fallbackFlags: fallbackFlags) else {
            // A disabled shortcut can't be triggered at all; WindowServer would ignore any synthesized keystroke.
            dlog("Accessory action: system shortcut \(id) is disabled in Keyboard Shortcuts")
            return
        }
        postKeyCombo(keyCode: shortcut.keyCode, flags: shortcut.flags)
    }

    /// The shortcut the user has assigned to a system action, or the macOS default when the entry has never been
    /// customized. Nil when the shortcut is turned off.
    static func symbolicHotKey(_ id: Int, fallbackKeyCode: UInt16, fallbackFlags: CGEventFlags) -> Shortcut? {
        let fallback = Shortcut(keyCode: fallbackKeyCode, flags: fallbackFlags)
        let hotKeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        guard let entry = hotKeys?[String(id)] as? [String: Any] else { return fallback }
        if let enabled = entry["enabled"] as? Bool, !enabled { return nil }
        // parameters = (character, virtual key code, modifier mask using NSEvent/CGEventFlags bit positions)
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Int],
              parameters.count >= 3,
              parameters[1] != 0xFFFF else { return fallback }
        return Shortcut(keyCode: UInt16(parameters[1]), flags: CGEventFlags(rawValue: UInt64(parameters[2])))
    }

    /// A key and its modifiers, as a virtual key code and event flags.
    struct Shortcut: Equatable {
        let keyCode: UInt16
        let flags: CGEventFlags

        /// The shortcut as a HID keyboard usage and modifier bits (Control 0x01, Shift 0x02, Option 0x04,
        /// Command 0x08), for accessories that store a shortcut and send it themselves. Nil for keys without a
        /// usage in the table.
        var hidKey: (usage: UInt8, modifiers: UInt8)? {
            guard let usage = Self.hidUsages[keyCode] else { return nil }
            var modifiers: UInt8 = 0
            if flags.contains(.maskControl) { modifiers |= 0x01 }
            if flags.contains(.maskShift) { modifiers |= 0x02 }
            if flags.contains(.maskAlternate) { modifiers |= 0x04 }
            if flags.contains(.maskCommand) { modifiers |= 0x08 }
            return (usage, modifiers)
        }

        /// macOS virtual key codes and the HID keyboard usages for the same key positions.
        nonisolated static let hidUsages: [UInt16: UInt8] = [
            // Letters
            0x00: 0x04, 0x0B: 0x05, 0x08: 0x06, 0x02: 0x07, 0x0E: 0x08, 0x03: 0x09, 0x05: 0x0A, 0x04: 0x0B,
            0x22: 0x0C, 0x26: 0x0D, 0x28: 0x0E, 0x25: 0x0F, 0x2E: 0x10, 0x2D: 0x11, 0x1F: 0x12, 0x23: 0x13,
            0x0C: 0x14, 0x0F: 0x15, 0x01: 0x16, 0x11: 0x17, 0x20: 0x18, 0x09: 0x19, 0x0D: 0x1A, 0x07: 0x1B,
            0x10: 0x1C, 0x06: 0x1D,
            // Digits 1…9, 0
            0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x17: 0x22, 0x16: 0x23, 0x1A: 0x24, 0x1C: 0x25,
            0x19: 0x26, 0x1D: 0x27,
            // Return, Escape, Delete, Tab, Space, - = [ ] \ ; ' ` , . /
            0x24: 0x28, 0x35: 0x29, 0x33: 0x2A, 0x30: 0x2B, 0x31: 0x2C, 0x1B: 0x2D, 0x18: 0x2E, 0x21: 0x2F,
            0x1E: 0x30, 0x2A: 0x31, 0x29: 0x33, 0x27: 0x34, 0x32: 0x35, 0x2B: 0x36, 0x2F: 0x37, 0x2C: 0x38,
            // F1…F12
            0x7A: 0x3A, 0x78: 0x3B, 0x63: 0x3C, 0x76: 0x3D, 0x60: 0x3E, 0x61: 0x3F, 0x62: 0x40, 0x64: 0x41,
            0x65: 0x42, 0x6D: 0x43, 0x67: 0x44, 0x6F: 0x45,
            // Home, Page Up, Forward Delete, End, Page Down, → ← ↓ ↑
            0x73: 0x4A, 0x74: 0x4B, 0x75: 0x4C, 0x77: 0x4D, 0x79: 0x4E, 0x7C: 0x4F, 0x7B: 0x50, 0x7D: 0x51,
            0x7E: 0x52,
        ]
    }

    /// The shortcut an action amounts to on this Mac, for accessories that send keystrokes themselves. Nil for
    /// actions that aren't a plain shortcut, and for shortcuts turned off in Keyboard Shortcuts.
    static func shortcut(for action: AccessoryButtonAction) -> Shortcut? {
        switch action {
        case .missionControl:
            return symbolicHotKey(SymbolicHotKey.missionControl, fallbackKeyCode: UInt16(kVK_UpArrow), fallbackFlags: [.maskControl])
        case .appExpose:
            return symbolicHotKey(SymbolicHotKey.appExpose, fallbackKeyCode: UInt16(kVK_DownArrow), fallbackFlags: [.maskControl])
        case .showDesktop:
            return symbolicHotKey(SymbolicHotKey.showDesktop, fallbackKeyCode: UInt16(kVK_F11), fallbackFlags: [])
        case .spaceLeft:
            return symbolicHotKey(SymbolicHotKey.moveLeftASpace, fallbackKeyCode: UInt16(kVK_LeftArrow), fallbackFlags: [.maskControl])
        case .spaceRight:
            return symbolicHotKey(SymbolicHotKey.moveRightASpace, fallbackKeyCode: UInt16(kVK_RightArrow), fallbackFlags: [.maskControl])
        case .navigateBack:
            return Shortcut(keyCode: UInt16(kVK_ANSI_LeftBracket), flags: [.maskCommand])
        case .navigateForward:
            return Shortcut(keyCode: UInt16(kVK_ANSI_RightBracket), flags: [.maskCommand])
        case .copy:
            return Shortcut(keyCode: UInt16(kVK_ANSI_C), flags: [.maskCommand])
        case .paste:
            return Shortcut(keyCode: UInt16(kVK_ANSI_V), flags: [.maskCommand])
        default:
            return nil
        }
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
