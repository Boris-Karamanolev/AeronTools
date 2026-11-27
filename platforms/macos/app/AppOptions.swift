import Foundation
import IOKit.ps

// MARK: - Brightness Automation

public enum BrightnessAutomation: String, CaseIterable, Identifiable {
    case off
    case matchMacBook
    case schedule

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .matchMacBook: return "Match MacBook screen"
        case .schedule: return "Day & night schedule"
        }
    }
}

nonisolated enum BrightnessSchedule {
    /// Whether `minuteOfDay` (0..<1440) falls in the night window, which may wrap past midnight.
    static func isNight(minuteOfDay: Int, nightStart: Int, dayStart: Int) -> Bool {
        if nightStart == dayStart {
            return false
        }
        if nightStart < dayStart {
            return minuteOfDay >= nightStart && minuteOfDay < dayStart
        }
        return minuteOfDay >= nightStart || minuteOfDay < dayStart
    }

    static func minuteOfDay(_ date: Date, calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

// MARK: - Menu Bar Stats

public enum MenuBarStat: String, CaseIterable, Identifiable {
    case none
    case watts
    case cpuTemperature
    case wattsAndTemperature

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: return "Icon only"
        case .watts: return "System power (W)"
        case .cpuTemperature: return "CPU temperature"
        case .wattsAndTemperature: return "Power and temperature"
        }
    }

    var showsWatts: Bool { self == .watts || self == .wattsAndTemperature }
    var showsTemperature: Bool { self == .cpuTemperature || self == .wattsAndTemperature }

    /// Compact text for the status item, e.g. "12.3 W · 54°".
    nonisolated static func text(watts: Double?, cpuCelsius: Double?, showWatts: Bool, showTemperature: Bool) -> String {
        var parts: [String] = []
        if showWatts, let watts {
            parts.append(String(format: "%.1f W", watts))
        }
        if showTemperature, let cpuCelsius {
            parts.append(String(format: "%.0f°", cpuCelsius))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Caffeine

public enum CaffeineDuration: CaseIterable, Identifiable {
    case fifteenMinutes, oneHour, twoHours, fourHours, eightHours, indefinitely

    public var id: Self { self }

    public var seconds: TimeInterval? {
        switch self {
        case .fifteenMinutes: return 15 * 60
        case .oneHour: return 3600
        case .twoHours: return 2 * 3600
        case .fourHours: return 4 * 3600
        case .eightHours: return 8 * 3600
        case .indefinitely: return nil
        }
    }

    public var title: String {
        switch self {
        case .fifteenMinutes: return "For 15 Minutes"
        case .oneHour: return "For 1 Hour"
        case .twoHours: return "For 2 Hours"
        case .fourHours: return "For 4 Hours"
        case .eightHours: return "For 8 Hours"
        case .indefinitely: return "Indefinitely"
        }
    }
}

enum PowerSource {
    static var isOnACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }

    private static var changeHandlers: [() -> Void] = []
    private static var runLoopSource: CFRunLoopSource?

    /// Calls `handler` whenever any power source changes: the charger, the Mac's battery, or an accessory's.
    static func onChange(_ handler: @escaping () -> Void) {
        changeHandlers.append(handler)
        guard runLoopSource == nil else { return }
        let callback: IOPowerSourceCallbackType = { _ in
            MainActor.assumeIsolated { PowerSource.changeHandlers.forEach { $0() } }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }
}
