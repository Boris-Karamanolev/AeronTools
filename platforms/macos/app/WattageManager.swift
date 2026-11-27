import Foundation
import IOKit
import Observation

// MARK: - WattageSnapshot

public struct WattageSnapshot: Sendable {
    /// Real-time total system power load in Watts (e.g. 10.5 W).
    public let systemLoadWatts: Double?
    /// Real-time power delivered to the system from external power (e.g. 20.0 W from USB-C PD or MagSafe).
    public let inputWatts: Double?
    /// Rated wattage of the attached power adapter (e.g. 20W, 65W, 96W, 140W).
    public let adapterWatts: Int?
    /// Battery charge rate (positive, e.g. +8.2 W) or discharge rate (negative, e.g. -5.5 W).
    public let batteryWatts: Double?
    /// Current battery charge percentage (0-100).
    public let batteryLevel: Int
    /// Whether the battery is actively charging.
    public let isCharging: Bool
    /// Whether connected to AC power / external charger.
    public let isPluggedIn: Bool
    /// Current battery voltage in Volts.
    public let voltage: Double?
    /// Current battery amperage in Amperes.
    public let amperage: Double?
    /// Charge cycles used so far, and the number the battery is rated for.
    public let cycleCount: Int?
    public let designCycleCount: Int?
    /// Full-charge capacity relative to design capacity, as System Settings reports "Maximum Capacity".
    public let maximumCapacityPercent: Int?

    /// Returns nil for missing or nonsensical capacities; caps at 100 like System Settings.
    nonisolated static func healthPercent(nominalCapacity: Int?, designCapacity: Int?) -> Int? {
        guard let nominalCapacity, let designCapacity, nominalCapacity > 0, designCapacity > 0 else { return nil }
        return min(100, Int((Double(nominalCapacity) / Double(designCapacity) * 100).rounded()))
    }
}

// MARK: - WattageManager

@Observable
@MainActor
public final class WattageManager {
    public static let shared = WattageManager()

    public private(set) var currentSnapshot: WattageSnapshot?
    public private(set) var isMonitoring: Bool = false
    public private(set) var isSupported: Bool = true

    private var timer: Timer?

    private init() {
        checkHardwareSupport()
    }

    private func checkHardwareSupport() {
        let matching = IOServiceMatching("AppleSmartBattery")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        if service != 0 {
            IOObjectRelease(service)
            self.isSupported = true
        } else {
            self.isSupported = false
        }
    }

    /// Starts polling power metrics. Only called while something shows the readings: the open popover or a menu
    /// bar stat.
    public func startMonitoring() {
        guard isSupported else { return }
        guard !isMonitoring else { return }
        isMonitoring = true

        // Immediate sample on open so UI displays current wattage instantly
        samplePower()

        timer?.invalidate()
        // Scheduled on the main run loop, so each tick runs on the main actor directly.
        let timer = Timer.scheduledTimer(withTimeInterval: SMCConnection.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isMonitoring else { return }
                self.samplePower()
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

    /// Samples hardware power telemetry from the IOKit registry.
    public func samplePower() {
        let matching = IOServiceMatching("AppleSmartBattery")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else {
            return
        }

        let isPluggedIn = (dict["ExternalConnected"] as? Bool ?? false) || (dict["AppleRawExternalConnected"] as? Int == 1)
        let isCharging = dict["IsCharging"] as? Bool ?? false
        let batteryLevel = dict["CurrentCapacity"] as? Int ?? 0

        let rawVoltage = dict["Voltage"] as? Double ?? dict["AppleRawBatteryVoltage"] as? Double ?? 0
        let voltage = rawVoltage > 0 ? rawVoltage / 1000.0 : nil

        let rawAmperage = dict["InstantAmperage"] as? Double ?? dict["Amperage"] as? Double ?? 0
        let amperage = rawAmperage / 1000.0

        var batteryWatts: Double? = nil
        if let telemetry = dict["PowerTelemetryData"] as? [String: Any] {
            if let bp = telemetry["BatteryPower"] as? Double {
                batteryWatts = bp / 1000.0
            } else if let bpStr = telemetry["BatteryPower"] as? String, let bp = Double(bpStr) {
                batteryWatts = bp / 1000.0
            }
        }
        if batteryWatts == nil, let v = voltage {
            batteryWatts = (isCharging ? 1.0 : -1.0) * abs(v * amperage)
        }

        // AppleSmartBattery only refreshes its registry properties about once a minute, so prefer
        // the SMC's live power keys (updated ~1 s): PSTR = total system power, PDTR = DC input power.
        let smc = SMCConnection.shared
        let liveSystemWatts = smc?.readValue("PSTR").flatMap { $0 > 0 ? $0 : nil }
        let liveInputWatts = isPluggedIn ? smc?.readValue("PDTR").flatMap { $0 > 0 ? $0 : nil } : nil

        // On battery the whole system load comes from the battery, so the live figure is also the discharge rate.
        if !isPluggedIn, let live = liveSystemWatts {
            batteryWatts = -live
        }

        var systemLoadWatts: Double? = liveSystemWatts
        if systemLoadWatts == nil, let telemetry = dict["PowerTelemetryData"] as? [String: Any],
           let load = telemetry["SystemLoad"] as? Double {
            systemLoadWatts = load / 1000.0
        }
        if systemLoadWatts == nil, !isPluggedIn, let bw = batteryWatts {
            systemLoadWatts = abs(bw)
        }

        var inputWatts: Double? = liveInputWatts
        if inputWatts == nil, let dist = dict["PowerDistribution"] as? [String: Any],
           let mw = dist["IPDInputPower"] as? Double {
            inputWatts = mw / 1000.0
        }
        if inputWatts == nil, let telemetry = dict["PowerTelemetryData"] as? [String: Any],
           let pi = telemetry["SystemPowerIn"] as? Double {
            inputWatts = pi / 1000.0
        }

        let adapterWatts = (dict["AdapterDetails"] as? [String: Any])?["Watts"] as? Int

        // Apple silicon nests capacities in BatteryData; Intel Macs expose them at the top level.
        let batteryData = dict["BatteryData"] as? [String: Any]
        let nominalCapacity = batteryData?["NominalChargeCapacity"] as? Int
            ?? dict["NominalChargeCapacity"] as? Int
            ?? dict["AppleRawMaxCapacity"] as? Int
        let designCapacity = batteryData?["DesignCapacity"] as? Int ?? dict["DesignCapacity"] as? Int

        self.currentSnapshot = WattageSnapshot(
            systemLoadWatts: systemLoadWatts,
            inputWatts: inputWatts,
            adapterWatts: adapterWatts,
            batteryWatts: batteryWatts,
            batteryLevel: batteryLevel,
            isCharging: isCharging,
            isPluggedIn: isPluggedIn,
            voltage: voltage,
            amperage: amperage,
            cycleCount: dict["CycleCount"] as? Int,
            designCycleCount: dict["DesignCycleCount9C"] as? Int,
            maximumCapacityPercent: WattageSnapshot.healthPercent(nominalCapacity: nominalCapacity, designCapacity: designCapacity)
        )
    }
}
