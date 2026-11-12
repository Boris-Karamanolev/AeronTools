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

    // Performance (read from the mouse; nil until it has answered)
    private(set) var dpi: Int?
    private(set) var dpiRange: HIDPPProtocol.DPIRange?
    private(set) var reportRateHz: Int?
    private(set) var supportedReportRates: [Int] = []
    /// The mouse accepts DPI and report-rate changes: it's in host mode, or has no onboard profiles at all.
    private(set) var canControlPerformance = false
    /// The onboard profile the mouse returns to when the app quits.
    private(set) var onboardProfile: Int?
    /// Analog trigger settings (actuation, rapid trigger, haptics), applied to both keys. Nil if unsupported.
    private(set) var triggerSettings: HIDPPProtocol.TriggerSettings?
    private(set) var triggerLimits: HIDPPProtocol.TriggerLimits?
    /// Side button actions. Nil until the mouse is controllable and reports Mouse Button Spy.
    private(set) var sideButtons: SideButtons?

    /// Save DPI, report rate and triggers into the mouse's first onboard profile, so it keeps them without the app.
    var savesToOnboardProfile: Bool = UserDefaults.standard.object(forKey: "logitechG.saveToOnboardProfile") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(savesToOnboardProfile, forKey: "logitechG.saveToOnboardProfile")
            if savesToOnboardProfile { scheduleProfileSave() }
        }
    }
    private(set) var profileSaveState: ProfileSaveState = .idle

    enum ProfileSaveState: Equatable {
        case idle
        case saving
        case saved(profile: Int)
        case failed(String)
    }

    struct SideButtons: Codable, Equatable {
        var back: AccessoryButtonAction = .systemDefault
        var forward: AccessoryButtonAction = .systemDefault
    }

    @ObservationIgnored private let monitor = HIDPPReceiverMonitor(productIDs: lightspeedReceiverIDs)
    @ObservationIgnored private var session: HIDPPSession?
    @ObservationIgnored private var identifyTask: Task<Void, Never>?
    @ObservationIgnored private var batteryFeature: HIDPPSession.BatteryFeature?
    @ObservationIgnored private var dpiFeatureIndex: UInt8?
    @ObservationIgnored private var reportRateFeatureIndex: UInt8?
    @ObservationIgnored private var onboardFeatureIndex: UInt8?
    @ObservationIgnored private var triggerFeatureIndex: UInt8?
    @ObservationIgnored private var spyFeatureIndex: UInt8?
    @ObservationIgnored private var buttonCount = 0
    /// Press reporting is on and remapped side buttons are silenced to macOS.
    @ObservationIgnored private var isSpying = false
    @ObservationIgnored private var lastButtonMask: UInt16 = 0
    @ObservationIgnored private var profileSaveTask: Task<Void, Never>?
    @ObservationIgnored private var isInHostMode = false
    @ObservationIgnored private var liftOffDistance: UInt8 = 0

    private init() {}

    // MARK: Lifecycle

    fileprivate func setUp() {
        monitor.onReceiversChanged = { [weak self] in self?.refresh() }
        monitor.onReport = { [weak self] report, device in self?.handle(report: report, from: device) }
        monitor.start()
        refresh()
    }

    // MARK: Device State

    /// Re-reads which receiver is attached and asks the mouse on it who it is.
    fileprivate func refresh() {
        guard let receiver = monitor.receivers.first else {
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
            #if DEBUG
            if HIDPPTrace.isEnabled { return }
            #endif
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

        // The mouse has no trigger getter, so the app always applies known values: the saved ones, or the
        // onboard profile's on first use. That keeps what Settings shows in line with the mouse.
        triggerFeatureIndex = await session.featureIndex(for: HIDPPProtocol.featureAnalogTriggers)
        if let index = triggerFeatureIndex,
           let reply = await session.request(featureIndex: index, function: 0x00) {
            triggerLimits = HIDPPProtocol.parseTriggerLimits(reply)
        }

        spyFeatureIndex = await session.featureIndex(for: HIDPPProtocol.featureMouseButtonSpy)
        if let index = spyFeatureIndex, let reply = await session.request(featureIndex: index, function: 0x00) {
            buttonCount = Int(reply[4])
        }

        guard canControlPerformance else { return }
        if triggerFeatureIndex != nil {
            setTriggerSettings(savedTriggerSettings ?? .profileDefault)
        }
        if spyFeatureIndex != nil, buttonCount >= HIDPPProtocol.forwardSideButton {
            setSideButtons(savedSideButtons ?? SideButtons())
        }
        scheduleProfileSave()
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
            self.scheduleProfileSave()
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
            self.scheduleProfileSave()
        }
    }

    /// Applies trigger settings to both keys (per-key settings are intentionally not offered) and remembers them.
    func setTriggerSettings(_ requested: HIDPPProtocol.TriggerSettings) {
        guard let session, let index = triggerFeatureIndex, canControlPerformance else { return }
        var settings = requested
        if let limits = triggerLimits {
            settings.actuation = min(max(settings.actuation, 1), limits.maxActuation)
            settings.rapidTrigger = min(max(settings.rapidTrigger, 0), limits.maxRapidTrigger)
            settings.haptics = min(max(settings.haptics, 0), limits.maxHaptics)
        }
        if let data = try? JSONEncoder().encode(settings), let key = settingsKey(Self.triggerSettingsKey) {
            UserDefaults.standard.set(data, forKey: key)
        }
        Task { [weak self] in
            var applied = true
            for key: UInt8 in [0x00, 0x01] {
                let reply = await session.request(
                    featureIndex: index, function: 0x01,
                    params: HIDPPProtocol.setTriggerParams(key: key, settings)
                )
                applied = applied && reply != nil
            }
            guard let self, self.session === session, applied else { return }
            self.triggerSettings = settings
            self.scheduleProfileSave()
        }
    }

    /// v2: rapid trigger 0 means off. v1 never set the on bit, so its rapid trigger was always off in practice.
    private static let triggerSettingsKey = "triggers.v2"

    private var savedTriggerSettings: HIDPPProtocol.TriggerSettings? {
        let decoder = JSONDecoder()
        if let key = settingsKey(Self.triggerSettingsKey), let data = UserDefaults.standard.data(forKey: key) {
            return try? decoder.decode(HIDPPProtocol.TriggerSettings.self, from: data)
        }
        guard let key = settingsKey("triggers"), let data = UserDefaults.standard.data(forKey: key),
              var legacy = try? decoder.decode(HIDPPProtocol.TriggerSettings.self, from: data) else { return nil }
        legacy.rapidTrigger = 0
        return legacy
    }

    // MARK: Onboard Profile

    /// Saves a few seconds after the last change, so adjusting a slider writes the mouse's memory once.
    private func scheduleProfileSave() {
        guard savesToOnboardProfile, canControlPerformance, onboardFeatureIndex != nil else { return }
        profileSaveTask?.cancel()
        profileSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            await self.saveToOnboardProfile()
        }
    }

    /// Writes DPI, report rate and triggers into the first onboard profile. Only those bytes change; the sector
    /// must verify before it's touched, is read back after writing, and is restored if the read-back differs.
    private func saveToOnboardProfile() async {
        guard let session, let index = onboardFeatureIndex else { return }
        profileSaveState = .saving

        guard let infoReply = await session.request(featureIndex: index, function: 0x00),
              let info = HIDPPProtocol.parseOnboardProfilesInfo(infoReply),
              info.profileFormat == HIDPPProtocol.supportedProfileFormat else {
            profileSaveState = .failed("This mouse's profile format isn't supported.")
            return
        }

        var directory: [UInt8] = []
        for offset in [0, 16] {
            guard let reply = await session.request(
                featureIndex: index, function: 0x05, params: HIDPPProtocol.readMemoryParams(sector: 0, offset: offset)
            ) else {
                profileSaveState = .failed("Couldn't read the mouse's profile list.")
                return
            }
            directory += reply[4..<20]
        }
        guard let sector = HIDPPProtocol.firstEnabledProfileSector(directory: directory) else {
            profileSaveState = .failed("The mouse has no enabled onboard profile.")
            return
        }

        guard let original = await readSector(sector, size: info.sectorSize, session: session, index: index) else {
            profileSaveState = .failed("Couldn't read the onboard profile.")
            return
        }
        let settings = HIDPPProtocol.ProfileSettings(dpi: dpi, reportRateHz: reportRateHz, triggers: triggerSettings)
        guard let patched = HIDPPProtocol.patchedProfileSector(original, with: settings) else {
            profileSaveState = .failed("The onboard profile didn't pass its checksum, so it was left untouched.")
            return
        }

        let profile = Int(sector)
        guard patched != original else {
            profileSaveState = .saved(profile: profile)
            return
        }

        if await writeSector(sector, patched, session: session, index: index),
           await readSector(sector, size: info.sectorSize, session: session, index: index) == patched {
            profileSaveState = .saved(profile: profile)
        } else {
            // Put the original back so the mouse never keeps a half-written profile.
            _ = await writeSector(sector, original, session: session, index: index)
            profileSaveState = .failed("Saving to the mouse didn't verify, so its profile was restored.")
            dlog("Logitech G: onboard profile write failed verification; original restored")
        }
    }

    private func readSector(_ sector: UInt16, size: Int, session: HIDPPSession, index: UInt8) async -> [UInt8]? {
        var chunks: [[UInt8]] = []
        for offset in HIDPPProtocol.sectorReadOffsets(sectorSize: size) {
            guard let reply = await session.request(
                featureIndex: index, function: 0x05, params: HIDPPProtocol.readMemoryParams(sector: sector, offset: offset)
            ) else { return nil }
            chunks.append(Array(reply[4..<20]))
        }
        return HIDPPProtocol.assembleSector(chunks, sectorSize: size)
    }

    /// memoryAddrWrite (6), then the data 16 bytes at a time (7), then memoryWriteEnd (8).
    private func writeSector(_ sector: UInt16, _ data: [UInt8], session: HIDPPSession, index: UInt8) async -> Bool {
        guard await session.request(
            featureIndex: index, function: 0x06, params: HIDPPProtocol.writeMemoryStartParams(sector: sector, length: data.count)
        ) != nil else { return false }
        for offset in stride(from: 0, to: data.count, by: 16) {
            let chunk = Array(data[offset..<min(offset + 16, data.count)])
            guard await session.request(featureIndex: index, function: 0x07, params: chunk) != nil else { return false }
        }
        return await session.request(featureIndex: index, function: 0x08) != nil
    }

    // MARK: Side Buttons

    /// Remapped side buttons are silenced to macOS and reported to this app over HID++ instead, so only this
    /// mouse's buttons trigger the actions. Buttons left at System Default keep working natively, and with
    /// both at the default nothing is reported to the app at all.
    func setSideButtons(_ buttons: SideButtons) {
        guard let session, let index = spyFeatureIndex, canControlPerformance else { return }
        if let data = try? JSONEncoder().encode(buttons), let key = settingsKey("sideButtons") {
            UserDefaults.standard.set(data, forKey: key)
        }
        var silenced: Set<Int> = []
        if buttons.back != .systemDefault { silenced.insert(HIDPPProtocol.backSideButton) }
        if buttons.forward != .systemDefault { silenced.insert(HIDPPProtocol.forwardSideButton) }
        let map = HIDPPProtocol.buttonMap(buttonCount: buttonCount, silencing: silenced)

        Task { [weak self] in
            guard let self else { return }
            var applied = true
            if silenced.isEmpty {
                if self.isSpying {
                    // Restore every button to macOS, then stop reporting presses.
                    applied = await session.request(featureIndex: index, function: 0x04, params: map) != nil
                    _ = await session.request(featureIndex: index, function: 0x02)
                    self.isSpying = false
                }
            } else {
                if !self.isSpying {
                    applied = await session.request(featureIndex: index, function: 0x01) != nil
                    self.isSpying = applied
                }
                if applied {
                    applied = await session.request(featureIndex: index, function: 0x04, params: map) != nil
                }
            }
            guard self.session === session, applied else { return }
            self.lastButtonMask = 0
            self.sideButtons = buttons
        }
    }

    private var savedSideButtons: SideButtons? {
        guard let key = settingsKey("sideButtons"), let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SideButtons.self, from: data)
    }

    /// A spy event: act on side buttons that were just pressed (and are remapped).
    private func handleButtonMask(_ mask: UInt16) {
        let previous = lastButtonMask
        lastButtonMask = mask
        guard let buttons = sideButtons else { return }
        for (button, action) in [(HIDPPProtocol.backSideButton, buttons.back), (HIDPPProtocol.forwardSideButton, buttons.forward)]
        where action != .systemDefault
            && HIDPPProtocol.isButtonPressed(button, in: mask)
            && !HIDPPProtocol.isButtonPressed(button, in: previous) {
            AccessoryActions.perform(action)
        }
    }

    /// Hands the mouse back to its onboard profile, so it behaves as configured in G HUB without the app.
    fileprivate func releaseControl() {
        if let session, let index = spyFeatureIndex, isSpying {
            // Give every button back to macOS and stop reporting presses before leaving host mode.
            session.sendWithoutReply(
                featureIndex: index, function: 0x04,
                params: HIDPPProtocol.buttonMap(buttonCount: buttonCount, silencing: [])
            )
            session.sendWithoutReply(featureIndex: index, function: 0x02)
            isSpying = false
        }
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
        batteryFeature = await session.batteryFeature()
        if let feature = batteryFeature, let reading = await session.readBattery(feature) {
            apply(reading)
        }
    }

    private func apply(_ reading: HIDPPProtocol.BatteryReading) {
        if batteryPercent != reading.percentage { batteryPercent = reading.percentage }
        if isCharging != reading.isCharging { isCharging = reading.isCharging }
        AccessoryBatteryAlerts.shared.report(id: id, name: accessoryName, percent: batteryPercent, isCharging: isCharging)
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
        triggerFeatureIndex = nil
        triggerSettings = nil
        triggerLimits = nil
        spyFeatureIndex = nil
        buttonCount = 0
        isSpying = false
        lastButtonMask = 0
        sideButtons = nil
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
                // The mouse returns to its onboard profile when it powers off; host mode, press reporting and
                // the button map are re-applied on reconnect.
                isInHostMode = false
                isSpying = false
                lastButtonMask = 0
                canControlPerformance = false
            } else {
                identify()
            }
            return
        }
        if let index = spyFeatureIndex, let mask = HIDPPProtocol.parseButtonSpyEvent(event, expectedFeatureIndex: index) {
            handleButtonMask(mask)
            return
        }
        // Battery changes the mouse pushes on its own (same layout as the getStatus reply).
        if let feature = batteryFeature, let reading = HIDPPSession.batteryReading(from: event, feature: feature) {
            apply(reading)
        }
    }
}

