import Foundation

/// What the app remembers about one external monitor, keyed by its EDID identity so it survives reconnects.
struct MonitorSettings: Codable, Equatable {
    var brightness: Float?
    var volume: Float?
    var isMuted = false
    /// Gamma-based dimming on top of hardware brightness; 1 means none.
    var extraDimming: Float = 1
    /// Input codes from the monitor's capabilities string (slow to read, so cached). Empty means it reported none.
    var inputSources: [UInt8]?
}

@MainActor
final class MonitorSettingsStore {
    static let shared = MonitorSettingsStore()

    private static let defaultsKey = "monitorSettingsV1"
    private var settings: [String: MonitorSettings]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: MonitorSettings].self, from: data) {
            settings = decoded
        } else {
            settings = [:]
        }
    }

    func settings(for key: String) -> MonitorSettings? {
        settings[key]
    }

    func update(_ key: String, _ change: (inout MonitorSettings) -> Void) {
        var value = settings[key] ?? MonitorSettings()
        change(&value)
        guard value != settings[key] else { return }
        settings[key] = value
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
