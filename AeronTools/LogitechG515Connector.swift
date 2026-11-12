import SwiftUI

// MARK: - LogitechG515Connector

/// The Logitech G515 keyboard, on its USB cable or its LIGHTSPEED receiver. The receiver's pairing record names
/// it while it sleeps; once awake, its full name, battery and lighting come over HID++. Event-driven: device
/// attach/detach, the receiver reporting the keyboard waking or sleeping, and changes the keyboard pushes on its
/// own (battery, the brightness key).
@Observable
@MainActor
final class LogitechG515Connector {
    static let shared = LogitechG515Connector()

    /// The G515 LIGHTSPEED TKL's own product ID when connected by its USB cable.
    nonisolated static let wiredProductIDs = [0xC355]
    /// The keyboard has a single lighting zone.
    private static let lightingZone: UInt8 = 0

    /// Finds the keyboard on its USB cable, or on whichever LIGHTSPEED receiver it's paired to (each hosts one
    /// device, in slot 1).
    @ObservationIgnored let device = HIDPPReceiverDevice(
        productIDs: LogitechGConnector.lightspeedReceiverIDs, wiredProductIDs: wiredProductIDs, slots: 1...1,
        alertID: "logitech.g515", matches: { $0.kind == .keyboard }
    )

    var deviceName: String? { device.deviceName }
    var isOnline: Bool { device.isOnline }

    /// Lighting brightness as the keyboard reports it, 0…`maxBrightness`; nil until read.
    private(set) var brightness: Int?
    private(set) var maxBrightness = 100
    /// The built-in effects the keyboard offers, in its own order.
    private(set) var effects: [HIDPPProtocol.RGBEffect] = []
    /// The lighting chosen in the app. The keyboard can't report its current effect, so this is what was last set.
    private(set) var lighting: HIDPPProtocol.RGBLighting
    /// Game mode, switched with the keyboard's game mode key; nil until read.
    private(set) var isGameModeOn: Bool?

    private var session: HIDPPSession? { device.session }
    @ObservationIgnored private var brightnessIndex: UInt8?
    @ObservationIgnored private var rgbIndex: UInt8?
    @ObservationIgnored private var gameModeIndex: UInt8?
    @ObservationIgnored private var effectIndices: [HIDPPProtocol.RGBEffect: UInt8] = [:]
    /// The newest values waiting to be written; rapid changes (a dragged slider or colour) collapse into them.
    @ObservationIgnored private var pendingLighting: HIDPPProtocol.RGBLighting?
    @ObservationIgnored private var pendingBrightness: Int?
    @ObservationIgnored private var isWriting = false
    /// The app has taken lighting control from the keyboard's onboard lighting, as G HUB does.
    @ObservationIgnored private var hasLightingControl = false
    @ObservationIgnored private var lastReapply = Date.distantPast

    private static let lightingKey = "g515.lighting"

    private init() {
        lighting = UserDefaults.standard.data(forKey: Self.lightingKey)
            .flatMap { try? JSONDecoder().decode(HIDPPProtocol.RGBLighting.self, from: $0) } ?? HIDPPProtocol.RGBLighting()
    }

    fileprivate func setUp() {
        device.onOnline = { [weak self] session in
            await self?.loadLighting(using: session)
            await self?.loadGameMode(using: session)
        }
        device.onEvent = { [weak self] event in self?.handle(event: event) }
        device.onOffline = { [weak self] in self?.deviceWentOffline() }
        device.start()
    }

    // MARK: Lighting

    private func loadLighting(using session: HIDPPSession) async {
        brightnessIndex = await session.featureIndex(for: HIDPPProtocol.featureBrightnessControl)
        if let index = brightnessIndex {
            if let info = await session.request(featureIndex: index, function: 0x00),
               let max = HIDPPProtocol.parseBrightnessLevel(info), max > 0 {
                maxBrightness = max
            }
            if let reply = await session.request(featureIndex: index, function: 0x01) {
                brightness = HIDPPProtocol.parseBrightnessLevel(reply)
            }
        }

        rgbIndex = await session.featureIndex(for: HIDPPProtocol.featureRGBEffects)
        guard let index = rgbIndex,
              let zone = await session.request(featureIndex: index, function: 0x00, params: [Self.lightingZone, 0xFF, 0x00]),
              zone.count > 8 else { return }
        var indices: [HIDPPProtocol.RGBEffect: UInt8] = [:]
        var found: [HIDPPProtocol.RGBEffect] = []
        for effectIndex in 0..<min(zone[8], 32) {
            guard let reply = await session.request(featureIndex: index, function: 0x00, params: [Self.lightingZone, effectIndex, 0x00]),
                  let effect = HIDPPProtocol.parseRGBZoneEffect(reply) else { continue }
            indices[effect.effect] = effect.index
            found.append(effect.effect)
        }
        guard self.session === session else { return }
        effectIndices = indices
        effects = found

        // The lighting chosen in the app is applied again after every wake and reconnect.
        if UserDefaults.standard.data(forKey: Self.lightingKey) != nil {
            setLighting(lighting)
        }
    }

