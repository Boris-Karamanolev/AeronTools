import SwiftUI
import IOKit.hid
import UserNotifications

// MARK: - AccessoryConnector

/// One supported accessory (a mouse, keyboard, headset…). The app talks to accessories only through this
/// protocol, so adding a device means writing one connector and listing it in `AccessoryRegistry`.
///
/// Connectors must be event-driven: react to device callbacks and system notifications rather than timers.
/// Every feature must be exclusive to the connector's own device: talk to that device directly, and never
/// intercept system-wide input (global event taps), which would also change other devices' behavior.
///
/// The app draws everything common from the properties below: the popover card (name, connection, battery),
/// the Settings device section with its status dot, greying out while disconnected, and low-battery alerts.
/// A connector only supplies its device-specific settings sections.
@MainActor
protocol AccessoryConnector: AnyObject {
    /// Stable identifier; used for view identity and persisting the selected Settings tab.
    var id: String { get }
    /// Accessory family shown in the Settings selector, e.g. "MX Master".
    var displayName: String { get }
    /// SF Symbol for the accessory, used on its popover card.
    var systemImage: String { get }

    /// Whether a device this connector supports is attached and has identified itself. A receiver with
    /// nothing on it, or a device another connector owns, must report false so no card is shown.
    /// Must be observable so the card and Settings update on their own.
    var isAvailable: Bool { get }
    /// The device's own name once known (e.g. "PRO X2 SUPERSTRIKE"), otherwise the family name.
    var accessoryName: String { get }
    /// How the device is connected; nil while it isn't.
    var connection: AccessoryConnection? { get }
    /// The device is answering right now. False while it sleeps, even though it's still paired.
    var isAwake: Bool { get }
    var batteryPercent: Int? { get }
    var isCharging: Bool { get }

    /// Called once at launch: register device callbacks and open the hardware.
    func start()
    /// Called when the app quits: hand any controls taken over from macOS back to the device, so it works
    /// normally without the app.
    func stop()
    /// Called after the Mac wakes. Devices often lose their settings across sleep, so re-apply them here.
    func systemDidWake()
    /// Called right before the menu bar popover opens, and when the app becomes active while the Accessories
    /// tab is shown: re-check permissions and fetch fresh state once.
    func popoverWillShow()
    /// Called when the accessory's popover card becomes visible or hidden, so any card-only work stops.
    func setCardVisible(_ visible: Bool)

    /// The device-specific Settings sections. The Accessories tab puts them in its form below the shared
    /// device section, and disables them while the device isn't available.
    func makeSettingsView() -> AnyView
}

/// How an accessory reaches the Mac.
enum AccessoryConnection: Equatable {
    case bluetooth
    case receiver
    case usbCable

    var title: String {
        switch self {
        case .bluetooth: return "Bluetooth"
        case .receiver: return "USB Receiver"
        case .usbCable: return "USB Cable"
        }
    }
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

// MARK: - Input Monitoring

/// Every HID++ accessory needs Input Monitoring to talk to its device. macOS posts no change notification,
/// so connectors re-check it when the popover opens or the app becomes active.
enum InputMonitoringPermission {
    static var isGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Shows the system prompt (off the main thread: it blocks until answered) and opens System Settings.
    static func request() {
        Task.detached(priority: .utility) {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Low Battery Alerts

/// One low-battery notification per discharge cycle, for every accessory. Connectors report each battery
/// change; nothing is polled.
@Observable
@MainActor
final class AccessoryBatteryAlerts {
    static let shared = AccessoryBatteryAlerts()

    private static let enabledKey = "accessoryLowBatteryAlert"
    private static let thresholdKey = "accessoryLowBatteryThreshold"
    private static let legacyMXOptionsKey = "mxMasterCardOptions"

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled && !oldValue {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        }
    }

    /// Battery percentage at or below which a notification is posted (5…50).
    var threshold: Int {
        didSet {
            UserDefaults.standard.set(threshold, forKey: Self.thresholdKey)
            alerted.removeAll()
        }
    }

    /// Accessories already notified in the current discharge cycle.
    @ObservationIgnored private var alerted: Set<String> = []

    private init() {
        let defaults = UserDefaults.standard
        // These settings used to belong to the MX Master; carry them over once.
        struct LegacyOptions: Decodable {
            var lowBatteryAlertEnabled: Bool?
            var lowBatteryThreshold: Int?
        }
        let legacy = defaults.data(forKey: Self.legacyMXOptionsKey)
            .flatMap { try? JSONDecoder().decode(LegacyOptions.self, from: $0) }
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? legacy?.lowBatteryAlertEnabled ?? true
        threshold = defaults.object(forKey: Self.thresholdKey) as? Int ?? legacy?.lowBatteryThreshold ?? 15
    }

    func report(id: String, name: String, percent: Int?, isCharging: Bool) {
        guard let percent else { return }
        if isCharging || percent > threshold {
            alerted.remove(id)
            return
        }
        guard isEnabled, !alerted.contains(id) else { return }
        alerted.insert(id)

        let content = UNMutableNotificationContent()
        content.title = "\(name) Battery Low"
        content.body = "Battery is at \(percent)%. Connect it to charge."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "lowBattery.\(id)", content: content, trigger: nil))
    }
}

// MARK: - Popover Cards

/// One card per connected accessory: name, connection and battery. Drawn the same for every accessory from
/// its connector's observable state, so cards appear and update as devices connect without polling.
struct AccessoryCardsView: View {
    var body: some View {
        ForEach(AccessoryRegistry.available, id: \.id) { connector in
            AccessoryCardHeader(
                systemImage: connector.systemImage,
                name: connector.accessoryName,
                status: connector.connection?.title ?? "Not connected",
                isOnline: connector.isAwake,
                batteryPercent: connector.batteryPercent,
                isCharging: connector.isCharging
            )
            .accessoryCardStyle()
        }
    }
}

// MARK: - Settings Tab

/// The Accessories tab: a selector (dimmed for accessories that aren't connected), the shared device section,
/// the accessory's own sections (disabled while it isn't connected) and the shared battery alert.
struct AccessoriesSettingsTabView: View {
    @AppStorage("selectedAccessorySettingsID") private var selectedID = ""
    @Bindable private var batteryAlerts = AccessoryBatteryAlerts.shared