// MARK: - AccessoryConnector

extension LogitechGConnector: AccessoryConnector {
    var id: String { "logitech.g-mouse" }
    var displayName: String { "G2 Superstrike" }
    var systemImage: String { "computermouse" }

    var isAvailable: Bool { deviceName != nil }
    var accessoryName: String { deviceName ?? displayName }
    /// LIGHTSPEED mice are always on a receiver here.
    var connection: AccessoryConnection? { isAvailable ? .receiver : nil }
    var isAwake: Bool { isOnline }

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
        if monitor.isOpen || monitor.openIfPermitted() {
            refresh()
        }
    }

    /// Nothing runs on a timer, so there's no card-only work to start or stop.
    func setCardVisible(_ visible: Bool) {}

    func makeSettingsView() -> AnyView {
        AnyView(LogitechGSettingsView(connector: self))
    }
}

// MARK: - Settings Sections

/// The Logitech G page: device-specific sections only. The Accessories tab adds the device section and
/// battery alerts, and disables everything while the mouse isn't connected.
private struct LogitechGSettingsView: View {
    let connector: LogitechGConnector

    private static let dpiPresets = [400, 800, 1600, 3200, 6400]

    nonisolated static func rateLabel(_ hz: Int) -> String {
        hz >= 1000 ? "\(hz / 1000) kHz" : "\(hz) Hz"
    }

