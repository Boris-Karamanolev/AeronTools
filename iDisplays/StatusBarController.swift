import AppKit
import SwiftUI

@MainActor
public final class StatusBarController: NSObject {
    public static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var model: DisplayStateModel {
        DisplayStateModel.shared
    }

    private override init() {
        super.init()
    }

    public func start() {
        setupPopover()
        updateVisibility()

        // Observe model changes to show/hide status bar item
        withObservationTracking {
            _ = model.hasExternalDisplays
        } onChange: {
            Task { @MainActor in
                self.startObserving()
            }
        }
    }

    private func startObserving() {
        updateVisibility()
        withObservationTracking {
            _ = model.hasExternalDisplays
        } onChange: {
            Task { @MainActor in
                self.startObserving()
            }
        }
    }

    private func setupPopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        let hostingController = NSHostingController(rootView: ContentView())
        // Size the popover to the SwiftUI content so it grows with the number of monitors.
        hostingController.sizingOptions = .preferredContentSize
        popover.contentViewController = hostingController
        self.popover = popover
    }

    public func updateVisibility() {
        if model.hasExternalDisplays {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                if let button = item.button {
                    button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "iDisplays")
                    button.imagePosition = .imageOnly
                    button.target = self
                    button.action = #selector(togglePopover(_:))
                }
                self.statusItem = item
            }
        } else {
            if let item = statusItem {
                popover?.close()
                NSStatusBar.system.removeStatusItem(item)
                self.statusItem = nil
            }
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button, let popover = popover else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Make sure display state is up-to-date
            model.refreshDisplays()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