    private var connectors: [any AccessoryConnector] { AccessoryRegistry.connectors }

    private var selected: (any AccessoryConnector)? {
        connectors.first { $0.id == selectedID } ?? connectors.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if connectors.count > 1 {
                AccessorySelector(connectors: connectors, selectedID: selected?.id) { selectedID = $0 }
                    .padding(.bottom, 8)
            }

            Form {
                if let selected {
                    deviceSection(selected)
                    selected.makeSettingsView()
                        .disabled(!selected.isAvailable)
                        .id(selected.id)
                } else {
                    ContentUnavailableView("No Supported Accessories", systemImage: "cable.connector")
                }
                batteryAlertSection
            }
            .formStyle(.grouped)
        }
        .task {
            // Permissions granted in System Settings are picked up when the user comes back.
            AccessoryRegistry.popoverWillShow()
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                AccessoryRegistry.popoverWillShow()
            }
        }
    }

    @ViewBuilder
    private func deviceSection(_ connector: any AccessoryConnector) -> some View {
        SettingsSection(title: "Device", footer: connector.isAvailable ? nil : "Connect the \(connector.displayName) to change its settings.") {
            HStack(spacing: 8) {
                StatusDot(isActive: connector.isAvailable && connector.isAwake)
                Text(connector.accessoryName)
                    .font(.headline)
            }
            LabeledContent("Connection", value: connectionText(connector))
            if let percent = connector.batteryPercent {
                LabeledContent("Battery", value: connector.isCharging ? "\(percent)% · Charging" : "\(percent)%")
            }
            if !InputMonitoringPermission.isGranted {
                PermissionNotice(
                    message: "Input Monitoring is needed to talk to the device.",
                    buttonTitle: "Open Settings…",
                    action: { InputMonitoringPermission.request() }
                )
            }
        }
    }

    private func connectionText(_ connector: any AccessoryConnector) -> String {
        guard connector.isAvailable, let connection = connector.connection else { return "Not connected" }
        return connector.isAwake ? connection.title : "\(connection.title) · Asleep"
    }

    private var batteryAlertSection: some View {
        SettingsSection(title: "Battery", footer: "Applies to every accessory. You're notified once per charge.") {
            Toggle("Low battery notification", isOn: $batteryAlerts.isEnabled)
            Stepper(value: $batteryAlerts.threshold, in: 5...50, step: 5) {
                LabeledContent("Notify at or below", value: "\(batteryAlerts.threshold)%")
            }
            .disabled(!batteryAlerts.isEnabled)
        }
    }
}

/// Segmented selector for accessories. Each shows a status dot, and is dimmed while not connected.
private struct AccessorySelector: View {
    let connectors: [any AccessoryConnector]
    let selectedID: String?
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(connectors, id: \.id) { connector in
                let isSelected = connector.id == selectedID
                Button {
                    onSelect(connector.id)
                } label: {
                    HStack(spacing: 6) {
                        StatusDot(isActive: connector.isAvailable && connector.isAwake)
                        Text(connector.displayName)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .opacity(connector.isAvailable ? 1 : 0.45)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityValue(connector.isAvailable ? "Connected" : "Not connected")
            }
        }
    }
}
