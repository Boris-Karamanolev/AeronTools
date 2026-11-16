import SwiftUI
import IOKit.hid

// MARK: - MXKeyboardConnector

/// Logitech MX keyboards (MX Mechanical, MX Keys Mini) on a Logi Bolt or Unifying receiver. Both speak the
/// same HID++ features (backlight, Fn inversion, reprogrammable F-keys), so one connector serves each model.
/// Bolt receivers host several devices, so every slot's pairing record is checked and the keyboard is found by
/// name. The receiver answers for the keyboard while it sleeps; once awake, its full name and battery come
/// over HID++. Event-driven: receiver attach/detach, the receiver reporting the keyboard waking or sleeping,
/// and battery changes the keyboard pushes on its own.
@Observable
@MainActor
final class MXKeyboardConnector {
    static let mxMechanical = MXKeyboardConnector(model: .mxMechanical)
    static let mxKeysMini = MXKeyboardConnector(model: .mxKeysMini)

    nonisolated static let receiverIDs = [HIDPPProtocol.boltReceiverProductID, HIDPPProtocol.unifyingReceiverProductID]

    /// The supported keyboards and how each is told apart on a receiver.
    enum Model: Sendable {
        case mxMechanical
        case mxKeysMini

        var id: String {
            switch self {
            case .mxMechanical: return "logitech.mx-mechanical"
            case .mxKeysMini: return "logitech.mx-keys-mini"
            }
        }

        var displayName: String {
            switch self {
            case .mxMechanical: return "MX Mechanical"
            case .mxKeysMini: return "MX Keys Mini"
            }
        }

        /// Prefix for settings saved per keyboard.
        var defaultsPrefix: String {
            switch self {
            case .mxMechanical: return "mxMechanical"
            case .mxKeysMini: return "mxKeysMini"
            }
        }

        nonisolated func matches(_ name: String) -> Bool {
            switch self {
            case .mxMechanical: return MXKeyboardConnector.isMXMechanical(name)
            case .mxKeysMini: return MXKeyboardConnector.isMXKeysMini(name)
            }
        }
    }

    let model: Model

    /// Finds the keyboard in any slot of any Bolt or Unifying receiver, and follows its name, wake state and battery.
    @ObservationIgnored let device: HIDPPReceiverDevice

    var deviceName: String? { device.deviceName }
    /// The keyboard is awake and answering; false while it sleeps (the receiver still knows it's paired).
    var isOnline: Bool { device.isOnline }
    var batteryPercent: Int? { device.batteryPercent }
    var isCharging: Bool { device.isCharging }
    /// The backlight configuration as the keyboard last reported it; nil until it has answered.
    private(set) var backlight: HIDPPProtocol.BacklightConfig?
    /// The effect as the keyboard reports it.
    private(set) var backlightEffect: HIDPPProtocol.BacklightEffect?
    /// F1–F12 act as standard function keys (true) or media keys (false); nil until read.
    private(set) var fnKeysAreStandard: Bool?
    /// The F-keys, by position (1 = F1). Only divertable ones can be remapped (Easy-Switch keys can't).
    private(set) var fKeyControls: [Int: HIDPPProtocol.KeyControl] = [:]
    /// Actions assigned to F-keys, by position. Keys left out keep their printed function.
    private(set) var keyActions: [Int: AccessoryButtonAction] = [:]

    private var session: HIDPPSession? { device.session }
    @ObservationIgnored private var backlightIndex: UInt8?
    @ObservationIgnored private var fnIndex: UInt8?
    @ObservationIgnored private var reprogIndex: UInt8?
    @ObservationIgnored private var hostIndex: UInt8 = 0
    /// Controls this app diverted; only these are ever handed back, so Options+'s own remaps are left alone.
    @ObservationIgnored private var divertedCIDs: Set<UInt16> = []
    @ObservationIgnored private var pressedCIDs: Set<UInt16> = []
    /// The newest configuration waiting to be written; rapid changes (a dragged slider) collapse into it.
    @ObservationIgnored private var pendingBacklight: HIDPPProtocol.BacklightConfig?
    @ObservationIgnored private var isWritingBacklight = false

    private init(model: Model) {
        self.model = model
        device = HIDPPReceiverDevice(
            productIDs: Self.receiverIDs, slots: 1...6, alertID: model.id,
            matches: { $0.kind == .keyboard && model.matches($0.name) }
        )
    }