    func setLighting(_ newValue: HIDPPProtocol.RGBLighting) {
        lighting = newValue
        if let data = try? JSONEncoder().encode(newValue) {
            UserDefaults.standard.set(data, forKey: Self.lightingKey)
        }
        pendingLighting = newValue
        flushWrites()
    }

    func setBrightness(_ level: Int) {
        brightness = level
        pendingBrightness = level
        flushWrites()
    }

    /// Writes the latest lighting and brightness, one request at a time, merging changes made in between. Always
    /// writes through the current session, so values set while reconnecting go to the keyboard once it's back.
    private func flushWrites() {
        guard !isWriting, session != nil else { return }
        isWriting = true
        Task { [weak self] in
            while let self, let session = self.session {
                if let level = self.pendingBrightness, let index = self.brightnessIndex {
                    self.pendingBrightness = nil
                    _ = await session.request(featureIndex: index, function: 0x02, params: HIDPPProtocol.setBrightnessParams(level))
                } else if let lighting = self.pendingLighting, let index = self.rgbIndex {
                    self.pendingLighting = nil
                    if !self.hasLightingControl {
                        // Function 5 [1, 3, 5], as G HUB sends it: lighting is controlled by the host, not the
                        // keyboard's onboard lighting.
                        let reply = await session.request(featureIndex: index, function: 0x05, params: [0x01, 0x03, 0x05])
                        self.hasLightingControl = reply != nil
                    }
                    if let effectIndex = self.effectIndices[lighting.effect] {
                        let params = HIDPPProtocol.setRGBEffectParams(zone: Self.lightingZone, index: effectIndex, lighting: lighting)
                        _ = await session.request(featureIndex: index, function: 0x01, params: params)
                    }
                } else {
                    break
                }
            }
            self?.isWriting = false
        }
    }

    // MARK: Game Mode

    private func loadGameMode(using session: HIDPPSession) async {
        gameModeIndex = await session.featureIndex(for: HIDPPProtocol.featureGameMode)
        guard let index = gameModeIndex,
              let reply = await session.request(featureIndex: index, function: 0x02),
              self.session === session else { return }
        isGameModeOn = HIDPPProtocol.parseGameModeState(reply)
    }

    // MARK: Incoming Reports

    /// Events beyond battery and link changes, which `device` handles.
    private func handle(event: [UInt8]) {
        // The brightness key: a function-0 event with the new level. (While Color Cycle or Color Wave runs, the
        // lighting feature also sends a function-0 timing event every couple of seconds; nothing needs it.)
        if let index = brightnessIndex, event[2] == index, event[3] >> 4 == 0,
           let level = HIDPPProtocol.parseBrightnessLevel(event) {
            brightness = level
            return
        }
        // The game mode key: a function-0 event with the new state. Switching loads that mode's lighting from the
        // keyboard's onboard profile (set in G HUB), so the app's lighting is applied again.
        if let index = gameModeIndex, event[2] == index, event[3] >> 4 == 0 {
            isGameModeOn = HIDPPProtocol.parseGameModeState(event)
            reapplyLighting()
            return
        }
        // A function-1 event from the lighting feature: the keyboard went back to its onboard lighting (it repeats
        // this, backing off, until the host answers), so control is taken back and the app's lighting reapplied.
        if let index = rgbIndex, event[2] == index, event[3] >> 4 == 1 {
            reapplyLighting()
        }
    }

