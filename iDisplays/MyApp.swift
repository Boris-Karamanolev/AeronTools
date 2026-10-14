import SwiftUI
import AppKit
import Carbon.HIToolbox

@main
struct iDisplaysApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        StatusBarController.shared.start()
        registerTurnOnHotKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DisplayStateModel.shared.turnOnBuiltin()
    }

    // ⌘⇧D turns the MacBook screen on. Carbon hotkeys need no Accessibility permission and work with nothing on screen.
    private func registerTurnOnHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in
                DisplayStateModel.shared.turnOnBuiltin()
            }
            return noErr
        }, 1, &eventType, nil, nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x6944_5350), id: 1) // 'iDSP'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(cmdKey | shiftKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            dlog("Failed to register ⌘⇧D hotkey: \(status)")
        }
    }
}
