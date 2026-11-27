import AppKit
import SwiftUI

// MARK: - Custom Vector Menu Bar & Header Icon Renderer

@MainActor
public enum AeronToolsIcon {
    /// Renders a crisp, Retina-aligned template `NSImage` for the macOS menu bar.
    /// Shows a sleek studio display with internal hardware control sliders, plus a secondary display
    /// frame or wireless broadcast waves when active.
    public static func menuBarImage(
        isGameModeActive: Bool = false,
        isCaffeineActive: Bool,
        isStreaming: Bool,
        hasExternalDisplays: Bool
    ) -> NSImage {
        if isGameModeActive,
           let controller = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: "Aeron Tools – Game Mode On") {
            controller.isTemplate = true
            return controller
        }
        if isCaffeineActive,
           let cup = NSImage(systemSymbolName: "cup.and.heat.waves.fill", accessibilityDescription: "Aeron Tools – Caffeine On") {
            cup.isTemplate = true
            return cup
        }

        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.labelColor.setStroke()
            NSColor.labelColor.setFill()

            // Optional secondary display outline (upper-right) when an external display is connected
            if hasExternalDisplays && !isStreaming {
                let backPath = NSBezierPath()
                backPath.lineWidth = 1.25
                backPath.lineCapStyle = .round
                backPath.lineJoinStyle = .round
                backPath.move(to: NSPoint(x: 5.5, y: 14.5))
                backPath.line(to: NSPoint(x: 15.0, y: 14.5))
                backPath.appendArc(withCenter: NSPoint(x: 15.0, y: 13.0), radius: 1.5, startAngle: 90, endAngle: 0, clockwise: true)
                backPath.line(to: NSPoint(x: 16.5, y: 7.5))
                backPath.stroke()
            }

            // Primary Studio Display Frame
            let screenRect = (hasExternalDisplays || isStreaming)
                ? NSRect(x: 1.5, y: 4.5, width: 13.0, height: 8.8)
                : NSRect(x: 2.0, y: 4.8, width: 14.0, height: 9.4)
            let framePath = NSBezierPath(roundedRect: screenRect, xRadius: 2.2, yRadius: 2.2)
            framePath.lineWidth = 1.45
            framePath.stroke()

            // Studio Display Stand
            let midX = screenRect.midX
            let standNeck = NSBezierPath()
            standNeck.lineWidth = 1.35
            standNeck.lineCapStyle = .round
            standNeck.move(to: NSPoint(x: midX, y: screenRect.minY))
            standNeck.line(to: NSPoint(x: midX, y: 2.3))
            standNeck.stroke()

            let standBase = NSBezierPath()
            standBase.lineWidth = 1.4
            standBase.lineCapStyle = .round
            standBase.move(to: NSPoint(x: midX - 2.9, y: 2.2))
            standBase.line(to: NSPoint(x: midX + 2.9, y: 2.2))
            standBase.stroke()

            // Internal Precision Sliders (2 horizontal tracks + knobs)
            let topY = screenRect.minY + screenRect.height * 0.66
            let botY = screenRect.minY + screenRect.height * 0.34
            let leftX = screenRect.minX + 2.3
            let rightX = screenRect.maxX - 2.3

            let slidersPath = NSBezierPath()
            slidersPath.lineWidth = 1.25
            slidersPath.lineCapStyle = .round
            slidersPath.move(to: NSPoint(x: leftX, y: topY))
            slidersPath.line(to: NSPoint(x: rightX, y: topY))
            slidersPath.move(to: NSPoint(x: leftX, y: botY))
            slidersPath.line(to: NSPoint(x: rightX, y: botY))
            slidersPath.stroke()

            // Slider Knobs
            let topKnobX = leftX + (rightX - leftX) * 0.68
            let botKnobX = leftX + (rightX - leftX) * 0.32
            let knobRadius: CGFloat = 1.45
            NSBezierPath(ovalIn: NSRect(
                x: topKnobX - knobRadius,
                y: topY - knobRadius,
                width: knobRadius * 2,
                height: knobRadius * 2
            )).fill()
            NSBezierPath(ovalIn: NSRect(
                x: botKnobX - knobRadius,
                y: botY - knobRadius,
                width: knobRadius * 2,
                height: knobRadius * 2
            )).fill()

            // Wireless Broadcast Arcs in upper-right when streaming
            if isStreaming {
                let waveCenter = NSPoint(x: 13.8, y: 12.6)
                let wave1 = NSBezierPath()
                wave1.lineWidth = 1.25
                wave1.lineCapStyle = .round
                wave1.appendArc(withCenter: waveCenter, radius: 1.9, startAngle: 10, endAngle: 85)
                wave1.stroke()

                let wave2 = NSBezierPath()
                wave2.lineWidth = 1.25
                wave2.lineCapStyle = .round
                wave2.appendArc(withCenter: waveCenter, radius: 3.6, startAngle: 10, endAngle: 85)
                wave2.stroke()
            }

