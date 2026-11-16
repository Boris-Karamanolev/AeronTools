import SwiftUI
import IOKit.hid

// MARK: - RazerDockConnector

/// The Razer Thunderbolt 4 Dock Chroma: its underglow lighting, and what's plugged into its ports.
///
/// Lighting goes through the dock's Chroma controller (`RazerChromaProtocol`), which stores what it's given, so
/// the dock keeps its lighting without the app. The ports come from the IORegistry (`DockPortMonitor`).
///
/// Event-driven: controller attach/detach from IOHIDManager, USB and Thunderbolt attach/detach notifications for
/// the ports, and the System Configuration store for the Ethernet link.
@Observable
@MainActor
final class RazerDockConnector {
    static let shared = RazerDockConnector()

    private static let name = "Razer Thunderbolt 4 Dock Chroma"

    /// The dock's lighting controller is attached, so the dock is connected.
    private(set) var isPresent = false
    /// The lighting as the dock last reported it, with the app's pending change applied; nil until read.
    private(set) var lighting: RazerChromaProtocol.Lighting?
    /// Lighting brightness, 0…255; nil until read.
    private(set) var brightness: Int?
    private(set) var serialNumber: String?
    private(set) var firmware: String?
    /// What's plugged into the dock.
    let ports = DockPortMonitor(model: .razerThunderbolt4)

    @ObservationIgnored private var manager: IOHIDManager?
    @ObservationIgnored private var isOpen = false
    @ObservationIgnored private var channel: RazerChromaChannel?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// The newest changes waiting to be written; rapid changes (a dragged slider or color) collapse into them.
    @ObservationIgnored private var pendingLighting: RazerChromaProtocol.Lighting?
    @ObservationIgnored private var pendingBrightness: UInt8?
    @ObservationIgnored private var isWriting = false

    private init() {}

    // MARK: Device

    fileprivate func setUp() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: RazerChromaProtocol.vendorID,
            kIOHIDProductIDKey: RazerChromaProtocol.dockChromaProductID,
            kIOHIDDeviceUsagePageKey: RazerChromaProtocol.usagePage,
            kIOHIDDeviceUsageKey: RazerChromaProtocol.usage,
        ] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let connector = Unmanaged<RazerDockConnector>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { connector.attached(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let connector = Unmanaged<RazerDockConnector>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { connector.removed(device) }
        }, context)
        // The callbacks run on the main run loop, which is why they can assume main-actor isolation.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        self.manager = manager
        openIfPermitted()
        ports.start()
    }

    /// Opening without Input Monitoring could show a blocking permission prompt, so this waits until it's
    /// granted, like the other accessories; it's tried again when the popover opens.
    private func openIfPermitted() {
        guard let manager, !isOpen, InputMonitoringPermission.isGranted else { return }
        isOpen = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        if isOpen { refresh() }
    }

    private func attached(_ device: IOHIDDevice) {
        channel = RazerChromaChannel(device: device)
        isPresent = true
        refresh()
    }

    private func removed(_ device: IOHIDDevice) {
        guard channel?.device == device else { return }
        refreshTask?.cancel()
        channel = nil
        isPresent = false
        lighting = nil
        brightness = nil
        serialNumber = nil
        firmware = nil
        pendingLighting = nil
        pendingBrightness = nil
    }

    // MARK: Reading

    /// Reads the dock's identity once, then its lighting. Runs on attach, wake and when the popover opens.
    private func refresh() {
        guard isOpen, let channel else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            if serialNumber == nil, let reply = await channel.request(RazerChromaProtocol.packet(.serial)) {
                serialNumber = RazerChromaProtocol.parseSerial(reply)
            }
            if firmware == nil, let reply = await channel.request(RazerChromaProtocol.packet(.firmware)) {
                firmware = RazerChromaProtocol.parseFirmware(reply)
            }
            guard !Task.isCancelled else { return }
            await readLighting(using: channel)
        }
    }

    private func readLighting(using channel: RazerChromaChannel) async {
        guard !isWriting else { return }
        let effect = await channel.request(RazerChromaProtocol.getEffectPacket())
        let level = await channel.request(RazerChromaProtocol.getBrightnessPacket())
        // A write started meanwhile; it reads back when it's done.
        guard self.channel === channel, !isWriting else { return }
        if let effect, let parsed = RazerChromaProtocol.parseLighting(effect, previous: lighting ?? .init()) {
            lighting = parsed
        }
        if let level, let value = RazerChromaProtocol.parseBrightness(level) {
            brightness = Int(value)
        }
    }

    // MARK: Writing

    func setLighting(_ new: RazerChromaProtocol.Lighting) {
        guard channel != nil, new.mode != nil else { return }
        lighting = new
        pendingLighting = new
        writePending()
    }

    func setBrightness(_ value: Int) {
        guard channel != nil else { return }
        brightness = value
        pendingBrightness = UInt8(clamping: value)
        writePending()
    }

    /// Writes the newest pending changes, then reads the lighting back so Settings shows what the dock uses.
    private func writePending() {
        guard !isWriting, let channel else { return }
        isWriting = true
        Task { [weak self] in
            while let self {
                if let next = pendingLighting {
                    pendingLighting = nil
                    if let packet = RazerChromaProtocol.setEffectPacket(next) { _ = await channel.request(packet) }
                } else if let next = pendingBrightness {
                    pendingBrightness = nil
                    _ = await channel.request(RazerChromaProtocol.setBrightnessPacket(next))
                } else {
                    break
                }
            }
            self?.isWriting = false
            await self?.readLighting(using: channel)
        }
    }
}

