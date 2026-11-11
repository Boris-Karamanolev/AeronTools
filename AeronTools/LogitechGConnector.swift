import SwiftUI
import IOKit.hid

// MARK: - LogitechGConnector

/// Logitech G mice on a LIGHTSPEED receiver (e.g. PRO X2 SUPERSTRIKE). The receiver's pairing records name
/// the mouse even while it sleeps; once it's awake its full name, battery and feature list come over HID++.
///
/// DPI and report rate: the mouse normally runs from an onboard profile, which refuses changes. While the app
/// runs it switches the mouse to host mode (as G HUB does), applies the saved values, and hands it back to its
/// onboard profile when the app quits. Every setting is sent to this mouse only.
/// Fully event-driven: receiver attach/detach comes from IOHIDManager, the receiver reports the mouse
/// connecting or disconnecting, and the mouse pushes battery changes on its own.
@Observable
@MainActor
final class LogitechGConnector {
    static let shared = LogitechGConnector()

    /// LIGHTSPEED receiver product IDs. Bolt/Unifying receivers belong to the MX Master connector.
    nonisolated static let lightspeedReceiverIDs: [Int] = [0xC539, 0xC53A, 0xC53F, 0xC545, 0xC547, 0xC54D]
    /// LIGHTSPEED receivers host one device, in slot 1.
    private static let receiverSlot: UInt8 = 0x01

    private(set) var deviceName: String?
    /// The mouse is awake and answering; false while it sleeps (the receiver still knows it's paired).
    private(set) var isOnline = false
    private(set) var batteryPercent: Int?
    private(set) var isCharging = false
    /// Every HID++ feature the mouse reports, loaded when its Settings page is opened.
    private(set) var supportedFeatures: [UInt16] = []
    private(set) var isLoadingFeatures = false
    private(set) var hasInputMonitoringAccess = false

    // Performance (read from the mouse; nil until it has answered)
    private(set) var dpi: Int?
    private(set) var dpiRange: HIDPPProtocol.DPIRange?
    private(set) var reportRateHz: Int?
    private(set) var supportedReportRates: [Int] = []
    /// The mouse accepts DPI and report-rate changes: it's in host mode, or has no onboard profiles at all.
    private(set) var canControlPerformance = false
    /// The onboard profile the mouse returns to when the app quits.
    private(set) var onboardProfile: Int?

    @ObservationIgnored private var hidManager: IOHIDManager?
    @ObservationIgnored private var isManagerOpen = false
    @ObservationIgnored private var session: HIDPPSession?
    @ObservationIgnored private var identifyTask: Task<Void, Never>?
    @ObservationIgnored private var batteryFeature: (index: UInt8, isUnified: Bool)?
    @ObservationIgnored private var dpiFeatureIndex: UInt8?
    @ObservationIgnored private var reportRateFeatureIndex: UInt8?
    @ObservationIgnored private var onboardFeatureIndex: UInt8?
    @ObservationIgnored private var isInHostMode = false
    @ObservationIgnored private var liftOffDistance: UInt8 = 0

    private init() {}

    // MARK: Lifecycle

    fileprivate func setUp() {
        guard hidManager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Only the receivers' HID++ interface (vendor page 0xFF00), never their pointer interface,
        // so mouse movement is never delivered to this app.
        let matches: [[String: Any]] = Self.lightspeedReceiverIDs.map { productID in
            [
                kIOHIDVendorIDKey as String: HIDPPProtocol.logitechVendorID,
                kIOHIDProductIDKey as String: productID,
                kIOHIDDeviceUsagePageKey as String: 0xFF00
            ]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let connector = Unmanaged<LogitechGConnector>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { connector.refresh() }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let connector = Unmanaged<LogitechGConnector>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { connector.refresh() }
        }, context)
        IOHIDManagerRegisterInputReportCallback(manager, { context, _, sender, _, reportID, report, length in
            guard let context, let sender, length > 0,
                  reportID == HIDPPProtocol.shortReportID || reportID == HIDPPProtocol.longReportID else { return }
            var bytes = Array(UnsafeBufferPointer(start: report, count: length))
            if bytes.first != UInt8(reportID) {
                bytes.insert(UInt8(reportID), at: 0)
            }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            let connector = Unmanaged<LogitechGConnector>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { connector.handle(report: bytes, from: device) }
        }, context)

