import AppKit
import Carbon.HIToolbox
import Observation

// MARK: - KeyboardShortcut

/// A global shortcut stored as a virtual key code plus Carbon modifier flags.
struct KeyboardShortcut: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    /// Key label captured when the shortcut was recorded, so it matches the user's keyboard layout.
    let keyLabel: String

    nonisolated var displayString: String {
        Self.modifierSymbols(carbonModifiers) + keyLabel
    }

    /// In the standard macOS order: ⌃⌥⇧⌘.
    nonisolated static func modifierSymbols(_ modifiers: UInt32) -> String {
        var symbols = ""
        if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols
    }

    nonisolated static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        return modifiers
    }

    /// Global shortcuts need ⌘, ⌃ or ⌥; Shift alone would hijack ordinary typing.
    nonisolated static func isValidGlobal(modifiers: UInt32) -> Bool {
        modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
    }

    nonisolated static func keyLabel(keyCode: UInt16, characters: String?) -> String {
        switch Int(keyCode) {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            let label = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return label.isEmpty ? "Key \(keyCode)" : label
        }
    }

    static let defaultRestoreScreen = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(cmdKey | shiftKey), keyLabel: "D"
    )
}

// MARK: - HotKeyAction

enum HotKeyAction: String, CaseIterable, Codable, Identifiable {
    case restoreBuiltinScreen
    case toggleBuiltinScreen
    case toggleCaffeine
    case toggleWirelessDisplay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .restoreBuiltinScreen: return "Turn MacBook screen on"
        case .toggleBuiltinScreen: return "Toggle MacBook screen"
        case .toggleCaffeine: return "Toggle Caffeine"
        case .toggleWirelessDisplay: return "Toggle Wireless Display"
        }
    }

    /// Carbon hotkey IDs must be non-zero.
    var carbonID: UInt32 {
        UInt32(Self.allCases.firstIndex(of: self)! + 1)
    }

    @MainActor
    func perform() {
        let model = DisplayStateModel.shared
        switch self {
        case .restoreBuiltinScreen: model.turnOnBuiltin()
        case .toggleBuiltinScreen: model.toggleBuiltinDisplay()
        case .toggleCaffeine: model.toggleCaffeine()
        case .toggleWirelessDisplay: WirelessDisplayManager.shared.toggleSession()
        }
    }
}

// MARK: - HotKeyManager

/// Registers global shortcuts with Carbon, which needs no Accessibility permission and works with nothing on screen.
@Observable
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    private static let defaultsKey = "hotKeys"
    private static let signature = OSType(0x6944_5350) // 'iDSP'

    private(set) var shortcuts: [HotKeyAction: KeyboardShortcut] = [:]
    /// Actions whose shortcut couldn't be registered, usually because another app already owns it.
    private(set) var conflicts: Set<HotKeyAction> = []

    @ObservationIgnored private var registered: [HotKeyAction: EventHotKeyRef] = [:]
    @ObservationIgnored private var handlerInstalled = false
    @ObservationIgnored private var isSuspended = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: KeyboardShortcut].self, from: data) {
            for (rawAction, shortcut) in decoded {
                if let action = HotKeyAction(rawValue: rawAction) {
                    shortcuts[action] = shortcut
                }
            }
        } else {
            shortcuts[.restoreBuiltinScreen] = .defaultRestoreScreen
        }
    }

    func start() {
        installHandlerIfNeeded()
        registerAll()
    }

    func shortcut(for action: HotKeyAction) -> KeyboardShortcut? {
        shortcuts[action]
    }

    /// Pass nil to clear the shortcut.
    func setShortcut(_ shortcut: KeyboardShortcut?, for action: HotKeyAction) {
        if let shortcut {
            // A key combination can only trigger one action.
            for (other, existing) in shortcuts where other != action && existing.keyCode == shortcut.keyCode
                && existing.carbonModifiers == shortcut.carbonModifiers {
                shortcuts[other] = nil
            }
        }
        shortcuts[action] = shortcut
        save()
        registerAll()
    }

    /// While recording, existing shortcuts must not fire.
    func suspend() {
        isSuspended = true
        unregisterAll()
    }

    func resume() {
        isSuspended = false
        registerAll()
    }

    private func save() {
        let encodable = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encodable) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func registerAll() {
        unregisterAll()
        guard !isSuspended else { return }
        var failed: Set<HotKeyAction> = []
        for (action, shortcut) in shortcuts {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.carbonID)
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registered[action] = ref
            } else {
                failed.insert(action)
                dlog("Failed to register \(shortcut.displayString) for \(action.rawValue): \(status)")
            }
        }
        if failed != conflicts {
            conflicts = failed
        }
    }

    private func unregisterAll() {
        for ref in registered.values {
            UnregisterEventHotKey(ref)
        }
        registered.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            Task { @MainActor in
                HotKeyAction.allCases.first { $0.carbonID == id }?.perform()
            }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}
