import SwiftUI
import IOKit.hid

// MARK: - MXMechanicalConnector

/// Logitech MX Mechanical keyboards (e.g. MX Mechanical Mini for Mac) on a Logi Bolt or Unifying receiver.
/// Bolt receivers host several devices, so every slot's pairing record is checked and the keyboard is found by
/// name. The receiver answers for the keyboard while it sleeps; once awake, its full name and battery come
/// over HID++. Event-driven: receiver attach/detach, the receiver reporting the keyboard waking or sleeping,
/// and battery changes the keyboard pushes on its own.
@Observable
@MainActor
final class MXMechanicalConnector {
    static let shared = MXMechanicalConnector()

    nonisolated static let receiverIDs = [HIDPPProtocol.boltReceiverProductID, HIDPPProtocol.unifyingReceiverProductID]
    private static let slots: ClosedRange<UInt8> = 1...6

    private(set) var deviceName: String?
    /// The keyboard is awake and answering; false while it sleeps (the receiver still knows it's paired).
    private(set) var isOnline = false
    private(set) var batteryPercent: Int?
    private(set) var isCharging = false
    /// The backlight configuration as the keyboard last reported it; nil until it has answered.
    private(set) var backlight: HIDPPProtocol.BacklightConfig?
    /// The keyboard can't report its effect, so this is the last one chosen here.
    private(set) var backlightEffect: HIDPPProtocol.BacklightEffect? = UserDefaults.standard.object(forKey: "mxMechanical.backlightEffect")
        .flatMap { $0 as? Int }.flatMap { HIDPPProtocol.BacklightEffect(rawValue: UInt8(clamping: $0)) }

    @ObservationIgnored private let monitor = HIDPPReceiverMonitor(productIDs: receiverIDs)
    @ObservationIgnored private var session: HIDPPSession?
    @ObservationIgnored private var identifyTask: Task<Void, Never>?
    @ObservationIgnored private var batteryFeature: HIDPPSession.BatteryFeature?
    @ObservationIgnored private var backlightIndex: UInt8?

    private init() {}

    /// The receiver abbreviates the name (e.g. "MX MCHNCL M"); the keyboard itself reports it in full.
    nonisolated static func isMXMechanical(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("mx mchncl") || lower.contains("mx mechanical")
    }

    // MARK: Lifecycle

    fileprivate func setUp() {
        monitor.onReceiversChanged = { [weak self] in self?.refresh() }
        monitor.onReport = { [weak self] report, device in
            guard let self, let session = self.session, session.device === device else { return }
            session.handle(report: report)
        }
        monitor.start()
        refresh()
    }

    /// Re-reads which receiver is attached and finds the keyboard on it.
    fileprivate func refresh() {
        guard let receiver = monitor.receivers.first else {
            clearDevice()
            return
        }
        identify(on: receiver, enablingNotifications: session?.device !== receiver)
    }

    private func identify(on receiver: IOHIDDevice, enablingNotifications: Bool) {
        identifyTask?.cancel()
        identifyTask = Task { [weak self] in
            guard let self else { return }
            let family: HIDPPSession.ReceiverFamily =
                HIDPPReceiverMonitor.productID(of: receiver) == HIDPPProtocol.boltReceiverProductID ? .bolt : .unifying

            // 1. Find the keyboard's slot from the pairing records; the receiver answers even while it sleeps.
            var found: (slot: UInt8, name: String)?
            for slot in Self.slots {
                let probe = HIDPPSession(device: receiver, deviceIndex: slot)
                self.session = probe
                if enablingNotifications && slot == Self.slots.lowerBound {
                    await probe.enableReceiverConnectionNotifications()
                }
                if let paired = await probe.receiverPairedDevice(family: family),
                   paired.kind == .keyboard, Self.isMXMechanical(paired.name) {
                    found = (slot, paired.name)
                    break
                }
                guard !Task.isCancelled else { return }
            }
            guard !Task.isCancelled else { return }
            guard let found else {
                self.clearDevice()
                return
            }

            let session = HIDPPSession(device: receiver, deviceIndex: found.slot)
            session.onEvent = { [weak self] event in self?.handle(event: event) }
            self.session = session
            if self.deviceName == nil {
                self.deviceName = found.name
            }

            // 2. Awake, the keyboard answers with its full name and battery.
            guard let identity = await session.identify(), !Task.isCancelled, self.session === session else {
                self.isOnline = false
                return
            }
            self.isOnline = true
            self.deviceName = identity.name
            self.batteryFeature = await session.batteryFeature()
            if let feature = self.batteryFeature, let reading = await session.readBattery(feature) {
                self.apply(reading)
            }
            await self.loadBacklight(using: session)
        }
    }

    // MARK: Backlight

    private func loadBacklight(using session: HIDPPSession) async {
        backlightIndex = await session.featureIndex(for: HIDPPProtocol.featureBacklight)
        await readBacklight(using: session)
    }

    private func readBacklight(using session: HIDPPSession) async {
        guard let index = backlightIndex,
              let reply = await session.request(featureIndex: index, function: 0x00),
              self.session === session else { return }
        backlight = HIDPPProtocol.parseBacklightConfig(reply)
    }

    /// Writes a configuration, then reads it back so Settings always shows what the keyboard actually uses.
    func setBacklight(_ config: HIDPPProtocol.BacklightConfig) {
        guard let session, let index = backlightIndex else { return }
        Task { [weak self] in
            _ = await session.request(featureIndex: index, function: 0x01, params: HIDPPProtocol.setBacklightConfigParams(config))
            await self?.readBacklight(using: session)
        }
    }