        // The input-report callbacks run on the main run loop, which is why they can assume main-actor isolation.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        hidManager = manager
        openIfPermitted()
    }

    /// Opening without Input Monitoring would show a blocking permission prompt, so wait until it's granted.
    /// The MX Master connector requests the permission; this one picks up the grant when the popover opens.
    private func openIfPermitted() {
        hasInputMonitoringAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        guard let hidManager, hasInputMonitoringAccess, !isManagerOpen else { return }
        let result = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        isManagerOpen = result == kIOReturnSuccess
        if !isManagerOpen {
            dlog(String(format: "Logitech G: IOHIDManagerOpen returned 0x%08x", result))
        }
        refresh()
    }

    // MARK: Device State

    /// Re-reads which receiver is attached and asks the mouse on it who it is.
    fileprivate func refresh() {
        guard isManagerOpen,
              let devices = hidManager.flatMap({ IOHIDManagerCopyDevices($0) as? Set<IOHIDDevice> }),
              let receiver = devices.first else {
            clearDevice()
            return
        }
        var isNewReceiver = false
        if session?.device !== receiver {
            session = HIDPPSession(device: receiver, deviceIndex: Self.receiverSlot)
            session?.onEvent = { [weak self] event in self?.handle(event: event) }
            isNewReceiver = true
        }
        identify(enablingNotifications: isNewReceiver)
    }

    private func identify(enablingNotifications: Bool = false) {
        guard let session else { return }
        identifyTask?.cancel()
        identifyTask = Task { [weak self] in
            if enablingNotifications {
                await session.enableReceiverConnectionNotifications()
            }
            // 1. The receiver says what's paired, even while the mouse sleeps. Nothing paired, or not a mouse: no card.
            guard let paired = await session.receiverPairedDevice(), paired.isPointingDevice else {
                guard let self, self.session === session else { return }
                self.clearDevice(keepSession: true)
                return
            }
            guard let self, !Task.isCancelled, self.session === session else { return }
            if self.deviceName == nil {
                self.deviceName = paired.name
            }

            // 2. If the mouse is awake it answers over HID++ 2.0 with its full name and battery.
            // Feature indices differ between mice, so never reuse ones learned from a previously paired device.
            session.reset()
            guard let identity = await session.identify(), !Task.isCancelled, self.session === session else {
                self.isOnline = false
                return
            }
            self.isOnline = true
            self.deviceName = identity.name
            await self.loadBattery(using: session)
            // Also runs after every reconnect: the mouse drops back to its onboard profile when it powers off.
            await self.takeControl(using: session)
        }
    }

    // MARK: Performance (DPI & Report Rate)

    /// Switches the mouse to host mode, reads its DPI and report-rate capabilities, then applies the saved values.
    private func takeControl(using session: HIDPPSession) async {
        dpiFeatureIndex = await session.featureIndex(for: HIDPPProtocol.featureExtendedDPI)
        reportRateFeatureIndex = await session.featureIndex(for: HIDPPProtocol.featureExtendedReportRate)
        onboardFeatureIndex = await session.featureIndex(for: HIDPPProtocol.featureOnboardProfiles)

        if let onboard = onboardFeatureIndex {
            // getCurrentProfile (function 4): [4…5] profile number.
            if let reply = await session.request(featureIndex: onboard, function: 0x04) {
                onboardProfile = (Int(reply[4]) << 8) | Int(reply[5])
            }
            // setOnboardMode (function 1).
            let reply = await session.request(featureIndex: onboard, function: 0x01, params: [HIDPPProtocol.OnboardMode.host.rawValue])
            isInHostMode = reply != nil
            canControlPerformance = isInHostMode
        } else {
            canControlPerformance = true
        }

        if let index = dpiFeatureIndex {
            var pages: [[UInt8]] = []
            for page in 0..<12 {
                guard let reply = await session.request(featureIndex: index, function: 0x02, params: [0x00, 0x00, UInt8(page)]) else { break }
                pages.append(reply)
                if HIDPPProtocol.dpiRangePageEndsList(reply) { break }
            }
            dpiRange = HIDPPProtocol.parseDPIRanges(pages: pages)
            if let reply = await session.request(featureIndex: index, function: 0x05, params: [0x00]),
               let sensor = HIDPPProtocol.parseSensorDPI(reply) {
                dpi = sensor.dpi
                liftOffDistance = sensor.liftOffDistance
            }
        }

        if let index = reportRateFeatureIndex {
            if let reply = await session.request(featureIndex: index, function: 0x01) {
                supportedReportRates = HIDPPProtocol.parseSupportedReportRates(reply)
            }
            if let reply = await session.request(featureIndex: index, function: 0x02) {
                reportRateHz = HIDPPProtocol.parseReportRate(reply)
            }
        }

        guard canControlPerformance else { return }
        if let saved = savedSetting("dpi"), saved != dpi {
            setDPI(saved)
        }
        if let saved = savedSetting("reportRate"), saved != reportRateHz {
            setReportRate(saved)
        }
    }

    /// Sets the sensor's DPI, snapped to a value it supports, and remembers it for this mouse.
    func setDPI(_ requested: Int) {
        guard let session, let index = dpiFeatureIndex, canControlPerformance else { return }
        let value = dpiRange?.nearestSupported(requested) ?? requested
        saveSetting("dpi", value)
        Task { [weak self] in
            let reply = await session.request(
                featureIndex: index, function: 0x06,
                params: HIDPPProtocol.setSensorDPIParams(dpi: value, liftOffDistance: self?.liftOffDistance ?? 0)
            )
            guard let self, self.session === session, reply != nil else { return }
            self.dpi = value
        }
    }

    /// Sets the report (polling) rate and remembers it for this mouse.
    func setReportRate(_ hz: Int) {
        guard let session, let index = reportRateFeatureIndex, canControlPerformance,
              supportedReportRates.contains(hz), let rateIndex = HIDPPProtocol.reportRateIndex(forHz: hz) else { return }
        saveSetting("reportRate", hz)
        Task { [weak self] in
            let reply = await session.request(featureIndex: index, function: 0x03, params: [rateIndex])
            guard let self, self.session === session, reply != nil else { return }
            self.reportRateHz = hz
        }
    }

    /// Hands the mouse back to its onboard profile, so it behaves as configured in G HUB without the app.
    fileprivate func releaseControl() {
        guard let session, let index = onboardFeatureIndex, isInHostMode else { return }
        session.sendWithoutReply(featureIndex: index, function: 0x01, params: [HIDPPProtocol.OnboardMode.onboard.rawValue])
        isInHostMode = false
    }

    /// Settings are stored per mouse model, so another G mouse on the receiver starts from its own values.
    private func settingsKey(_ name: String) -> String? {
        deviceName.map { "logitechG.\($0).\(name)" }
    }

    private func savedSetting(_ name: String) -> Int? {
        settingsKey(name).flatMap { UserDefaults.standard.object(forKey: $0) as? Int }
    }

    private func saveSetting(_ name: String, _ value: Int) {
        if let key = settingsKey(name) {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    private func loadBattery(using session: HIDPPSession) async {
        if let index = await session.featureIndex(for: HIDPPProtocol.featureUnifiedBattery) {
            batteryFeature = (index, true)
            // UnifiedBattery.getStatus is function 1.
            if let reply = await session.request(featureIndex: index, function: 0x01) {
                apply(batteryReply: reply)
            }
        } else if let index = await session.featureIndex(for: HIDPPProtocol.featureBatteryStatus) {
            batteryFeature = (index, false)
            if let reply = await session.request(featureIndex: index, function: 0x00) {
                apply(batteryReply: reply)
            }
        }
    }

    private func apply(batteryReply: [UInt8]) {
        guard let feature = batteryFeature,
              let reading = HIDPPProtocol.parseBatteryReply(
                  batteryReply, expectedFeatureIndex: feature.index, isUnifiedBattery: feature.isUnified
              ) else { return }
        if batteryPercent != reading.percentage { batteryPercent = reading.percentage }
        if isCharging != reading.isCharging { isCharging = reading.isCharging }
    }

    private func clearDevice(keepSession: Bool = false) {
        if !keepSession {
            identifyTask?.cancel()
            session = nil
        }
        batteryFeature = nil
        dpiFeatureIndex = nil
        reportRateFeatureIndex = nil
        onboardFeatureIndex = nil
        isInHostMode = false
        dpi = nil
        dpiRange = nil
        reportRateHz = nil
        supportedReportRates = []
        canControlPerformance = false
        onboardProfile = nil
        deviceName = nil
        isOnline = false
        batteryPercent = nil
        isCharging = false
        supportedFeatures = []
    }

    // MARK: Incoming Reports

    private func handle(report: [UInt8], from device: IOHIDDevice) {
        guard let session, session.device === device else { return }
        session.handle(report: report)
    }

    private func handle(event: [UInt8]) {
        // HID++ 1.0 "device connection" notification from the receiver: the mouse woke, slept, or re-paired.
        // Byte 4 bit 6 set means the link is down.
        if event[2] == 0x41 {
            if event[4] & 0x40 != 0 {
                isOnline = false
                // The mouse returns to its onboard profile when it powers off; host mode is re-entered on reconnect.
                isInHostMode = false
                canControlPerformance = false
            } else {
                identify()
            }
            return
        }
        // Battery changes the mouse pushes on its own (same layout as the getStatus reply).
        if let feature = batteryFeature, event[2] == feature.index {
            apply(batteryReply: event)
        }
    }

    // MARK: Feature List

    /// Loads the full feature list for the Settings page, so unsupported features can be identified and added.
    func loadFeatureList() {
        guard let session, isOnline, supportedFeatures.isEmpty, !isLoadingFeatures else { return }
        isLoadingFeatures = true
        Task { [weak self] in
            let features = await session.enumerateFeatures()
            guard let self, self.session === session else { return }
            self.supportedFeatures = features
            self.isLoadingFeatures = false
        }
    }
}

// MARK: - AccessoryConnector

extension LogitechGConnector: AccessoryConnector {
    var id: String { "logitech.g-mouse" }
    var displayName: String { "Logitech G" }
    var systemImage: String { "computermouse" }

    var isAvailable: Bool { deviceName != nil }

    func start() {
        setUp()
    }

    /// Returns the mouse to its onboard profile.
    func stop() {
        releaseControl()
    }

    func systemDidWake() {
        refresh()
    }

    func popoverWillShow() {
        // Picks up an Input Monitoring grant made in System Settings, then re-identifies the mouse once.
        if isManagerOpen {
            refresh()
        } else {
            openIfPermitted()
        }
    }

    /// Nothing runs on a timer, so there's no card-only work to start or stop.
    func setCardVisible(_ visible: Bool) {}

    func makeCardView() -> AnyView {
        AnyView(LogitechGCardView(connector: self))
    }

    func makeSettingsView() -> AnyView {
        AnyView(LogitechGSettingsView(connector: self))
    }
}

// MARK: - Popover Card

private struct LogitechGCardView: View {
    let connector: LogitechGConnector

    var body: some View {
        AccessoryCardHeader(
            systemImage: "computermouse.fill",
            name: connector.deviceName ?? "Logitech G",
            status: status,
            isOnline: connector.isOnline,
            batteryPercent: connector.batteryPercent,
            isCharging: connector.isCharging
        )
        .accessoryCardStyle()
    }

    private var status: String {
        guard connector.isOnline else { return "Asleep · LIGHTSPEED Receiver" }
        let readings = [connector.dpi.map { "\($0) DPI" }, connector.reportRateHz.map(LogitechGSettingsView.rateLabel)]
            .compactMap { $0 }
        return readings.isEmpty ? "LIGHTSPEED Receiver" : readings.joined(separator: " · ")
    }
}

// MARK: - Settings Page

private struct LogitechGSettingsView: View {
    let connector: LogitechGConnector
    @State private var dpiText = ""

    private static let dpiPresets = [400, 800, 1600, 3200, 6400]

    nonisolated static func rateLabel(_ hz: Int) -> String {
        hz >= 1000 ? "\(hz / 1000) kHz" : "\(hz) Hz"
    }

    var body: some View {
        Form {
            Section("Device") {
                LabeledContent("Mouse", value: connector.deviceName ?? "Not connected")
                LabeledContent("Connection", value: connector.deviceName == nil ? "—"
                    : connector.isOnline ? "LIGHTSPEED Receiver" : "Asleep (LIGHTSPEED Receiver)")
                if let percent = connector.batteryPercent {
                    LabeledContent("Battery", value: connector.isCharging ? "\(percent)% · Charging" : "\(percent)%")
                }
                if !connector.hasInputMonitoringAccess {
                    Text("Input Monitoring permission is needed to talk to the mouse. Grant it from the MX Master page or System Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if connector.isOnline && (connector.dpi != nil || connector.reportRateHz != nil) {
                performanceSection
            }

            if connector.isOnline {
                Section {
                    if connector.isLoadingFeatures {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        ForEach(connector.supportedFeatures, id: \.self) { featureID in
                            LabeledContent(HIDPPProtocol.featureName(featureID), value: String(format: "0x%04X", featureID))
                        }
                    }
                } header: {
                    Text("Supported HID++ Features")
                } footer: {
                    Text("Controls such as the haptic buttons will be added once their features are identified from this list.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { connector.loadFeatureList() }
        .onChange(of: connector.isOnline) { _, isOnline in
            if isOnline { connector.loadFeatureList() }
        }
        .onChange(of: connector.dpi, initial: true) { _, dpi in
            dpiText = dpi.map(String.init) ?? ""
        }
    }

    @ViewBuilder
    private var performanceSection: some View {
        Section {
            if let dpi = connector.dpi {
                LabeledContent("DPI") {
                    HStack(spacing: 6) {
                        ForEach(Self.dpiPresets.filter { preset in
                            connector.dpiRange.map { (($0.minimum)...($0.maximum)).contains(preset) } ?? true
                        }, id: \.self) { preset in
                            Button(String(preset)) { connector.setDPI(preset) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(dpi == preset ? .accentColor : nil)
                        }
                        TextField("DPI", text: $dpiText)
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                            .onSubmit {
                                if let value = Int(dpiText.trimmingCharacters(in: .whitespaces)) {
                                    connector.setDPI(value)
                                }
                            }
                    }
                    .disabled(!connector.canControlPerformance)
                }
            }

            if let rate = connector.reportRateHz, !connector.supportedReportRates.isEmpty {
                Picker("Report Rate", selection: Binding(get: { rate }, set: { connector.setReportRate($0) })) {
                    ForEach(connector.supportedReportRates, id: \.self) { hz in
                        Text(Self.rateLabel(hz)).tag(hz)
                    }
                }
                .disabled(!connector.canControlPerformance)
            }
        } header: {
            Text("Performance")
        } footer: {
            if let range = connector.dpiRange {
                Text(controlFooter + " DPI \(range.minimum)–\(range.maximum).")
            } else {
                Text(controlFooter)
            }
        }
    }

    private var controlFooter: String {
        guard connector.canControlPerformance else {
            return "The mouse is running from its onboard profile, so these can't be changed right now."
        }
        let profile = connector.onboardProfile.map { " \($0)" } ?? ""
        return "While Aeron Tools runs it controls the mouse directly, like G HUB. When it quits, the mouse returns to onboard profile\(profile)."
    }
}