    /// Takes lighting control back and writes the app's lighting again, once per burst of keyboard events.
    private func reapplyLighting() {
        guard UserDefaults.standard.data(forKey: Self.lightingKey) != nil,
              Date().timeIntervalSince(lastReapply) > 3 else { return }
        lastReapply = Date()
        hasLightingControl = false
        setLighting(lighting)
    }

    /// Feature indices differ between links (cable and receiver), so they're read again when it's back.
    private func deviceWentOffline() {
        brightnessIndex = nil
        rgbIndex = nil
        gameModeIndex = nil
        effectIndices = [:]
        hasLightingControl = false
        pendingBrightness = nil
        pendingLighting = nil
        guard !device.isAvailable else { return }
        brightness = nil
        effects = []
        isGameModeOn = nil
    }
}

// MARK: - AccessoryConnector

extension LogitechG515Connector: AccessoryConnector {
    var id: String { "logitech.g515" }
    var displayName: String { "G515" }
    var systemImage: String { "keyboard" }

    var isAvailable: Bool { device.isAvailable }
    var accessoryName: String { deviceName ?? displayName }
    var connection: AccessoryConnection? {
        guard isAvailable else { return nil }
        return device.isWired ? .usbCable : .receiver
    }
    var isAwake: Bool { isOnline }
    var batteryPercent: Int? { device.batteryPercent }
    var isCharging: Bool { device.isCharging }

    func start() {
        setUp()
    }

    func stop() {}

    func systemDidWake() {
        device.refresh()
    }

    func popoverWillShow() {
        device.popoverWillShow()
    }

    func setCardVisible(_ visible: Bool) {}

    func makeSettingsView() -> AnyView {
        AnyView(LogitechG515SettingsView(connector: self))
    }
}

// MARK: - Settings Sections

/// The G515 page: keyboard-specific sections only. The Accessories tab adds the device section and battery
/// alerts, and disables everything while the keyboard isn't connected.
private struct LogitechG515SettingsView: View {
    let connector: LogitechG515Connector

    var body: some View {
        if connector.isOnline, !connector.effects.isEmpty {
            let lighting = connector.lighting
            SettingsSection(title: "Lighting", footer: "Quit G HUB so it doesn't replace these. Pulsar Point and G HUB's other animated effects are drawn by G HUB and aren't built into the keyboard.") {
                Picker("Effect", selection: binding(\.effect)) {
                    ForEach(connector.effects) { effect in
                        Text(effect.title).tag(effect)
                    }
                }
                if lighting.effect.usesColor {
                    ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
                }
                if lighting.effect.usesSpeed {
                    LevelSlider(title: "Speed", value: lighting.speed, range: HIDPPProtocol.RGBLighting.speedRange) { speed in
                        var updated = connector.lighting
                        updated.speed = speed
                        connector.setLighting(updated)
                    }
                }
                if let brightness = connector.brightness {
                    LevelSlider(title: "Brightness", value: brightness, range: 0...connector.maxBrightness, commitsWhileDragging: true) {
                        connector.setBrightness($0)
                    }
                }
            }
        }
        if connector.isOnline, let isOn = connector.isGameModeOn {
            SettingsSection(title: "Game Mode", footer: "Switch game mode with the game mode key on the keyboard. The keys it blocks are set in G HUB.") {
                LabeledContent("Game mode") {
                    HStack(spacing: 6) {
                        StatusDot(isActive: isOn)
                        Text(isOn ? "On" : "Off")
                    }
                }
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<HIDPPProtocol.RGBLighting, Value>) -> Binding<Value> {
        Binding(
            get: { connector.lighting[keyPath: keyPath] },
            set: { value in
                var updated = connector.lighting
                updated[keyPath: keyPath] = value
                connector.setLighting(updated)
            }
        )
    }

    /// The lighting colour as a SwiftUI colour, converted to 8-bit sRGB for the keyboard.
    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                let color = connector.lighting.color
                return Color(.sRGB, red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255)
            },
            set: { newColor in
                let resolved = newColor.resolve(in: EnvironmentValues())
                func byte(_ component: Float) -> UInt8 { UInt8(clamping: Int((min(max(component, 0), 1) * 255).rounded())) }
                var updated = connector.lighting
                updated.color = HIDPPProtocol.RGBColor(red: byte(resolved.red), green: byte(resolved.green), blue: byte(resolved.blue))
                guard updated.color != connector.lighting.color else { return }
                connector.setLighting(updated)
            }
        )
    }
}