    var body: some View {
        Group {
            if connector.isOnline && (connector.dpi != nil || connector.reportRateHz != nil) {
                performanceSection
            }
            if connector.isOnline, let triggers = connector.triggerSettings {
                triggerSection(triggers)
            }
            if connector.isOnline, let buttons = connector.sideButtons {
                sideButtonSection(buttons)
            }
            if connector.isOnline {
                onboardMemorySection
            }
        }
        .disabled(!connector.canControlPerformance)
    }

    private var performanceSection: some View {
        SettingsSection(title: "Performance", footer: performanceFooter) {
            if let dpi = connector.dpi {
                DPIControl(
                    dpi: dpi,
                    presets: Self.dpiPresets,
                    range: (connector.dpiRange?.minimum ?? 100)...(connector.dpiRange?.maximum ?? 44_000),
                    onCommit: connector.setDPI
                )
            }
            if let rate = connector.reportRateHz, !connector.supportedReportRates.isEmpty {
                Picker("Report Rate", selection: Binding(get: { rate }, set: { connector.setReportRate($0) })) {
                    ForEach(connector.supportedReportRates, id: \.self) { hz in
                        Text(Self.rateLabel(hz)).tag(hz)
                    }
                }
            }
        }
    }

    private func triggerSection(_ triggers: HIDPPProtocol.TriggerSettings) -> some View {
        let limits = connector.triggerLimits
        return SettingsSection(title: "Triggers", footer: "Applies to both buttons. Lower actuation triggers a click earlier in the press.") {
            LevelSlider(title: "Actuation Point", value: triggers.actuation, range: 1...(limits?.maxActuation ?? 10)) {
                connector.setTriggerSettings(.init(actuation: $0, rapidTrigger: triggers.rapidTrigger, haptics: triggers.haptics))
            }
            LevelSlider(title: "Rapid Trigger", value: triggers.rapidTrigger, range: 0...(limits?.maxRapidTrigger ?? 5), lowestLabel: "Off") {
                connector.setTriggerSettings(.init(actuation: triggers.actuation, rapidTrigger: $0, haptics: triggers.haptics))
            }
            LevelSlider(title: "Haptic Feedback", value: triggers.haptics, range: 0...(limits?.maxHaptics ?? 5), lowestLabel: "Off") {
                connector.setTriggerSettings(.init(actuation: triggers.actuation, rapidTrigger: triggers.rapidTrigger, haptics: $0))
            }
        }
    }

