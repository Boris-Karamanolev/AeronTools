import AppKit
import SwiftUI

@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    public static let shared = SettingsWindowController()

    private var window: NSWindow?

    public var isWindowVisible: Bool {
        window?.isVisible == true
    }

    private override init() {
        super.init()
    }

    public func show() {
        // Switch activation policy to .regular so the dock icon and main menu appear.
        NSApp.setActivationPolicy(.regular)

        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: SettingsView())

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Aeron Tools Settings"
        win.contentViewController = hostingController
        win.center()
        win.delegate = self
        win.isReleasedWhenClosed = false

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        // When window closes, if user didn't request keeping icon in Dock, switch back to accessory.
        if !DisplayStateModel.shared.showDockIcon {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
