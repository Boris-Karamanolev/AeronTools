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
    // Function 3 sets the effect (one byte); there's no getter, so the last effect set is remembered by the app.

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

    /// Effect numbers for function 3, mapped on the keyboard one by one.
    enum BacklightEffect: UInt8, CaseIterable, Identifiable, Codable, Sendable {
        case staticLight = 3
        case contrast = 6
        case breathing = 1
        case waves = 4
        case reaction = 2
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
