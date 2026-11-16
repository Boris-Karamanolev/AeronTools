import SwiftUI

// MARK: - SatechiHubConnector

/// The Satechi Thunderbolt 4 Slim Hub Pro (ST-HT4SHM): what's plugged into its three Thunderbolt ports and its
/// USB-A port. The hub has nothing to configure; its only USB device is a billboard with a firmware interface.
///
/// Event-driven: `DockPortMonitor` follows USB and Thunderbolt attach and detach notifications.
@Observable
@MainActor
final class SatechiHubConnector {
    static let shared = SatechiHubConnector()

    private static let name = "Satechi Thunderbolt 4 Slim Hub Pro"

    /// What's plugged into the hub, and whether it's connected at all.
    let ports = DockPortMonitor(model: .satechiSlimHubPro)

    private init() {}
}

// MARK: - AccessoryConnector

extension SatechiHubConnector: AccessoryConnector {
    var id: String { "satechi.thunderbolt-4-slim-hub-pro" }
    var displayName: String { "Satechi Hub" }
    var systemImage: String { "cable.connector.horizontal" }

    var isAvailable: Bool { ports.layout.isPresent }
    var accessoryName: String { Self.name }
    var connection: AccessoryConnection? { isAvailable ? .thunderbolt : nil }
    var isAwake: Bool { isAvailable }
    var batteryPercent: Int? { nil }
    var isCharging: Bool { false }
    var hasBattery: Bool { false }
    /// Everything comes from the IORegistry; no HID device is opened.
    var needsInputMonitoring: Bool { false }

    func start() {
        ports.start()
    }

    func stop() {}

    func systemDidWake() {
        ports.refresh()
    }

    func popoverWillShow() {}

    func setCardVisible(_ visible: Bool) {}

    func makeSettingsView() -> AnyView {
        AnyView(SatechiHubSettingsView(connector: self))
    }
}

// MARK: - Settings Sections

/// The hub page: its ports and what's plugged in. The Accessories tab adds the device section, and disables
/// everything while the hub isn't connected.
private struct SatechiHubSettingsView: View {
    let connector: SatechiHubConnector

    var body: some View {
        DockPortsSection(monitor: connector.ports)
        if let serial = connector.ports.layout.serialNumber {
            SettingsSection(title: "About") {
                LabeledContent("Serial Number", value: serial)
            }
        }
    }
}