            return true
        }
        image.isTemplate = true
        return image
    }
}

@MainActor
public final class StatusBarController: NSObject, NSPopoverDelegate {
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
        if model.showMenuBarIcon {
            setupStatusItem()
        }
        startObserving()
    }

    public func setMenuBarVisible(_ visible: Bool) {
        if visible {
            if statusItem == nil {
                setupStatusItem()
                updateIcon()
            }
        } else {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
            if popover?.isShown == true {
                popover?.performClose(nil)
            }
        }
    }

    public func closePopover() {
        popover?.performClose(nil)
    }

    // Re-arms observation each time so the icon, live stats and telemetry polling track model changes.
    private func startObserving() {
        withObservationTracking {
            updateIcon()
            _ = model.showMenuBarIcon
            _ = model.showAccessoriesCard
            _ = WirelessDisplayManager.shared.isStreaming
            _ = GameModeManager.shared.isGameModeActive
            updateTelemetry()
        } onChange: {
            Task { @MainActor in
                self.startObserving()
            }
        }
    }

    private func setupPopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        let hostingController = NSHostingController(rootView: ContentView())
        // Size the popover to the SwiftUI content so it grows with the number of monitors.
        hostingController.sizingOptions = .preferredContentSize
        popover.contentViewController = hostingController
        self.popover = popover
    }

    private func setupStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        self.statusItem = item
    }

    /// Game Mode and Caffeine take precedence; otherwise the custom Aeron Tools icon reflects whether Wireless Display streaming or an external display is active.
    /// Live stats, when enabled, appear as text beside the icon.
    public func updateIcon() {
        guard let button = statusItem?.button else { return }
        let isStreaming = WirelessDisplayManager.shared.isStreaming
        let isGameModeActive = GameModeManager.shared.isGameModeActive
        let description: String
        if isGameModeActive {
            description = "Aeron Tools – Game Mode On"
        } else if model.isCaffeineActive {
            description = "Aeron Tools – Caffeine On"
        } else if isStreaming {
            description = "Aeron Tools – Wireless Display Streaming"
        } else if model.hasExternalDisplays {
            description = "Aeron Tools – External Display Connected"
        } else {
            description = "Aeron Tools"
        }

        let icon = AeronToolsIcon.menuBarImage(
            isGameModeActive: isGameModeActive,
            isCaffeineActive: model.isCaffeineActive,
            isStreaming: isStreaming,
            hasExternalDisplays: model.hasExternalDisplays
        )
        icon.accessibilityDescription = description
        button.image = icon

        let stat = model.menuBarStat
        let text = MenuBarStat.text(
            watts: WattageManager.shared.currentSnapshot?.systemLoadWatts,
            cpuCelsius: ThermalManager.shared.currentSnapshot?.cpuCelsius,
            showWatts: stat.showsWatts,
            showTemperature: stat.showsTemperature
        )
        let title = text.isEmpty ? "" : " " + text
        if button.title != title {
            // Monospaced digits stop the status item from jittering as values change.
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
            ])
        }
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button, let popover = popover else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Make sure display state is up-to-date. A menu bar app isn't always activated when its
            // icon is clicked, so permissions granted in System Settings are also picked up here.
            model.refreshDisplays()
            AccessibilityPermission.shared.refresh()
            WirelessDisplayManager.shared.refreshPermissions()
            WirelessDisplayManager.shared.refreshNetworkInterfaces()
            Task { await GameModeManager.shared.refreshStatus() }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Telemetry Polling

    /// Sensors are polled only while something shows them: an enabled card in the open popover, or a live
    /// stat in the menu bar.
    private func updateTelemetry() {
        let popoverShown = popover?.isShown == true
        let stat = model.menuBarStat
        let menuBarVisible = statusItem != nil

        let wantsWattage = (popoverShown && model.showWattageMeter) || (menuBarVisible && stat.showsWatts)
        let wantsThermals = (popoverShown && model.showThermals) || (menuBarVisible && stat.showsTemperature)

        if wantsWattage {
            WattageManager.shared.startMonitoring()
        } else {
            WattageManager.shared.stopMonitoring()
        }
        if wantsThermals {
            ThermalManager.shared.startMonitoring()
        } else {
            ThermalManager.shared.stopMonitoring()
        }
    }

    // MARK: - NSPopoverDelegate

    public func popoverDidShow(_ notification: Notification) {
        updateTelemetry()
    }

    public func popoverDidClose(_ notification: Notification) {
        updateTelemetry()
    }
}
