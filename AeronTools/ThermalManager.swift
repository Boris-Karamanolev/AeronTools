import Foundation
import IOKit
import Observation

// MARK: - ThermalSnapshot

public struct FanReading: Sendable, Identifiable {
    public let id: Int
    /// Current fan speed in RPM.
    public let rpm: Double
    /// Maximum rated speed of this fan.
    public let maxRPM: Double
    /// Whether the SMC reports the fan in forced (manual) mode rather than automatic.
    public let isManual: Bool

    /// Speed as a fraction of the fan's rated maximum (0...1).
    public var fraction: Double {
        guard maxRPM > 0 else { return 0 }
        return min(1, max(0, rpm / maxRPM))
    }
}

public struct ThermalSnapshot: Sendable {
    /// Average CPU die temperature in °C.
    public let cpuCelsius: Double?
    /// Average GPU die temperature in °C.
    public let gpuCelsius: Double?
    /// Battery temperature in °C (laptops only).
    public let batteryCelsius: Double?
    /// One entry per physical fan. Empty on fanless Macs (e.g. MacBook Air).
    public let fans: [FanReading]
    /// System-wide thermal pressure as reported by macOS.
    public let thermalState: ProcessInfo.ThermalState
}

// MARK: - ThermalManager

@Observable
@MainActor
public final class ThermalManager {
    public static let shared = ThermalManager()

    public private(set) var currentSnapshot: ThermalSnapshot?
    public private(set) var isMonitoring: Bool = false
    public private(set) var isSupported: Bool = true

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private lazy var sensorKeys = SensorKeys.forCurrentChip()

    private init() {
        isSupported = SMCConnection.shared != nil
    }

    /// Starts polling the SMC. Only called while something shows the readings: the open popover or a menu bar stat.
    public func startMonitoring() {
        guard isSupported, !isMonitoring else { return }
        isMonitoring = true

        sample()

        timer?.invalidate()
        // Scheduled on the main run loop, so each tick runs on the main actor directly.
        let timer = Timer.scheduledTimer(withTimeInterval: SMCConnection.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isMonitoring else { return }
                self.sample()
            }
        }
        // Lets macOS batch the wakeup with other work; a reading a moment late doesn't matter.
        timer.tolerance = SMCConnection.pollTolerance
        self.timer = timer
    }

    /// Stops polling immediately, so nothing runs while no readings are shown.
    public func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        guard let smc = SMCConnection.shared else { return }

        let fanCount = Int(smc.readValue("FNum") ?? 0)
        let fans: [FanReading] = (0..<fanCount).compactMap { i in
            guard let rpm = smc.readValue("F\(i)Ac") else { return nil }
            return FanReading(
                id: i,
                rpm: max(0, rpm),
                maxRPM: smc.readValue("F\(i)Mx") ?? 0,
                isManual: (smc.readValue("F\(i)Md") ?? 0) == 1
            )
        }

        currentSnapshot = ThermalSnapshot(
            cpuCelsius: averageTemperature(of: sensorKeys.cpu, using: smc),
            gpuCelsius: averageTemperature(of: sensorKeys.gpu, using: smc),
            batteryCelsius: readBatteryTemperature(),
            fans: fans,
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }

    /// Averages the given sensors, discarding missing keys and implausible readings
    /// (some SMC sensors report placeholder values when idle or unpopulated).
    private func averageTemperature(of keys: [String], using smc: SMCConnection) -> Double? {
        let readings = keys.compactMap { smc.readValue($0) }.filter { (10...120).contains($0) }
        guard !readings.isEmpty else { return nil }
        return readings.reduce(0, +) / Double(readings.count)
    }

    /// Battery temperature from AppleSmartBattery, reported in hundredths of a degree Celsius.
    private func readBatteryTemperature() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let value = IORegistryEntryCreateCFProperty(service, "Temperature" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Int, value > 0 else {
            return nil
        }
        return Double(value) / 100.0
    }
}

// MARK: - SensorKeys

/// SMC temperature keys differ between chip generations; these are the die sensors for each family.
private struct SensorKeys {
    let cpu: [String]
    let gpu: [String]

    private static let m1 = SensorKeys(
        cpu: ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"],
        gpu: ["Tg05", "Tg0D", "Tg0L", "Tg0T"]
    )
    private static let m2 = SensorKeys(
        cpu: ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"],
        gpu: ["Tg0f", "Tg0j"]
    )
    private static let m3 = SensorKeys(
        cpu: ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
              "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"],
        gpu: ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]
    )
    private static let m4 = SensorKeys(
        cpu: ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"],
        gpu: ["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"]
    )
    private static let intel = SensorKeys(
        cpu: ["TC0P", "TC0D", "TC0E", "TC0F"],
        gpu: ["TG0P", "TG0D", "TCGC"]
    )

    static func forCurrentChip() -> SensorKeys {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let brand = String(cString: buffer)

        if brand.contains("Intel") { return intel }
        if brand.contains("M1") { return m1 }
        if brand.contains("M2") { return m2 }
        if brand.contains("M3") { return m3 }
        if brand.contains("M4") { return m4 }

        // Unknown (newer) Apple silicon: probe every known key; missing ones are simply skipped.
        let all = [m1, m2, m3, m4]
        return SensorKeys(
            cpu: Array(Set(all.flatMap(\.cpu))),
            gpu: Array(Set(all.flatMap(\.gpu)))
        )
    }
}
