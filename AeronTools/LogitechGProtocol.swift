import Foundation

// MARK: - Logitech G HID++ Features

/// Pure builders and parsers for the gaming-mouse features used by `LogitechGConnector`. Layouts were
/// confirmed against a PRO X2 SUPERSTRIKE.
nonisolated extension HIDPPProtocol {
    static let featureExtendedDPI: UInt16 = 0x2202
    static let featureExtendedReportRate: UInt16 = 0x8061
    static let featureOnboardProfiles: UInt16 = 0x8100
    /// Inductive analog triggers (PRO X2 SUPERSTRIKE): actuation point, rapid trigger and haptic feedback.
    static let featureAnalogTriggers: UInt16 = 0x1B0C

    // MARK: Extended Adjustable DPI (0x2202)

    /// The DPI values a sensor accepts, as contiguous ranges with a fixed step each
    /// (e.g. 100–200 in steps of 1, then 200–500 in steps of 2, …).
    struct DPIRange: Equatable, Sendable {
        struct Segment: Equatable, Sendable {
            let lower: Int
            let upper: Int
            let step: Int
        }

        let segments: [Segment]

        var minimum: Int { segments.first?.lower ?? 0 }
        var maximum: Int { segments.last?.upper ?? 0 }

        /// The closest value the sensor accepts.
        func nearestSupported(_ dpi: Int) -> Int {
            let clamped = min(max(dpi, minimum), maximum)
            guard let segment = segments.first(where: { clamped <= $0.upper }) else { return clamped }
            let offset = ((clamped - segment.lower) + segment.step / 2) / segment.step * segment.step
            return min(segment.lower + offset, segment.upper)
        }
    }

    /// `getSensorDpiRanges` pages: [4] sensor, [5] direction, [6] page, then 13 bytes of a big-endian word list
    /// that continues across pages (a word can be split between two). A word ≥ 0xE000 is the step (low 13 bits)
    /// between the values either side of it; 0x0000 ends the list.
    static func parseDPIRanges(pages: [[UInt8]]) -> DPIRange? {
        let data = pages.flatMap { $0.count >= 20 ? Array($0[7..<20]) : [] }
        var words: [Int] = []
        var index = 0
        while index + 1 < data.count {
            let word = (Int(data[index]) << 8) | Int(data[index + 1])
            if word == 0 { break }
            words.append(word)
            index += 2
        }

        var segments: [DPIRange.Segment] = []
        var previous: Int?
        var pendingStep: Int?
        for word in words {
            if word >= 0xE000 {
                pendingStep = word & 0x1FFF
            } else {
                if let lower = previous, let step = pendingStep, step > 0, word > lower {
                    segments.append(.init(lower: lower, upper: word, step: step))
                }
                previous = word
                pendingStep = nil
            }
        }
        return segments.isEmpty ? nil : DPIRange(segments: segments)
    }

    /// Whether a ranges page holds the list's terminating 0x0000 word, so no further pages are needed.
    static func dpiRangePageEndsList(_ page: [UInt8]) -> Bool {
        guard page.count >= 20 else { return true }
        let data = Array(page[7..<20])
        return stride(from: 0, to: data.count - 1, by: 2).contains { data[$0] == 0 && data[$0 + 1] == 0 }
    }

    struct SensorDPI: Equatable, Sendable {
        let dpi: Int
        let liftOffDistance: UInt8
    }

    /// `getSensorDpiParameters` (function 5): [4] sensor, [5…6] DPI X, [7…8] default X, [9…10] DPI Y,
    /// [11…12] default Y, [13] lift-off distance.
    static func parseSensorDPI(_ reply: [UInt8]) -> SensorDPI? {
        guard reply.count >= 14 else { return nil }
        let dpi = (Int(reply[5]) << 8) | Int(reply[6])
        return dpi > 0 ? SensorDPI(dpi: dpi, liftOffDistance: reply[13]) : nil
    }

    /// `setSensorDpiParameters` (function 6): sensor, DPI X, DPI Y, lift-off distance.
    static func setSensorDPIParams(dpi: Int, liftOffDistance: UInt8) -> [UInt8] {
        let value = UInt16(clamping: dpi)
        return [0x00, UInt8(value >> 8), UInt8(value & 0xFF), UInt8(value >> 8), UInt8(value & 0xFF), liftOffDistance]
    }

    // MARK: Extended Report Rate (0x8061)

    /// Report rates by flag bit / rate index: bit 0 = 125 Hz (8 ms) … bit 6 = 8000 Hz (125 µs).
    static let reportRatesHz: [Int] = [125, 250, 500, 1000, 2000, 4000, 8000]

    /// `getReportRateList` (function 1): [4…5] big-endian flags, one bit per supported rate.
    static func parseSupportedReportRates(_ reply: [UInt8]) -> [Int] {
        guard reply.count >= 6 else { return [] }
        let flags = (Int(reply[4]) << 8) | Int(reply[5])
        return reportRatesHz.indices.filter { flags & (1 << $0) != 0 }.map { reportRatesHz[$0] }
    }

    /// `getReportRate` (function 2): [4] rate index.
    static func parseReportRate(_ reply: [UInt8]) -> Int? {
        guard reply.count >= 5, reportRatesHz.indices.contains(Int(reply[4])) else { return nil }
        return reportRatesHz[Int(reply[4])]
    }

    /// The rate index `setReportRate` (function 3) expects for a rate in Hz.
    static func reportRateIndex(forHz hz: Int) -> UInt8? {
        reportRatesHz.firstIndex(of: hz).map(UInt8.init)
    }

    // MARK: Analog Triggers (0x1B0C)
    //
    // Mapped by passively tracing G HUB. Function 0 reads the limits; function 1 sets one key as
    // [key, actuation, rapid trigger, haptics]; there's no getter (G HUB reads the onboard profile instead).
    // Every value is in steps of 4 per level G HUB shows, e.g. actuation level 5 is sent as 0x14.
    // Rapid trigger also uses bit 0 as its on/off switch: G HUB sent 0x09 (on, level 2), 0x05 (on, level 1)
    // and 0x08 (off).

    /// Raw units per user-facing level.
    static let triggerUnitsPerLevel = 4

    /// The trigger settings, as the levels G HUB shows. Applied to both keys alike.
    struct TriggerSettings: Equatable, Codable, Sendable {
        /// Actuation point, 1 (shallowest) … 10.
        var actuation: Int
        /// Rapid trigger, 0 (off) or 1 … 5.
        var rapidTrigger: Int
        /// Haptic feedback strength, 0 (off) … 5.
        var haptics: Int

        /// The PRO X2 SUPERSTRIKE's onboard profile values (`14 08 0C`: rapid trigger off), used until the user
        /// changes anything.
        static let profileDefault = TriggerSettings(actuation: 5, rapidTrigger: 0, haptics: 3)

        /// The level sent while rapid trigger is off; the device ignores it, and G HUB uses the same.
        static let rapidTriggerOffLevel = 2
    }

    struct TriggerLimits: Equatable, Sendable {
        let maxActuation: Int
        let maxRapidTrigger: Int
        let maxHaptics: Int
    }

    /// `getInfo` (function 0): [6] max actuation, [7] max rapid trigger, [8] max haptics, in raw units.
    static func parseTriggerLimits(_ reply: [UInt8]) -> TriggerLimits? {
        guard reply.count >= 9, reply[6] > 0 else { return nil }
        let units = triggerUnitsPerLevel
        return TriggerLimits(
            maxActuation: Int(reply[6]) / units,
            maxRapidTrigger: Int(reply[7]) / units,
            maxHaptics: Int(reply[8]) / units
        )
    }

    /// `setTrigger` (function 1) parameters for one key (0 = left, 1 = right).
    static func setTriggerParams(key: UInt8, _ settings: TriggerSettings) -> [UInt8] {
        let units = triggerUnitsPerLevel
        let rapidTrigger = settings.rapidTrigger > 0
            ? settings.rapidTrigger * units | 0x01
            : TriggerSettings.rapidTriggerOffLevel * units
        return [
            key,
            UInt8(clamping: settings.actuation * units),
            UInt8(clamping: rapidTrigger),
            UInt8(clamping: settings.haptics * units)
        ]
    }

    // MARK: Mouse Button Spy (0x8110)
    //
    // Mapped by tracing G HUB: function 0 = button count, 1 = start reporting presses over HID++,
    // 2 = stop, 3 = get the button map, 4 = set it. The map lists, per physical button, the button number it
    // reports to macOS; 0 means it reports nothing, so only HID++ sees it. Press events (function 0,
    // software ID 0) carry a big-endian mask in [4…5], bit n-1 = button n.

    static let featureMouseButtonSpy: UInt16 = 0x8110
    /// Standard mouse button numbers of the rear and front side buttons.
    static let backSideButton = 4
    static let forwardSideButton = 5

    /// The button map: every button reports as itself, except `silenced` ones, which only reach HID++.
    static func buttonMap(buttonCount: Int, silencing silenced: Set<Int>) -> [UInt8] {
        (1...max(1, buttonCount)).map { silenced.contains($0) ? 0 : UInt8(clamping: $0) }
    }

    /// The pressed-button mask from a spy event, or nil if the report isn't one.
    static func parseButtonSpyEvent(_ report: [UInt8], expectedFeatureIndex: UInt8) -> UInt16? {
        guard report.count >= 6, report[2] == expectedFeatureIndex, report[3] == 0x00 else { return nil }
        return (UInt16(report[4]) << 8) | UInt16(report[5])
    }

    static func isButtonPressed(_ button: Int, in mask: UInt16) -> Bool {
        (1...16).contains(button) && mask & (1 << (button - 1)) != 0
    }

    // MARK: Onboard Profiles (0x8100)

    enum OnboardMode: UInt8, Sendable {
        /// The mouse runs from a profile stored on it; DPI and report rate changes are refused.
        case onboard = 0x01
        /// The host controls DPI and report rate directly, as Logitech G HUB does.
        case host = 0x02
    }
}