    /// The receiver abbreviates the name (e.g. "MX MCHNCL M"); the keyboard itself reports it in full.
    nonisolated static func isMXMechanical(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("mx mchncl") || lower.contains("mx mechanical")
    }

    /// A Bolt receiver reports the MX Keys Mini by its full name.
    nonisolated static func isMXKeysMini(_ name: String) -> Bool {
        name.lowercased().contains("mx keys mini")
    }

    // MARK: Lifecycle

    fileprivate func setUp() {
        device.onOnline = { [weak self] session in
            await self?.loadBacklight(using: session)
            await self?.loadKeys(using: session)
        }
        device.onEvent = { [weak self] event in self?.handle(event: event) }
        device.onOffline = { [weak self] in self?.deviceWentOffline() }
        device.start()
    }

    // MARK: Fn Keys & Remapping

    private func loadKeys(using session: HIDPPSession) async {
        if let changeHost = await session.featureIndex(for: HIDPPProtocol.featureChangeHost),
           let reply = await session.request(featureIndex: changeHost, function: 0x00),
           let host = HIDPPProtocol.parseCurrentHost(reply) {
            hostIndex = host
        }
        fnIndex = await session.featureIndex(for: HIDPPProtocol.featureFnInversion)
        await readFnKeys(using: session)

        reprogIndex = await session.featureIndex(for: HIDPPProtocol.featureReprogControlsV4)
        guard let index = reprogIndex, let countReply = await session.request(featureIndex: index, function: 0x00) else { return }
        var controls: [Int: HIDPPProtocol.KeyControl] = [:]
        for controlIndex in 0..<countReply[4] {
            guard let reply = await session.request(featureIndex: index, function: 0x01, params: [controlIndex]),
                  let control = HIDPPProtocol.parseKeyControl(reply),
                  (1...12).contains(control.fKeyPosition) else { continue }
            controls[control.fKeyPosition] = control
        }
        guard self.session === session else { return }
        fKeyControls = controls
        keyActions = savedKeyActions.filter { controls[$0.key]?.isDivertable == true }
        // Diversions don't survive the keyboard powering off; this runs again on every wake.
        divertedCIDs.removeAll()
        for position in keyActions.keys {
            await applyKeyAction(at: position, using: session)
        }
    }

    private func readFnKeys(using session: HIDPPSession) async {
        guard let index = fnIndex,
              let reply = await session.request(featureIndex: index, function: 0x00, params: [hostIndex]),
              self.session === session else { return }
        fnKeysAreStandard = HIDPPProtocol.parseFnInversion(reply, host: hostIndex)
    }

    func setFnKeysAreStandard(_ standard: Bool) {
        guard let session, let index = fnIndex else { return }
        fnKeysAreStandard = standard
        Task { [weak self] in
            _ = await session.request(featureIndex: index, function: 0x01, params: [self?.hostIndex ?? 0, standard ? 0x01 : 0x00])
            await self?.readFnKeys(using: session)
        }
    }

    func setKeyAction(_ action: AccessoryButtonAction, at position: Int) {
        guard let session else { return }
        keyActions[position] = action == .systemDefault ? nil : action
        saveKeyActions()
        Task { await self.applyKeyAction(at: position, using: session) }
    }

    /// Diverts a remapped key so its presses reach only this app, or hands a key this app diverted back to macOS.
    private func applyKeyAction(at position: Int, using session: HIDPPSession) async {
        guard let index = reprogIndex, let control = fKeyControls[position], control.isDivertable else { return }
        let diverts = keyActions[position] != nil
        guard diverts || divertedCIDs.contains(control.cid) else { return }
        let packet = HIDPPProtocol.setControlReportingPacket(
            deviceIndex: session.deviceIndex, featureIndex: index, controlID: control.cid, diverted: diverts
        )
        guard await session.request(packet: packet) != nil else { return }
        if diverts { divertedCIDs.insert(control.cid) } else { divertedCIDs.remove(control.cid) }
    }

