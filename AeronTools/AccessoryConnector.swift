import SwiftUI

// MARK: - AccessoryConnector

/// One supported accessory (a mouse, keyboard, headset…). The app talks to accessories only through this
/// protocol, so adding a device means writing one connector and listing it in `AccessoryRegistry`.
///
/// Connectors must be event-driven: react to device callbacks and system notifications rather than timers.
/// Every feature must be exclusive to the connector's own device: talk to that device directly, and never
/// intercept system-wide input (global event taps), which would also change other devices' behavior.
/// Lifecycle hooks below are the only points where the app asks a connector to do work.
@MainActor
protocol AccessoryConnector: AnyObject {
    /// Stable identifier; used for view identity and persisting the selected Settings tab.
    var id: String { get }
    /// Name shown in Settings, e.g. "MX Master".
    var displayName: String { get }
    /// SF Symbol shown next to the name in Settings.
    var systemImage: String { get }
    /// Whether a device this connector supports is attached and has identified itself. A receiver with
    /// nothing on it, or a device another connector owns, must report false so no card is shown.
    /// Must be observable so the popover card appears and disappears on its own.
    var isAvailable: Bool { get }

    /// Called once at launch: register device callbacks and open the hardware.
    func start()
    /// Called when the app quits: hand any controls taken over from macOS back to the device, so it works
    /// normally without the app.
    func stop()
    /// Called after the Mac wakes. Devices often lose their settings across sleep, so re-apply them here.
    func systemDidWake()
    /// Called right before the menu bar popover opens: re-check permissions and fetch fresh state once.
    func popoverWillShow()
    /// Called when the accessory's popover card becomes visible or hidden, so any card-only work stops.
    func setCardVisible(_ visible: Bool)

    /// Compact card for the menu bar popover, shown only while connected.
    func makeCardView() -> AnyView
    /// Full settings page for the Settings window's Accessories tab.
    func makeSettingsView() -> AnyView
}

// MARK: - AccessoryRegistry

/// The list of supported accessories. To add one, conform a type to `AccessoryConnector` and append it here.
@MainActor
enum AccessoryRegistry {
    static let connectors: [any AccessoryConnector] = [
        MXMasterManager.shared,
        LogitechGConnector.shared,
    ]

    static var available: [any AccessoryConnector] {
        connectors.filter(\.isAvailable)
    }

    static func startAll() {
        connectors.forEach { $0.start() }
    }

    static func stopAll() {
        connectors.forEach { $0.stop() }
    }

    static func systemDidWake() {
        connectors.forEach { $0.systemDidWake() }
    }

    static func popoverWillShow() {
        connectors.forEach { $0.popoverWillShow() }
    }

    static func setCardsVisible(_ visible: Bool) {
        connectors.forEach { $0.setCardVisible(visible) }
    }
}

// MARK: - Popover Cards

/// Cards for every connected accessory. Each card reads its connector's observable state, so cards
/// appear and disappear as devices connect without any polling.
struct AccessoryCardsView: View {
    var body: some View {
        ForEach(AccessoryRegistry.available, id: \.id) { connector in
            connector.makeCardView()
        }
    }
}

// MARK: - Settings Tab

/// The Accessories tab: the single connector's settings, or a picker when several accessories are supported.
struct AccessoriesSettingsTabView: View {
    @AppStorage("selectedAccessorySettingsID") private var selectedID = ""

    private var connectors: [any AccessoryConnector] { AccessoryRegistry.connectors }

    private var selected: (any AccessoryConnector)? {
        connectors.first { $0.id == selectedID } ?? connectors.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if connectors.count > 1 {
                Picker("Accessory", selection: $selectedID) {
                    ForEach(connectors, id: \.id) { connector in
                        Label(connector.displayName, systemImage: connector.systemImage)
                            .tag(connector.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.bottom, 8)
            }

            if let selected {
                selected.makeSettingsView()
                    .id(selected.id)
            } else {
                ContentUnavailableView("No Supported Accessories", systemImage: "cable.connector")
            }
        }
    }
}
