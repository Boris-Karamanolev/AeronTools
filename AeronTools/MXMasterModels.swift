import Foundation

// MARK: - MX Master Configuration Models

/// Connection transport detected for the Logitech MX Master mouse.
public enum MXConnectionTransport: String, Codable, Sendable, Equatable {
    case bluetoothLE = "Bluetooth LE"
    case logiBolt = "Logi Bolt Receiver"
    case unifying = "Unifying Receiver"
    case usbWired = "USB-C Wired"
    case disconnected = "Not Connected"

    public var symbolName: String {
        switch self {
        case .bluetoothLE: return "dot.radiowaves.left.and.right"
        case .logiBolt, .unifying: return "antenna.radiowaves.left.and.right"
        case .usbWired: return "cable.connector.horizontal"
        case .disconnected: return "computermouse"
        }
    }
}

/// MagSpeed electromagnetic scroll wheel mode.
public enum MXWheelMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case ratchet = "ratchet"
    case freeSpin = "freeSpin"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ratchet: return "Ratchet"
        case .freeSpin: return "Free-Spin"
        }
    }

    public var subtitle: String {
        switch self {
        case .ratchet: return "Precise line-by-line notched scrolling"
        case .freeSpin: return "Hyper-fast frictionless inertia scrolling"
        }
    }

    /// HID++ 2.0 SmartShift wheel mode value (`1` = Free-Spin, `2` = Ratchet).
    nonisolated public var hidppValue: UInt8 {
        switch self {
        case .freeSpin: return 0x01
        case .ratchet: return 0x02
        }
    }

    nonisolated public init?(hidppValue: UInt8) {
        switch hidppValue {
        case 0x01: self = .freeSpin
        case 0x02: self = .ratchet
        default: return nil
        }
    }
}

/// Action assigned to the MX Master horizontal thumbwheel.
public enum MXThumbwheelAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case horizontalScroll
    case displayBrightness
    case displayVolume
    case switchSpaces
    case switchTabs
    case zoom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .horizontalScroll: return "Horizontal Scroll"
        case .displayBrightness: return "Brightness (Display Under Pointer)"
        case .displayVolume: return "Volume (Display Under Pointer)"
        case .switchSpaces: return "Switch Desktop Spaces"
        case .switchTabs: return "Switch Browser / App Tabs"
        case .zoom: return "Zoom In / Out (⌘+ / ⌘-)"
        }
    }

    public var shortTitle: String {
        switch self {
        case .horizontalScroll: return "Horiz. Scroll"
        case .displayBrightness: return "Brightness"
        case .displayVolume: return "Volume"
        case .switchSpaces: return "Spaces"
        case .switchTabs: return "App Tabs"
        case .zoom: return "Zoom"
        }
    }
}

/// Persisted user configuration for the MX Master 4.
public struct MXMasterConfig: Codable, Equatable, Sendable {
    public var dpi: Int = 1600
    public var wheelMode: MXWheelMode = .ratchet
    public var smartShiftEnabled: Bool = true
    /// SmartShift auto-disengage sensitivity threshold (1 = lightest flick, 50 = hardest flick).
    public var smartShiftThreshold: Int = 25

    /// Inverts vertical mouse wheel scroll so the mouse uses Standard scrolling while Trackpad stays Natural.
    public var standardVerticalScroll: Bool = true
    /// Enables high-frequency pixel-interpolated smooth scrolling for discrete mouse wheel ticks.
    public var smoothScrolling: Bool = true
    /// Scroll speed multiplier (0.5 ... 3.0).
    public var scrollSpeedMultiplier: Double = 1.25

    public var thumbwheelAction: MXThumbwheelAction = .horizontalScroll
    public var invertThumbwheel: Bool = false

    public var middleButtonAction: AccessoryButtonAction = .systemDefault
    public var backButtonAction: AccessoryButtonAction = .navigateBack
    public var forwardButtonAction: AccessoryButtonAction = .navigateForward
    public var gestureButtonClickAction: AccessoryButtonAction = .missionControl
    /// Button behind the scroll wheel; `.systemDefault` keeps the hardware Ratchet / Free-Spin toggle.
    public var modeShiftButtonAction: AccessoryButtonAction = .systemDefault
    /// Haptic sense panel under the thumb.
    public var hapticPanelButtonAction: AccessoryButtonAction = .systemDefault