    /// Hands every key this app diverted back to macOS, so the keyboard works normally once the app has quit.
    fileprivate func releaseKeys() {
        guard let session, let index = reprogIndex else { return }
        for cid in divertedCIDs {
            session.sendWithoutReply(featureIndex: index, function: 0x03, params: [UInt8(cid >> 8), UInt8(cid & 0xFF), 0x22])
        }
        divertedCIDs.removeAll()
    }

    /// A diverted-keys event: run the action of each remapped key that was just pressed.
    private func handleDivertedKeys(_ cids: [UInt16]) {
        let pressed = Set(cids)
        let newlyPressed = pressed.subtracting(pressedCIDs)
        pressedCIDs = pressed
        for cid in newlyPressed {
            guard let position = fKeyControls.first(where: { $0.value.cid == cid })?.key,
                  let action = keyActions[position] else { continue }
            AccessoryActions.perform(action)
        }
    }

    private var savedKeyActions: [Int: AccessoryButtonAction] {
        guard let name = deviceName, let data = UserDefaults.standard.data(forKey: "\(model.defaultsPrefix).\(name).keyActions"),
              let stored = try? JSONDecoder().decode([String: AccessoryButtonAction].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, action in Int(key).map { ($0, action) } })
    }

    private func saveKeyActions() {
        guard let name = deviceName else { return }
        let stored = Dictionary(uniqueKeysWithValues: keyActions.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: "\(model.defaultsPrefix).\(name).keyActions")
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
        if let info = await session.request(featureIndex: index, function: 0x02), self.session === session {
            backlightEffect = HIDPPProtocol.parseBacklightEffect(info)
        }
    }

    /// Shows the change at once, writes it (merging rapid changes into the latest), then reads the configuration
    /// back so Settings ends up showing what the keyboard actually uses.
    func setBacklight(_ config: HIDPPProtocol.BacklightConfig) {
        guard let session, let index = backlightIndex else { return }
        backlight = config
        pendingBacklight = config
        guard !isWritingBacklight else { return }
        isWritingBacklight = true
        Task { [weak self] in
            while let self, let next = self.pendingBacklight {
                self.pendingBacklight = nil
                _ = await session.request(featureIndex: index, function: 0x01, params: HIDPPProtocol.setBacklightConfigParams(next))
            }
            self?.isWritingBacklight = false
            await self?.readBacklight(using: session)
        }
    }

    func setBacklightEffect(_ effect: HIDPPProtocol.BacklightEffect) {
        guard let session, let index = backlightIndex else { return }
        backlightEffect = effect
        Task { [weak self] in
            _ = await session.request(featureIndex: index, function: 0x03, params: [effect.rawValue])
            // Read back what the keyboard actually switched to.
            await self?.readBacklight(using: session)
        }
    }

    /// The keyboard fell asleep or went away. Its diversions end when it powers off and are re-applied on wake;
    /// if it's gone entirely, forget its features.
    private func deviceWentOffline() {
        pressedCIDs.removeAll()
        guard !device.isAvailable else { return }
        backlightIndex = nil
        backlight = nil
        backlightEffect = nil
        fnIndex = nil
        reprogIndex = nil
        fnKeysAreStandard = nil
        fKeyControls = [:]
        divertedCIDs.removeAll()
    }

    // MARK: Incoming Reports

    /// Events beyond battery and link changes, which `device` handles.
    private func handle(event: [UInt8]) {
        if let index = reprogIndex, let cids = HIDPPProtocol.parseDivertedButtonsEvent(event, expectedFeatureIndex: index) {
            handleDivertedKeys(cids)
            return
        }
        // The backlight keys change the configuration on the keyboard itself; re-read it when it says so.
        if let index = backlightIndex, event[2] == index, let session {
            Task { await self.readBacklight(using: session) }
        }
    }
}

// MARK: - AccessoryConnector

extension MXKeyboardConnector: AccessoryConnector {
    var id: String { model.id }
    var displayName: String { model.displayName }
    var systemImage: String { "keyboard" }

    var isAvailable: Bool { deviceName != nil }
    var accessoryName: String { deviceName ?? displayName }
    var connection: AccessoryConnection? { isAvailable ? .receiver : nil }
    var isAwake: Bool { isOnline }

    func start() {
        setUp()
    }

    /// Hands remapped keys back to macOS.
    func stop() {
        releaseKeys()
    }

    func systemDidWake() {
        device.refresh()
    }