// MARK: - RazerChromaChannel

/// Talks to the lighting controller. Feature reports are synchronous and the controller takes a moment to answer,
/// so transfers run one at a time on their own queue, off the main actor.
nonisolated final class RazerChromaChannel: @unchecked Sendable {
    let device: IOHIDDevice
    private let queue = DispatchQueue(label: "com.aeronlabs.razer-chroma")

    init(device: IOHIDDevice) {
        self.device = device
    }

    /// Sends a request and returns the controller's successful reply, or nil if it failed or never answered.
    func request(_ packet: [UInt8]) async -> [UInt8]? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.transfer(packet)) }
        }
    }

    private func transfer(_ packet: [UInt8]) -> [UInt8]? {
        var request = packet
        guard IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, &request, request.count) == kIOReturnSuccess else { return nil }
        // The reply is ready after a few milliseconds; until then the controller reports it's busy.
        for _ in 0..<10 {
            usleep(10_000)
            var reply = [UInt8](repeating: 0, count: RazerChromaProtocol.reportLength)
            var length = CFIndex(reply.count)
            guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, &reply, &length) == kIOReturnSuccess else { return nil }
            switch RazerChromaProtocol.status(of: reply, answering: packet) {
            case .success: return reply
            case .busy, nil: continue
            default: return nil
            }
        }
        return nil
    }
}

// MARK: - AccessoryConnector

extension RazerDockConnector: AccessoryConnector {
    var id: String { "razer.thunderbolt-4-dock" }
    var displayName: String { "Razer Dock" }
    var systemImage: String { "dock.rectangle" }

    var isAvailable: Bool { isPresent }
    var accessoryName: String { Self.name }
    var connection: AccessoryConnection? { isPresent ? .thunderbolt : nil }
    var isAwake: Bool { isPresent }
    var batteryPercent: Int? { nil }
    var isCharging: Bool { false }
    var hasBattery: Bool { false }

    func start() {
        setUp()
    }

    /// Nothing to hand back: the lighting is stored on the dock.
    func stop() {}

    func systemDidWake() {
        refresh()
        ports.refresh()
    }

    func popoverWillShow() {
        openIfPermitted()
        refresh()
    }

    func setCardVisible(_ visible: Bool) {}

    func makeSettingsView() -> AnyView {
        AnyView(RazerDockSettingsView(connector: self))
    }
}

// MARK: - Settings Sections

/// The dock page: a diagram of its ports with what's plugged in, and its lighting. The Accessories tab adds the
/// device section, and disables everything while the dock isn't connected.
private struct RazerDockSettingsView: View {
    let connector: RazerDockConnector

    private typealias Lighting = RazerChromaProtocol.Lighting

    var body: some View {
        DockPortsSection(monitor: connector.ports) {
            ChromaGlowBar(lighting: connector.lighting, brightness: connector.brightness)
                .padding(.horizontal, 14)
        }
        if let lighting = connector.lighting {
            lightingSection(lighting)
        }
        if connector.serialNumber != nil || connector.firmware != nil {
            SettingsSection(title: "About") {
                if let serial = connector.serialNumber {
                    LabeledContent("Serial Number", value: serial)
                }
                if let firmware = connector.firmware {
                    LabeledContent("Lighting Firmware", value: firmware)
                }
            }
        }
    }

    // MARK: Lighting