    public var gesturesEnabled: Bool = true
    public var gestureUpAction: AccessoryButtonAction = .missionControl
    public var gestureDownAction: AccessoryButtonAction = .appExpose
    public var gestureLeftAction: AccessoryButtonAction = .spaceLeft
    public var gestureRightAction: AccessoryButtonAction = .spaceRight

    public init() {}

    /// Decodes leniently so newly added settings fall back to defaults instead of discarding the saved configuration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MXMasterConfig()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        dpi = value(.dpi, d.dpi)
        wheelMode = value(.wheelMode, d.wheelMode)
        smartShiftEnabled = value(.smartShiftEnabled, d.smartShiftEnabled)
        smartShiftThreshold = value(.smartShiftThreshold, d.smartShiftThreshold)
        standardVerticalScroll = value(.standardVerticalScroll, d.standardVerticalScroll)
        smoothScrolling = value(.smoothScrolling, d.smoothScrolling)
        scrollSpeedMultiplier = value(.scrollSpeedMultiplier, d.scrollSpeedMultiplier)
        thumbwheelAction = value(.thumbwheelAction, d.thumbwheelAction)
        invertThumbwheel = value(.invertThumbwheel, d.invertThumbwheel)
        middleButtonAction = value(.middleButtonAction, d.middleButtonAction)
        backButtonAction = value(.backButtonAction, d.backButtonAction)
        forwardButtonAction = value(.forwardButtonAction, d.forwardButtonAction)
        gestureButtonClickAction = value(.gestureButtonClickAction, d.gestureButtonClickAction)
        modeShiftButtonAction = value(.modeShiftButtonAction, d.modeShiftButtonAction)
        hapticPanelButtonAction = value(.hapticPanelButtonAction, d.hapticPanelButtonAction)
        gesturesEnabled = value(.gesturesEnabled, d.gesturesEnabled)
        gestureUpAction = value(.gestureUpAction, d.gestureUpAction)
        gestureDownAction = value(.gestureDownAction, d.gestureDownAction)
        gestureLeftAction = value(.gestureLeftAction, d.gestureLeftAction)
        gestureRightAction = value(.gestureRightAction, d.gestureRightAction)
    }

    /// Clamps DPI to the supported sensor range and 50-DPI step size of the MX Master 4 (200...8000 DPI).
    nonisolated public static func clampedDPI(_ rawDPI: Int, minDPI: Int = 200, maxDPI: Int = 8000, step: Int = 50) -> Int {
        let clamped = min(maxDPI, max(minDPI, rawDPI))
        guard step > 0 else { return clamped }
        let offset = clamped - minDPI
        let roundedOffset = Int((Double(offset) / Double(step)).rounded()) * step
        return min(maxDPI, max(minDPI, minDPI + roundedOffset))
    }

    /// Clamps SmartShift threshold to valid HID++ range (1...50).
    nonisolated public static func clampedSmartShiftThreshold(_ raw: Int) -> Int {
        min(50, max(1, raw))
    }
}

/// Real-time hardware telemetry snapshot for the connected Logitech mouse.
public struct MXMasterSnapshot: Sendable, Equatable {
    public let deviceName: String
    public let productID: Int
    public let transport: MXConnectionTransport
    public let batteryPercent: Int?
    public let isCharging: Bool
    public let hidppConnected: Bool
    public let minDPI: Int
    public let maxDPI: Int
    public let dpiStep: Int
    public let reportedDPI: Int?
    public let reportedWheelMode: MXWheelMode?
    public let reportedSmartShiftEnabled: Bool?
    public let reportedSmartShiftThreshold: Int?
}

extension MXMasterSnapshot {
    /// The same snapshot with the device's own name, as reported over HID++.
    func withDeviceName(_ name: String) -> MXMasterSnapshot {
        MXMasterSnapshot(
            deviceName: name,
            productID: productID,
            transport: transport,
            batteryPercent: batteryPercent,
            isCharging: isCharging,
            hidppConnected: hidppConnected,
            minDPI: minDPI,
            maxDPI: maxDPI,
            dpiStep: dpiStep,
            reportedDPI: reportedDPI,
            reportedWheelMode: reportedWheelMode,
            reportedSmartShiftEnabled: reportedSmartShiftEnabled,
            reportedSmartShiftThreshold: reportedSmartShiftThreshold
        )
    }
}