    func popoverWillShow() {
        device.popoverWillShow()
    }

    func setCardVisible(_ visible: Bool) {}

    func makeSettingsView() -> AnyView {
        AnyView(MXKeyboardSettingsView(connector: self))
    }
}

// MARK: - Settings Sections

/// The MX keyboard page: keyboard-specific sections only. The Accessories tab adds the device section and
/// battery alerts, and disables everything while the keyboard isn't connected.
private struct MXKeyboardSettingsView: View {
    let connector: MXKeyboardConnector

    private static let durations = [5, 10, 15, 30, 45, 60, 90, 120, 180, 300]

    var body: some View {
        if connector.isOnline, let backlight = connector.backlight {
            backlightSection(backlight)
        }
        if connector.isOnline, let standard = connector.fnKeysAreStandard {
            SettingsSection(title: "Keys", footer: "When on, press Fn for the media functions printed on the keys.") {
                Toggle("Use F1–F12 as standard function keys", isOn: Binding(
                    get: { standard },
                    set: { connector.setFnKeysAreStandard($0) }
                ))
            }
        }
        if connector.isOnline, connector.fKeyControls.values.contains(where: \.isDivertable) {
            SettingsSection(title: "Key Remapping", footer: "Click a key to choose its action. Only this keyboard's keys change; the Easy-Switch keys can't be remapped. Quit Logi Options+ so it doesn't handle the same keys.") {
                KeyRowPicker(
                    keys: connector.fKeyControls.keys.sorted().compactMap { position in
                        connector.fKeyControls[position].map { control in
                            KeyCapInfo(id: position, label: "F\(position)", systemImage: Self.symbol(for: control),
                                       isEnabled: control.isDivertable)
                        }
                    },
                    action: { connector.keyActions[$0] ?? .systemDefault },
                    onSelect: { connector.setKeyAction($1, at: $0) }
                )
            }
        }
    }

    /// The symbol printed on a key, from its own function. Logitech task numbers, read from an
    /// MX Mechanical Mini for Mac and an MX Keys Mini.
    private static func symbol(for control: HIDPPProtocol.KeyControl) -> String? {
        switch control.task {
        case 0x00AE: return "1.circle"           // Easy-Switch 1
        case 0x00AF: return "2.circle"
        case 0x00B0: return "3.circle"
        case 0x00C1: return "light.min"          // Backlight down
        case 0x00C2: return "light.max"          // Backlight up
        case 0x00D8: return "waveform.and.mic"   // Dictation
        case 0x00DD: return "face.smiling"       // Emoji
        case 0x00DF: return "camera.viewfinder"  // Screenshot
        case 0x00F1: return "mic.slash"          // Mute microphone
        case 0x00B1: return "magnifyingglass"    // Search
        case 0x00FD: return "playpause"          // Play / pause
        case 0x0004: return "playpause"          // Play / pause (MX Keys Mini)
        case 0x0003: return "speaker.slash"      // Mute
        case 0x0002: return "speaker.wave.1"     // Volume down
        case 0x0001: return "speaker.wave.3"     // Volume up
        default: return nil
        }
    }

    private func backlightSection(_ backlight: HIDPPProtocol.BacklightConfig) -> some View {
        SettingsSection(title: "Backlight", footer: "Battery saving turns the backlight off below 10% battery. The keyboard's own backlight keys still work.") {
            Toggle("Backlight", isOn: binding(backlight, \.isEnabled))
            Group {
                // The MX Keys Mini only has a static backlight, so there's nothing to pick.
                if backlight.supportedEffects.count > 1 {
                    Picker("Effect", selection: Binding(
                        get: { connector.backlightEffect },
                        set: { if let effect = $0 { connector.setBacklightEffect(effect) } }
                    )) {
                        if connector.backlightEffect == nil {
                            Text("Not set").tag(HIDPPProtocol.BacklightEffect?.none)
                        }
                        ForEach(backlight.supportedEffects) { effect in
                            Text(effect.title).tag(Optional(effect))
                        }
                    }
                }
                Toggle("Automatic brightness", isOn: binding(backlight, \.isAutomaticBrightness))
                if !backlight.isAutomaticBrightness {
                    LevelSlider(title: "Brightness", value: Int(backlight.level), range: 1...7, commitsWhileDragging: true) { level in
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