    private func lightingSection(_ lighting: Lighting) -> some View {
        SettingsSection(title: "Lighting", footer: "Saved on the dock, so it keeps its lighting without the app.") {
            Picker("Effect", selection: Binding(
                get: { lighting.mode },
                set: { mode in
                    guard let mode else { return }
                    var new = lighting
                    new.mode = mode
                    connector.setLighting(new)
                }
            )) {
                if lighting.mode == nil {
                    Text("Set by Another App").tag(RazerChromaProtocol.Mode?.none)
                }
                ForEach(RazerChromaProtocol.Mode.allCases) { mode in
                    Text(mode.title).tag(Optional(mode))
                }
            }

            switch lighting.mode {
            case .staticColor:
                colorPicker("Color", lighting, \.primary)
            case .breathing:
                Picker("Colors", selection: binding(lighting, \.breathing)) {
                    ForEach(RazerChromaProtocol.BreathingStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                if lighting.breathing != .random {
                    colorPicker(lighting.breathing == .dual ? "First Color" : "Color", lighting, \.primary)
                }
                if lighting.breathing == .dual {
                    colorPicker("Second Color", lighting, \.secondary)
                }
            case .wave:
                Picker("Direction", selection: binding(lighting, \.waveDirection)) {
                    ForEach(RazerChromaProtocol.WaveDirection.allCases) { direction in
                        Text(direction.title).tag(direction)
                    }
                }
            case .off, .spectrum, nil:
                EmptyView()
            }

            if let brightness = connector.brightness, lighting.mode != .off {
                LevelSlider(title: "Brightness", value: Self.percent(brightness), range: 0...100, lowestLabel: "Off",
                            commitsWhileDragging: true) { percent in
                    connector.setBrightness(Int((Double(percent) * 2.55).rounded()))
                }
            }
        }
    }

    private static func percent(_ brightness: Int) -> Int {
        Int((Double(brightness) / 2.55).rounded())
    }

    private func colorPicker(_ title: String, _ lighting: Lighting,
                             _ keyPath: WritableKeyPath<Lighting, RazerChromaProtocol.RGB>) -> some View {
        ColorPicker(title, selection: Binding(
            get: { Color(lighting[keyPath: keyPath]) },
            set: { color in
                var new = lighting
                new[keyPath: keyPath] = RazerChromaProtocol.RGB(color)
                connector.setLighting(new)
            }
        ), supportsOpacity: false)
    }

    /// A binding that edits one field of the current lighting and writes the whole configuration.
    private func binding<Value>(_ lighting: Lighting, _ keyPath: WritableKeyPath<Lighting, Value>) -> Binding<Value> {
        Binding(
            get: { lighting[keyPath: keyPath] },
            set: { value in
                var new = lighting
                new[keyPath: keyPath] = value
                connector.setLighting(new)
            }
        )
    }
}

/// The underglow, animated to match the dock's effect and dimmed to its brightness. Only animates for moving
/// effects, and holds still with Reduce Motion.
private struct ChromaGlowBar: View {
    let lighting: RazerChromaProtocol.Lighting?
    let brightness: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isAnimated: Bool {
        guard !reduceMotion, let mode = lighting?.mode else { return false }
        return mode == .breathing || mode == .spectrum || mode == .wave
    }

    var body: some View {
        TimelineView(.animation(paused: !isAnimated)) { context in
            let look = appearance(at: isAnimated ? context.date.timeIntervalSinceReferenceDate : 0)
            Capsule()
                .fill(look.style)
                .opacity(look.intensity)
                .shadow(color: look.glow.opacity(look.intensity * 0.8), radius: 6)
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    private func appearance(at time: TimeInterval) -> (style: AnyShapeStyle, glow: Color, intensity: Double) {
        let level = max(0.12, Double(brightness ?? 255) / 255)
        guard let lighting, let mode = lighting.mode, mode != .off else {
            return (AnyShapeStyle(Color.secondary.opacity(0.25)), .clear, 1)
        }
        switch mode {
        case .staticColor:
            let color = Color(lighting.primary)
            return (AnyShapeStyle(color), color, level)
        case .breathing:
            // One breath every four seconds, alternating colours for two-colour breathing.
            let cycle = Int(time / 4)
            let phase = (1 - cos(time / 4 * 2 * .pi)) / 2
            let color: Color
            switch lighting.breathing {
            case .single: color = Color(lighting.primary)
            case .dual: color = Color(cycle.isMultiple(of: 2) ? lighting.primary : lighting.secondary)
            case .random: color = Color(hue: (Double(cycle) * 0.37).truncatingRemainder(dividingBy: 1), saturation: 1, brightness: 1)
            }
            return (AnyShapeStyle(color), color, level * (0.1 + 0.9 * phase))
        case .spectrum:
            let color = Color(hue: (time / 10).truncatingRemainder(dividingBy: 1), saturation: 1, brightness: 1)
            return (AnyShapeStyle(color), color, level)
        case .wave:
            let direction: Double = lighting.waveDirection == .leftToRight ? -1 : 1
            let offset = (time / 4 * direction).truncatingRemainder(dividingBy: 1) + 1
            let colors = (0...6).map { step in
                Color(hue: (Double(step) / 6 + offset).truncatingRemainder(dividingBy: 1), saturation: 1, brightness: 1)
            }
            return (AnyShapeStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)), colors[3], level)
        case .off:
            return (AnyShapeStyle(Color.secondary.opacity(0.25)), .clear, 1)
        }
    }
}

// MARK: - Color Conversion

private extension Color {
    init(_ rgb: RazerChromaProtocol.RGB) {
        self.init(.sRGB, red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
    }
}

private extension RazerChromaProtocol.RGB {
    init(_ color: Color) {
        let srgb = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(red: UInt8((srgb.redComponent * 255).rounded().clamped(to: 0...255)),
                  green: UInt8((srgb.greenComponent * 255).rounded().clamped(to: 0...255)),
                  blue: UInt8((srgb.blueComponent * 255).rounded().clamped(to: 0...255)))
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
