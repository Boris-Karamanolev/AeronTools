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
    /// The device runs on a battery, so Settings shows the shared battery alert. Defaults to true.
    var hasBattery: Bool { get }
    /// The device is reached through IOHIDManager, which needs Input Monitoring. Defaults to true.
    var needsInputMonitoring: Bool { get }

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

extension AccessoryConnector {
    var hasBattery: Bool { true }
    var needsInputMonitoring: Bool { true }
}

/// How an accessory reaches the Mac.
enum AccessoryConnection: Equatable {
    case bluetooth
    case receiver
    case usbCable
    case thunderbolt

    var title: String {
        switch self {
        case .bluetooth: return "Bluetooth"
        case .receiver: return "USB Receiver"
        case .usbCable: return "USB Cable"
        case .thunderbolt: return "Thunderbolt"
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
        MXKeyboardConnector.mxMechanical,
        MXKeyboardConnector.mxKeysMini,
        LogitechG515Connector.shared,
        KeychronM3MiniConnector.shared,
        RazerDockConnector.shared,
        SatechiHubConnector.shared,
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
                    .padding(.bottom, 4)
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
                if selected?.hasBattery ?? true {
                    batteryAlertSection
                }
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
            if connector.needsInputMonitoring && !InputMonitoringPermission.isGranted {
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

/// Accessory tiles, like the display picker in System Settings: an icon tile per accessory with its name and a
/// status dot below. Accessories that aren't connected are dimmed. Once the row no longer fits it scrolls
/// sideways, like the shelves in the App Store: with a trackpad, with a mouse wheel while the pointer is over the
/// row, or with the chevrons at its ends.
private struct AccessorySelector: View {
    let connectors: [any AccessoryConnector]
    let selectedID: String?
    let onSelect: (String) -> Void

    @State private var isHovering = false
    @State private var isAtStart = true
    @State private var isAtEnd = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            tiles
            scrollingTiles
        }
    }

    private var tiles: some View {
        HStack(spacing: 6) {
            ForEach(connectors, id: \.id) { connector in
                AccessoryTile(connector: connector, isSelected: connector.id == selectedID) {
                    onSelect(connector.id)
                }
                .id(connector.id)
            }
        }
        .padding(.vertical, 2)
    }

    private var scrollingTiles: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                tiles
                    .padding(.horizontal, 28)
            }
            .scrollIndicators(.never)
            .modifier(ScrollEdgeTracker(isAtStart: $isAtStart, isAtEnd: $isAtEnd))
            .onHover { isHovering = $0 }
            .modifier(VerticalWheelScrollsHorizontally(isActive: isHovering))
            .overlay(alignment: .leading) {
                if !isAtStart {
                    chevron("chevron.left", label: "Scroll Left") {
                        if let first = connectors.first { proxy.scrollTo(first.id, anchor: .leading) }
                    }
                }
            }
            .overlay(alignment: .trailing) {
                if !isAtEnd {
                    chevron("chevron.right", label: "Scroll Right") {
                        if let last = connectors.last { proxy.scrollTo(last.id, anchor: .trailing) }
                    }
                }
            }
            .onAppear {
                // Show the selected accessory, even when it's past the visible part of the row.
                if let selectedID { proxy.scrollTo(selectedID, anchor: .center) }
            }
        }
    }

    private func chevron(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25), action)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Follows whether a scroll view is scrolled to either end, so the chevrons can hide there. Needs macOS 15;
/// on earlier versions both chevrons stay visible.
private struct ScrollEdgeTracker: ViewModifier {
    @Binding var isAtStart: Bool
    @Binding var isAtEnd: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: [Bool].self) { geometry in
                let offset = geometry.contentOffset.x + geometry.contentInsets.leading
                let maxOffset = geometry.contentSize.width - geometry.containerSize.width
                return [offset <= 1, offset >= maxOffset - 1]
            } action: { _, edges in
                isAtStart = edges[0]
                isAtEnd = edges[1]
            }
        } else {
            content
        }
    }
}

/// While active, turns vertical scroll-wheel movement into horizontal scrolling. macOS only scrolls a horizontal
/// scroll view with Shift held or a sideways swipe, so this lets a plain mouse wheel move the row too. The event's
/// axes are swapped before it's delivered, so the scroll view keeps its own smooth scrolling and momentum.
private struct VerticalWheelScrollsHorizontally: ViewModifier {
    let isActive: Bool

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onChange(of: isActive, initial: true) { _, active in
                if active { install() } else { remove() }
            }
            .onDisappear { remove() }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            Self.swappingAxes(of: event) ?? event
        }
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// The same event scrolling sideways, or nil if it already scrolls sideways (or can't be rewritten).
    private static func swappingAxes(of event: NSEvent) -> NSEvent? {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX), let copy = event.cgEvent?.copy() else { return nil }
        // Line and pixel deltas are integer fields; the fixed-point delta is fractional.
        for (vertical, horizontal) in [(CGEventField.scrollWheelEventDeltaAxis1, CGEventField.scrollWheelEventDeltaAxis2),
                                       (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2)] {
            copy.setIntegerValueField(horizontal, value: copy.getIntegerValueField(vertical))
            copy.setIntegerValueField(vertical, value: 0)
        }
        copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: copy.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
        copy.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        return NSEvent(cgEvent: copy)
    }
}

private struct AccessoryTile: View {
    let connector: any AccessoryConnector
    let isSelected: Bool
    let action: () -> Void

    private var isActive: Bool { connector.isAvailable && connector.isAwake }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: connector.systemImage)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .frame(width: 60, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                                          lineWidth: isSelected ? 1.5 : 0.5)
                    )

                HStack(spacing: 4) {
                    StatusDot(isActive: isActive)
                    Text(connector.displayName)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: 82)
            }
            .frame(width: 84)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(connector.isAvailable ? 1 : 0.45)
        .help(connector.isAvailable ? connector.accessoryName : "\(connector.displayName) · Not connected")
        .accessibilityLabel(connector.displayName)
        .accessibilityValue(connector.isAvailable ? "Connected" : "Not connected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