    func setBacklightEffect(_ effect: HIDPPProtocol.BacklightEffect) {
        guard let session, let index = backlightIndex else { return }
        Task { [weak self] in
            guard await session.request(featureIndex: index, function: 0x03, params: [effect.rawValue]) != nil,
                  let self, self.session === session else { return }
            self.backlightEffect = effect
            UserDefaults.standard.set(Int(effect.rawValue), forKey: "mxMechanical.backlightEffect")
        }
    }

    private func apply(_ reading: HIDPPProtocol.BatteryReading) {
        if batteryPercent != reading.percentage { batteryPercent = reading.percentage }
        if isCharging != reading.isCharging { isCharging = reading.isCharging }
        AccessoryBatteryAlerts.shared.report(id: id, name: accessoryName, percent: batteryPercent, isCharging: isCharging)
    }

    private func clearDevice() {
        identifyTask?.cancel()
        session = nil
        batteryFeature = nil
        backlightIndex = nil
        backlight = nil
        deviceName = nil
        isOnline = false
        batteryPercent = nil
        isCharging = false
    }

    // MARK: Incoming Reports

    private func handle(event: [UInt8]) {
        // HID++ 1.0 device-connection notification from the receiver: byte 4 bit 6 set means the link is down.
        if event[2] == 0x41 {
            if event[4] & 0x40 != 0 {
                isOnline = false
            } else if let receiver = session?.device {
                identify(on: receiver, enablingNotifications: false)
            }
            return
        }
        if let feature = batteryFeature, let reading = HIDPPSession.batteryReading(from: event, feature: feature) {
            apply(reading)
            return
        }
        // The backlight keys change the configuration on the keyboard itself; re-read it when it says so.
        if let index = backlightIndex, event[2] == index, let session {
            Task { await self.readBacklight(using: session) }
        }
    }
}

// MARK: - AccessoryConnector

extension MXMechanicalConnector: AccessoryConnector {
    var id: String { "logitech.mx-mechanical" }
    var displayName: String { "MX Mechanical" }
    var systemImage: String { "keyboard" }

    var isAvailable: Bool { deviceName != nil }
    var accessoryName: String { deviceName ?? displayName }
    var connection: AccessoryConnection? { isAvailable ? .receiver : nil }
    var isAwake: Bool { isOnline }

    func start() {
        setUp()
    }

    /// Nothing is taken over from macOS yet, so there's nothing to hand back.
    func stop() {}

    func systemDidWake() {
        refresh()
    }

    func popoverWillShow() {
        if monitor.isOpen || monitor.openIfPermitted() {
            refresh()
        }
    }

    func setCardVisible(_ visible: Bool) {}

    func makeSettingsView() -> AnyView {
        AnyView(MXMechanicalSettingsView(connector: self))
    }
}

// MARK: - Settings Sections

/// The MX Mechanical page: keyboard-specific sections only. The Accessories tab adds the device section and
/// battery alerts, and disables everything while the keyboard isn't connected.
private struct MXMechanicalSettingsView: View {
    let connector: MXMechanicalConnector

    private static let durations = [5, 10, 15, 30, 45, 60, 90, 120, 180, 300]

    var body: some View {
        if connector.isOnline, let backlight = connector.backlight {
            backlightSection(backlight)
        }
    }

    private func backlightSection(_ backlight: HIDPPProtocol.BacklightConfig) -> some View {
        SettingsSection(title: "Backlight", footer: "Battery saving turns the backlight off below 10% battery. The keyboard's own backlight keys still work.") {
            Toggle("Backlight", isOn: binding(backlight, \.isEnabled))
            Group {
                Picker("Effect", selection: Binding(
                    get: { connector.backlightEffect },
                    set: { if let effect = $0 { connector.setBacklightEffect(effect) } }
                )) {
                    if connector.backlightEffect == nil {
                        Text("Not set").tag(HIDPPProtocol.BacklightEffect?.none)
                    }
                    ForEach(HIDPPProtocol.BacklightEffect.allCases) { effect in
                        Text(effect.title).tag(Optional(effect))
                    }
                }
                Toggle("Automatic brightness", isOn: binding(backlight, \.isAutomaticBrightness))
                if !backlight.isAutomaticBrightness {
                    LevelSlider(title: "Brightness", value: Int(backlight.level), range: 1...8) { level in
                        var config = backlight
                        config.level = UInt8(level)
                        connector.setBacklight(config)
                    }
                }
                Picker("Turn off after", selection: binding(backlight, \.durationSeconds)) {
                    ForEach(Self.durations, id: \.self) { seconds in
                        Text(seconds < 60 ? "\(seconds) sec" : "\(seconds / 60) min").tag(seconds)
                    }
                    if !Self.durations.contains(backlight.durationSeconds) {
                        Text("\(backlight.durationSeconds) sec").tag(backlight.durationSeconds)
                    }
                }
                Toggle("Battery saving", isOn: binding(backlight, \.isBatterySaving))
            }
            .disabled(!backlight.isEnabled)
        }
    }

    /// A binding that edits one field of the current configuration and writes the whole configuration.
    private func binding<Value>(_ backlight: HIDPPProtocol.BacklightConfig,
                                _ keyPath: WritableKeyPath<HIDPPProtocol.BacklightConfig, Value>) -> Binding<Value> {
        Binding(
            get: { backlight[keyPath: keyPath] },
            set: { value in
                var config = backlight
                config[keyPath: keyPath] = value
                connector.setBacklight(config)
            }
        )
    }
}
