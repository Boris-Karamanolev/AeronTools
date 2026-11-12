import Foundation

// MARK: - Logitech Keyboard HID++ Features

/// Pure builders and parsers for keyboard features used by `MXMechanicalConnector`. Layouts were mapped by
/// tracing Logi Options+ with an MX Mechanical Mini for Mac.
nonisolated extension HIDPPProtocol {
    static let featureBacklight: UInt16 = 0x1982

    // MARK: Backlight 2 (0x1982)
    //
    // Function 0 reads the configuration (from byte 4):
    //   [0] enabled, [1] options, [2] supported, [3…4] supported effects (LE), [5] level,
    //   [6…7] duration with hands away, [8…9] duration with hands on keys, [10…11] duration while charging
    //   (little-endian, in 5-second units).
    // Function 1 writes it as [enabled, options, 0xFF, level, the three durations]: no effects field, and 0xFF
    // in place of the supported byte, as open-source HID++ tools do. The app reads the configuration back after
    // every write to confirm it took.
    // Options: bits 3–4 = mode (1 automatic brightness, 3 manual level), bit 2 = battery saving.
    // Function 2 reads the backlight info; byte 7 of its reply is the current effect. Function 3 sets the effect
    // (one byte, same numbers).

    struct BacklightConfig: Equatable, Sendable {
        var isEnabled: Bool
        var options: UInt8
        var supported: UInt8
        var effects: UInt16
        var level: UInt8
        var durationAway: UInt16
        var durationTyping: UInt16
        var durationCharging: UInt16

        private static let modeMask: UInt8 = 0x18
        private static let automaticMode: UInt8 = 0x08
        private static let manualMode: UInt8 = 0x18
        private static let batterySavingBit: UInt8 = 0x04

        var isAutomaticBrightness: Bool {
            get { options & Self.modeMask != Self.manualMode }
            set { options = (options & ~Self.modeMask) | (newValue ? Self.automaticMode : Self.manualMode) }
        }

        var isBatterySaving: Bool {
            get { options & Self.batterySavingBit != 0 }
            set { options = newValue ? options | Self.batterySavingBit : options & ~Self.batterySavingBit }
        }

        /// The timeout Options+ shows; it sets all three durations to the same value.
        var durationSeconds: Int {
            get { Int(durationAway) * 5 }
            set {
                let units = UInt16(clamping: max(1, newValue / 5))
                durationAway = units
                durationTyping = units
                durationCharging = units
            }
        }
    }

    static func parseBacklightConfig(_ reply: [UInt8]) -> BacklightConfig? {
        guard reply.count >= 16 else { return nil }
        func le(_ index: Int) -> UInt16 { UInt16(reply[index]) | (UInt16(reply[index + 1]) << 8) }
        return BacklightConfig(
            isEnabled: reply[4] != 0,
            options: reply[5],
            supported: reply[6],
            effects: le(7),
            level: reply[9],
            durationAway: le(10),
            durationTyping: le(12),
            durationCharging: le(14)
        )
    }

    static func setBacklightConfigParams(_ config: BacklightConfig) -> [UInt8] {
        func le(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
        return [config.isEnabled ? 0x01 : 0x00, config.options, 0xFF, config.level]
            + le(config.durationAway) + le(config.durationTyping) + le(config.durationCharging)
    }

    /// Effect numbers, mapped by reading the keyboard's current effect after each selection in Logi Options+.
    enum BacklightEffect: UInt8, CaseIterable, Identifiable, Codable, Sendable {
        case staticLight = 0
        case contrast = 3
        case breathing = 2
        case waves = 6
        case reaction = 4
        case random = 5

        var id: UInt8 { rawValue }

        var title: String {
            switch self {
            case .staticLight: return "Static"
            case .contrast: return "Contrast"
            case .breathing: return "Breathing"
            case .waves: return "Waves"
            case .reaction: return "Reaction"
            case .random: return "Random"
            }
        }
    }
}

nonisolated extension HIDPPProtocol {
    /// The current effect from a backlight-info reply (function 2): byte 7.
    static func parseBacklightEffect(_ reply: [UInt8]) -> BacklightEffect? {
        reply.count > 7 ? BacklightEffect(rawValue: reply[7]) : nil
    }
}

// MARK: - Fn Keys & Key Remapping

nonisolated extension HIDPPProtocol {
    static let featureFnInversion: UInt16 = 0x40A3
    static let featureChangeHost: UInt16 = 0x1814

    // Fn inversion (0x40A3), per Easy-Switch host, mapped by tracing Options+:
    //   function 0 [host] → [host, state, …], function 1 [host, state]. State 1 = F1–F12 act as standard function
    //   keys; 0 = they're media keys (Fn gives the F-keys).

    /// The Fn state from a function-0 reply for `host`.
    static func parseFnInversion(_ reply: [UInt8], host: UInt8) -> Bool? {
        guard reply.count >= 6, reply[4] == host else { return nil }
        return reply[5] != 0
    }

    /// ChangeHost (0x1814) function 0: [4] number of hosts, [5] current host.
    static func parseCurrentHost(_ reply: [UInt8]) -> UInt8? {
        reply.count >= 6 ? reply[5] : nil
    }

    // Reprogrammable Controls (0x1B04): function 0 = control count, function 1 [index] = control info:
    //   [cid hi, cid lo, task hi, task lo, flags, F-key position, group, …]. Remapping diverts a key's control so
    //   its presses reach only this app (the same mechanism as the MX Master's buttons); Options+ remapped F4 by
    //   diverting control 0x00E2.

    struct KeyControl: Equatable, Sendable {
        let cid: UInt16
        /// The key's own function (e.g. 0x00C1 backlight down), as Logitech numbers tasks.
        let task: UInt16
        /// 1…12 for F1–F12, 0 for other keys.
        let fKeyPosition: Int
        let isDivertable: Bool
    }

    private static let divertableFlag: UInt8 = 0x20

    static func parseKeyControl(_ reply: [UInt8]) -> KeyControl? {
        guard reply.count >= 10 else { return nil }
        let cid = (UInt16(reply[4]) << 8) | UInt16(reply[5])
        guard cid != 0 else { return nil }
        let task = (UInt16(reply[6]) << 8) | UInt16(reply[7])
        return KeyControl(cid: cid, task: task, fKeyPosition: Int(reply[9]), isDivertable: reply[8] & divertableFlag != 0)
    }
}

// MARK: - RGB Effects & Brightness (Logitech G keyboards)

nonisolated extension HIDPPProtocol {
    static let featureRGBEffects: UInt16 = 0x8071
    static let featureBrightnessControl: UInt16 = 0x8040

    // RGB Effects (0x8071), read from a G515 LIGHTSPEED TKL:
    //   function 0 [zone, effect, 0] → [zone, effect, effect ID (BE), …]; [0xFF, 0xFF] describes the device
    //   ([2] = zone count) and [zone, 0xFF] the zone ([4] = effect count). The effect index used to set an
    //   effect is the keyboard's own numbering, so it's read rather than assumed.
    //   function 1 [zone, effect index, 10 effect parameters, persistence] sets an effect. G HUB's effect
    //   writes are function 1 too. Parameter offsets follow the effect IDs as open-source HID++ tools use them.

    /// The keyboard's built-in effects. G HUB's Pulsar Point, Echo Press, Starlight and Screen Sampler are
    /// drawn by G HUB itself, key by key, so they aren't here. The keyboard also lists Ripple (0x0017), which
    /// accepts the layouts tried so far but never lights up, so it's left out.
    enum RGBEffect: UInt16, CaseIterable, Identifiable, Codable, Sendable {
        case off = 0x0000
        case fixed = 0x0001
        case breathing = 0x000A
        case colorCycle = 0x0015
        case colorWave = 0x0016

        var id: UInt16 { rawValue }

        var title: String {
            switch self {
            case .off: return "Off"
            case .fixed: return "Fixed"
            case .breathing: return "Breathing"
            case .colorCycle: return "Color Cycle"
            case .colorWave: return "Color Wave"
            }
        }

        var usesColor: Bool { self == .fixed || self == .breathing }
        var usesSpeed: Bool { self != .off && self != .fixed }
    }

    struct RGBColor: Codable, Equatable, Sendable {
        var red: UInt8
        var green: UInt8
        var blue: UInt8

        static let white = RGBColor(red: 0xFF, green: 0xFF, blue: 0xFF)
    }

    /// The lighting chosen in the app. Speed is 1 (slowest) … 10 (fastest).
    struct RGBLighting: Codable, Equatable, Sendable {
        var effect: RGBEffect = .fixed
        var color: RGBColor = .white
        var speed: Int = 5

        static let speedRange = 1...10

        /// Effect period in milliseconds: 10 s at the slowest, 1 s at the fastest (twice that for the
        /// whole-keyboard colour cycle and wave, which look frantic otherwise).
        var periodMilliseconds: UInt16 {
            let clamped = min(max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
            let base = 11_000 - clamped * 1_000
            return UInt16(effect == .colorCycle || effect == .colorWave ? base * 2 : base)
        }
    }

    /// The effect a function-0 [zone, effect] reply describes, with the index to set it by.
    static func parseRGBZoneEffect(_ reply: [UInt8]) -> (index: UInt8, effect: RGBEffect)? {
        guard reply.count >= 8 else { return nil }
        let id = (UInt16(reply[6]) << 8) | UInt16(reply[7])
        return RGBEffect(rawValue: id).map { (reply[5], $0) }
    }

    /// Function 1's parameters: [zone, effect index, 10 effect parameters, persistence (1 = keep after power-off)].
    static func setRGBEffectParams(zone: UInt8, index: UInt8, lighting: RGBLighting) -> [UInt8] {
        var effect = [UInt8](repeating: 0, count: 10)
        let color = lighting.color
        let period = lighting.periodMilliseconds
        switch lighting.effect {
        case .off:
            break
        case .fixed:
            effect[0...2] = [color.red, color.green, color.blue]
        case .breathing:
            // Colour, period, waveform (0 = default), intensity (100%).
            effect[0...2] = [color.red, color.green, color.blue]
            effect[3...4] = [UInt8(period >> 8), UInt8(period & 0xFF)]
            effect[6] = 100
        case .colorCycle, .colorWave:
            // Full saturation, period, intensity (100%).
            effect[1] = 0xFF
            effect[6...7] = [UInt8(period >> 8), UInt8(period & 0xFF)]
            effect[8] = 100
        }
        return [zone, index] + effect + [0x01]
    }

    // Brightness Control (0x8040): function 0 → [max (BE), steps, capabilities], function 1 → [level (BE)],
    // function 2 [level (BE)] sets it. The keyboard's brightness key pushes function-0 events with the new level.

    static func parseBrightnessLevel(_ report: [UInt8]) -> Int? {
        report.count >= 6 ? (Int(report[4]) << 8) | Int(report[5]) : nil
    }

    static func setBrightnessParams(_ level: Int) -> [UInt8] {
        let clamped = UInt16(clamping: max(0, level))
        return [UInt8(clamped >> 8), UInt8(clamped & 0xFF)]
    }
}

// MARK: - Game Mode (Logitech G keyboards)

nonisolated extension HIDPPProtocol {
    /// Disable Controls by CIDX (0x4523): the game mode feature. Read from a G515 LIGHTSPEED TKL while toggling
    /// game mode with its key: function 2 → [1 while game mode is on], and the keyboard pushes a function-0 event
    /// [state] each time the key is pressed. Which keys game mode blocks isn't readable this way.
    static let featureGameMode: UInt16 = 0x4523

    static func parseGameModeState(_ report: [UInt8]) -> Bool? {
        report.count > 4 ? report[4] != 0 : nil
    }
}