    private func sideButtonSection(_ buttons: LogitechGConnector.SideButtons) -> some View {
        SettingsSection(title: "Side Buttons", footer: "Only this mouse's side buttons change. System Default keeps the normal back and forward behavior.") {
            ActionPicker(title: "Back Button", selection: Binding(get: { buttons.back }, set: { action in
                connector.setSideButtons(.init(back: action, forward: buttons.forward))
            }))
            ActionPicker(title: "Forward Button", selection: Binding(get: { buttons.forward }, set: { action in
                connector.setSideButtons(.init(back: buttons.back, forward: action))
            }))
        }
    }

    private var onboardMemorySection: some View {
        SettingsSection(title: "Onboard Memory", footer: "Saves DPI, report rate and triggers to the mouse a few seconds after a change, so it keeps them without Aeron Tools. Side button actions always need the app.") {
            Toggle("Save settings to the mouse", isOn: Binding(
                get: { connector.savesToOnboardProfile },
                set: { connector.savesToOnboardProfile = $0 }
            ))
            switch connector.profileSaveState {
            case .idle:
                EmptyView()
            case .saving:
                LabeledContent("Status", value: "Saving…")
            case .saved(let profile):
                LabeledContent("Status", value: "Saved to profile \(profile)")
            case .failed(let message):
                LabeledContent("Status") {
                    Text(message)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var performanceFooter: String {
        guard connector.canControlPerformance else {
            return "The mouse is running from its onboard profile, so these can't be changed right now."
        }
        let profile = connector.onboardProfile.map { " \($0)" } ?? ""
        return "While Aeron Tools runs it controls the mouse directly, like G HUB. When it quits, the mouse returns to onboard profile\(profile)."
    }
}
