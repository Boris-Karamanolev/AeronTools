import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import Carbon.HIToolbox
import IOKit
import IOKit.hid
import IOKit.ps
import Observation
import UserNotifications

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

/// Action assignable to MX Master buttons or directional hold-and-drag gestures.
public enum MXButtonAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case systemDefault
    case missionControl
    case appExpose
    case showDesktop
    case launchpad
    case spaceLeft
    case spaceRight
    case navigateBack
    case navigateForward
    case playPause
    case mutePointerDisplay
    case toggleMacBookScreen
    case toggleCaffeine
    case toggleWheelMode
    case copy
    case paste

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .systemDefault: return "System Default"
        case .missionControl: return "Mission Control"
        case .appExpose: return "App Exposé"
        case .showDesktop: return "Show Desktop"
        case .launchpad: return "Launchpad"
        case .spaceLeft: return "Move a Space Left"
        case .spaceRight: return "Move a Space Right"
        case .navigateBack: return "Back (⌘[)"
        case .navigateForward: return "Forward (⌘])"
        case .playPause: return "Play / Pause Media"
        case .mutePointerDisplay: return "Mute Display Under Pointer"
        case .toggleMacBookScreen: return "Toggle MacBook Screen"
        case .toggleCaffeine: return "Toggle Caffeine"
        case .toggleWheelMode: return "Toggle Ratchet / Free-Spin"
        case .copy: return "Copy (⌘C)"
        case .paste: return "Paste (⌘V)"
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

    public var middleButtonAction: MXButtonAction = .systemDefault
    public var backButtonAction: MXButtonAction = .navigateBack
    public var forwardButtonAction: MXButtonAction = .navigateForward
    public var gestureButtonClickAction: MXButtonAction = .missionControl
    /// Button behind the scroll wheel; `.systemDefault` keeps the hardware Ratchet / Free-Spin toggle.
    public var modeShiftButtonAction: MXButtonAction = .systemDefault
    /// Haptic sense panel under the thumb.
    public var hapticPanelButtonAction: MXButtonAction = .systemDefault

    public var gesturesEnabled: Bool = true
    public var gestureUpAction: MXButtonAction = .missionControl
    public var gestureDownAction: MXButtonAction = .appExpose
    public var gestureLeftAction: MXButtonAction = .spaceLeft
    public var gestureRightAction: MXButtonAction = .spaceRight

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

/// Which sections of the menu bar popover card are visible, plus the low-battery alert preference.
public struct MXMasterCardOptions: Codable, Equatable, Sendable {
    public var showBatteryBar: Bool = true
    public var showWheelControls: Bool = true
    public var showDPIControls: Bool = true
    public var showThumbwheel: Bool = true

    public var lowBatteryAlertEnabled: Bool = true
    /// Battery percentage at or below which a notification is posted (5...50).
    public var lowBatteryThreshold: Int = 15

    public init() {}

    /// Decodes leniently so newly added options fall back to defaults instead of discarding saved settings.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MXMasterCardOptions()
        showBatteryBar = try container.decodeIfPresent(Bool.self, forKey: .showBatteryBar) ?? defaults.showBatteryBar
        showWheelControls = try container.decodeIfPresent(Bool.self, forKey: .showWheelControls) ?? defaults.showWheelControls
        showDPIControls = try container.decodeIfPresent(Bool.self, forKey: .showDPIControls) ?? defaults.showDPIControls
        showThumbwheel = try container.decodeIfPresent(Bool.self, forKey: .showThumbwheel) ?? defaults.showThumbwheel
        lowBatteryAlertEnabled = try container.decodeIfPresent(Bool.self, forKey: .lowBatteryAlertEnabled) ?? defaults.lowBatteryAlertEnabled
        lowBatteryThreshold = try container.decodeIfPresent(Int.self, forKey: .lowBatteryThreshold) ?? defaults.lowBatteryThreshold
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

// MARK: - HID++ 2.0 Protocol Framing & Parsing

/// Pure, nonisolated HID++ 2.0 packet builder and parser for Logitech mice (BLE, Logi Bolt, Unifying, USB).
nonisolated public enum HIDPPProtocol {
    public static let logitechVendorID: Int = 0x046D
    public static let boltReceiverProductID: Int = 0xC548
    public static let unifyingReceiverProductID: Int = 0xC52B

    public static let shortReportID: UInt8 = 0x10
    public static let longReportID: UInt8 = 0x11
    public static let shortReportLength: Int = 7
    public static let longReportLength: Int = 20

    /// Software identifier nibble (1...15) used by Aeron Tools to tag requests and match replies.
    public static let softwareID: UInt8 = 0x0A

    // HID++ 2.0 Feature IDs
    public static let featureRoot: UInt16 = 0x0000
    public static let featureFeatureSet: UInt16 = 0x0001
    public static let featureDeviceName: UInt16 = 0x0005
    public static let featureBatteryStatus: UInt16 = 0x1000
    public static let featureUnifiedBattery: UInt16 = 0x1004
    public static let featureReprogControlsV4: UInt16 = 0x1B04
    public static let featureSmartShift: UInt16 = 0x2110
    public static let featureSmartShiftEnhanced: UInt16 = 0x2111
    public static let featureThumbwheel: UInt16 = 0x2150
    public static let featureAdjustableDPI: UInt16 = 0x2201

    // Common MX Master Control IDs (CIDs) for feature 0x1B04
    public static let cidMiddleButton: UInt16 = 0x0052
    public static let cidBackButton: UInt16 = 0x0053
    public static let cidForwardButton: UInt16 = 0x0056
    public static let cidGestureThumbButton: UInt16 = 0x00C3
    public static let cidModeShiftButton: UInt16 = 0x00C4
    /// MX Master 4 haptic sense panel under the thumb (Actions Ring button in Logi Options+).
    public static let cidHapticPanelButton: UInt16 = 0x01A0

    // MARK: Packet Builders

    /// Builds a 20-byte HID++ 2.0 long request packet.
    public static func makeLongPacket(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        functionID: UInt8,
        swID: UInt8 = softwareID,
        params: [UInt8] = []
    ) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: longReportLength)
        packet[0] = longReportID
        packet[1] = deviceIndex
        packet[2] = featureIndex
        packet[3] = ((functionID & 0x0F) << 4) | (swID & 0x0F)
        for (i, byte) in params.prefix(longReportLength - 4).enumerated() {
            packet[4 + i] = byte
        }
        return packet
    }

    /// Builds a 7-byte HID++ 2.0 short request packet.
    public static func makeShortPacket(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        functionID: UInt8,
        swID: UInt8 = softwareID,
        params: [UInt8] = []
    ) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: shortReportLength)
        packet[0] = shortReportID
        packet[1] = deviceIndex
        packet[2] = featureIndex
        packet[3] = ((functionID & 0x0F) << 4) | (swID & 0x0F)
        for (i, byte) in params.prefix(shortReportLength - 4).enumerated() {
            packet[4 + i] = byte
        }
        return packet
    }

    /// Builds an `IRoot.getFeature(featureID)` request to look up a feature's runtime index table slot.
    public static func getFeatureIndexPacket(deviceIndex: UInt8, featureID: UInt16) -> [UInt8] {
        makeLongPacket(
            deviceIndex: deviceIndex,
            featureIndex: 0x00,
            functionID: 0x00,
            params: [UInt8(featureID >> 8), UInt8(featureID & 0xFF)]
        )
    }

    /// Builds a `UnifiedBattery.getStatus` (`0x1004`, function `0x01`) request.
    public static func getUnifiedBatteryStatusPacket(deviceIndex: UInt8, featureIndex: UInt8) -> [UInt8] {
        makeLongPacket(deviceIndex: deviceIndex, featureIndex: featureIndex, functionID: 0x01)
    }

    /// Builds a legacy `BatteryStatus.getBatteryLevelStatus` (`0x1000`, function `0x00`) request.
    public static func getLegacyBatteryStatusPacket(deviceIndex: UInt8, featureIndex: UInt8) -> [UInt8] {
        makeLongPacket(deviceIndex: deviceIndex, featureIndex: featureIndex, functionID: 0x00)
    }

    /// Builds an `AdjustableDPI.getSensorDPI` (`0x2201`, function `0x02`) request for sensor 0.
    public static func getSensorDPIPacket(deviceIndex: UInt8, featureIndex: UInt8, sensorIndex: UInt8 = 0) -> [UInt8] {
        makeLongPacket(deviceIndex: deviceIndex, featureIndex: featureIndex, functionID: 0x02, params: [sensorIndex])
    }

    /// Builds an `AdjustableDPI.setSensorDPI` (`0x2201`, function `0x03`) request for sensor 0.
    public static func setSensorDPIPacket(deviceIndex: UInt8, featureIndex: UInt8, dpi: Int, sensorIndex: UInt8 = 0) -> [UInt8] {
        let clamped = UInt16(MXMasterConfig.clampedDPI(dpi))
        return makeLongPacket(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionID: 0x03,
            params: [sensorIndex, UInt8(clamped >> 8), UInt8(clamped & 0xFF)]
        )
    }

    /// Builds a `SmartShift.getRatchetControlMode` request.
    /// `0x2110` uses function `0x00`; `0x2111` (Enhanced) uses function `0x01` because `0x00` is `getCapabilities`.
    public static func getSmartShiftPacket(deviceIndex: UInt8, featureIndex: UInt8, isEnhanced: Bool) -> [UInt8] {
        makeLongPacket(deviceIndex: deviceIndex, featureIndex: featureIndex, functionID: isEnhanced ? 0x01 : 0x00)
    }

    /// Builds a `SmartShift.setRatchetControlMode` request (`0x2110` function `0x01`, `0x2111` function `0x02`).
    /// - Parameters:
    ///   - wheelMode: `.ratchet` (`0x02`) or `.freeSpin` (`0x01`)
    ///   - smartShiftEnabled: Whether auto-disengage is active when in ratchet mode
    ///   - threshold: Sensitivity threshold `1...50`
    public static func setSmartShiftPacket(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        isEnhanced: Bool,
        wheelMode: MXWheelMode,
        smartShiftEnabled: Bool,
        threshold: Int
    ) -> [UInt8] {
        let clampedThreshold = UInt8(MXMasterConfig.clampedSmartShiftThreshold(threshold))
        // byte 0 = wheelMode (0 = unchanged, 1 = FreeSpin, 2 = Ratchet)
        // byte 1 = autoDisengage (0 = unchanged, 1...254 = SmartShift threshold, 0xFF = never disengage)
        // byte 2 = 0x2110: autoDisengageDefault / 0x2111: tunable torque (0 = unchanged for both)
        let autoDisengage: UInt8
        if wheelMode == .ratchet {
            autoDisengage = smartShiftEnabled ? clampedThreshold : 0xFF
        } else {
            autoDisengage = 0x00
        }
        return makeLongPacket(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionID: isEnhanced ? 0x02 : 0x01,
            params: [wheelMode.hidppValue, autoDisengage, 0x00]
        )
    }

    /// Builds a `ReprogControlsV4.setCidReporting` (`0x1B04`, function `0x03`) packet to divert or undivert a control ID.
    public static func setControlDivertedPacket(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        controlID: UInt16,
        diverted: Bool
    ) -> [UInt8] {
        // Flags byte: bit 0 = divert (1) / undivert (0), bit 1 = dvalid (1 = update divert bit)
        let flags: UInt8 = diverted ? 0x03 : 0x02
        return makeLongPacket(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionID: 0x03,
            params: [UInt8(controlID >> 8), UInt8(controlID & 0xFF), flags]
        )
    }

    // MARK: Packet Parsers

    /// Normalizes an incoming HID report (which may or may not have a leading report ID byte on BLE).
    public static func normalizeReport(_ bytes: [UInt8]) -> [UInt8]? {
        guard !bytes.isEmpty else { return nil }
        if bytes[0] == shortReportID || bytes[0] == longReportID {
            return bytes.count >= 7 ? bytes : nil
        }
        // Some BLE HID++ GATT characteristics omit the leading 0x11 report ID byte (19 bytes payload).
        if bytes.count == 19 {
            return [longReportID] + bytes
        }
        if bytes.count == 6 {
            return [shortReportID] + bytes
        }
        return nil
    }

    /// Returns true if the packet is a HID++ 1.0 (`0x8F`) or 2.0 (`0xFF`) error response.
    public static func isErrorResponse(_ report: [UInt8]) -> Bool {
        guard let norm = normalizeReport(report) else { return true }
        return norm[2] == 0xFF || norm[2] == 0x8F
    }

    /// Parses the reply to `IRoot.getFeature(featureID)` (`0x0000`, function `0x00`) and returns the feature table index.
    public static func parseFeatureIndexReply(_ report: [UInt8]) -> UInt8? {
        guard let norm = normalizeReport(report),
              !isErrorResponse(norm),
              norm[2] == 0x00,
              (norm[3] >> 4) == 0x00,
              norm.count >= 5 else { return nil }
        let index = norm[4]
        return index == 0 ? nil : index
    }

    public struct BatteryReading: Sendable, Equatable {
        public let percentage: Int
        public let isCharging: Bool
    }

    /// Parses a `UnifiedBattery` (`0x1004`) or `BatteryStatus` (`0x1000`) reply or event packet.
    public static func parseBatteryReply(_ report: [UInt8], expectedFeatureIndex: UInt8, isUnifiedBattery: Bool) -> BatteryReading? {
        guard let norm = normalizeReport(report),
              !isErrorResponse(norm),
              norm[2] == expectedFeatureIndex,
              norm.count >= 7 else { return nil }

        let percentage = Int(norm[4])
        guard (1...100).contains(percentage) else { return nil }

        if isUnifiedBattery {
            // UnifiedBattery (0x1004): norm[4] = stateOfCharge (%), norm[5] = levelFlags, norm[6] = chargingStatus
            // chargingStatus: 0 = discharging, 1 = recharging, 2 = charge in final stage, 3 = charge complete, 4 = recharging below optimal
            let chargingStatus = norm[6]
            let isCharging = (1...4).contains(chargingStatus)
            return BatteryReading(percentage: percentage, isCharging: isCharging)
        } else {
            // BatteryStatus (0x1000): norm[4] = dischargeLevel (%), norm[5] = nextLevel, norm[6] = status
            // status: 0 = discharging, 1..4 = recharging / full
            let status = norm[6]
            let isCharging = (1...4).contains(status)
            return BatteryReading(percentage: percentage, isCharging: isCharging)
        }
    }

    /// Parses an `AdjustableDPI.getSensorDPI` (`0x2201`, function `0x02`) reply.
    public static func parseSensorDPIReply(_ report: [UInt8], expectedFeatureIndex: UInt8) -> Int? {
        guard let norm = normalizeReport(report),
              !isErrorResponse(norm),
              norm[2] == expectedFeatureIndex,
              norm.count >= 7 else { return nil }
        let dpi = (Int(norm[5]) << 8) | Int(norm[6])
        return (100...16000).contains(dpi) ? dpi : nil
    }

    public struct SmartShiftReading: Sendable, Equatable {
        public let wheelMode: MXWheelMode
        public let smartShiftEnabled: Bool
        public let threshold: Int
    }

    /// Parses a `SmartShift` (`0x2110` / `0x2111`) reply.
    public static func parseSmartShiftReply(_ report: [UInt8], expectedFeatureIndex: UInt8) -> SmartShiftReading? {
        guard let norm = normalizeReport(report),
              !isErrorResponse(norm),
              norm[2] == expectedFeatureIndex,
              norm.count >= 6,
              let mode = MXWheelMode(hidppValue: norm[4]) else { return nil }

        let autoDisengage = Int(norm[5])
        let enabled = (1...254).contains(autoDisengage)
        let threshold = enabled ? MXMasterConfig.clampedSmartShiftThreshold(autoDisengage) : 25
        return SmartShiftReading(wheelMode: mode, smartShiftEnabled: enabled, threshold: threshold)
    }

    /// Parses a diverted button notification from `ReprogControlsV4` (`0x1B04`, event `0x00`), returning the pressed Control IDs (up to 4 simultaneous CIDs).
    public static func parseDivertedButtonsEvent(_ report: [UInt8], expectedFeatureIndex: UInt8) -> [UInt16]? {
        guard let norm = normalizeReport(report),
              !isErrorResponse(norm),
              norm[2] == expectedFeatureIndex,
              (norm[3] >> 4) == 0x00,
              norm.count >= 12 else { return nil }

        var cids: [UInt16] = []
        for slot in 0..<4 {
            let hi = UInt16(norm[4 + slot * 2])
            let lo = UInt16(norm[5 + slot * 2])
            let cid = (hi << 8) | lo
            if cid != 0 {
                cids.append(cid)
            }
        }
        return cids
    }
}

// MARK: - MXMasterManager

@Observable
@MainActor
public final class MXMasterManager {
    public static let shared = MXMasterManager()

    private static let configDefaultsKey = "mxMasterConfig"
    private static let cardOptionsDefaultsKey = "mxMasterCardOptions"

    public var config: MXMasterConfig {
        didSet {
            saveConfig()
            handleConfigDidChange(from: oldValue, to: config)
        }
    }

    public var cardOptions: MXMasterCardOptions {
        didSet {
            if let data = try? JSONEncoder().encode(cardOptions) {
                UserDefaults.standard.set(data, forKey: Self.cardOptionsDefaultsKey)
            }
            if cardOptions.lowBatteryAlertEnabled && !oldValue.lowBatteryAlertEnabled {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
            if cardOptions.lowBatteryThreshold != oldValue.lowBatteryThreshold {
                hasSentLowBatteryAlert = false
            }
            updateBatteryAlertTimer()
            evaluateLowBatteryAlert()
        }
    }

    public private(set) var snapshot: MXMasterSnapshot = MXMasterSnapshot(
        deviceName: "MX Master 4",
        productID: 0,
        transport: .disconnected,
        batteryPercent: nil,
        isCharging: false,
        hidppConnected: false,
        minDPI: 200,
        maxDPI: 8000,
        dpiStep: 50,
        reportedDPI: nil,
        reportedWheelMode: nil,
        reportedSmartShiftEnabled: nil,
        reportedSmartShiftThreshold: nil
    ) {
        didSet {
            updateBatteryAlertTimer()
            evaluateLowBatteryAlert()
        }
    }

    public private(set) var isConnected: Bool = false
    /// Input Monitoring (TCC ListenEvent) is required to open the mouse's HID++ channel.
    public private(set) var hasInputMonitoringAccess: Bool = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    public private(set) var isMonitoring: Bool = false
    public private(set) var lastStatusMessage: String = "Searching for Logitech MX Master…"

    // MARK: Private State

    @ObservationIgnored private var hidManager: IOHIDManager?
    @ObservationIgnored private var activeHIDDevice: IOHIDDevice?
    @ObservationIgnored private var activeDeviceIndex: UInt8 = 0xFF
    @ObservationIgnored private var featureTable: [UInt16: UInt8] = [:]
    @ObservationIgnored private var pressedDivertedCIDs: Set<UInt16> = []
    @ObservationIgnored private var inputMonitoringTimer: Timer?

    @ObservationIgnored private var eventTap: CFMachPort?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    /// Pointer-motion tap, enabled only while the gesture button is held so ordinary mouse movement never
    /// round-trips through the main thread.
    @ObservationIgnored private var gestureTap: CFMachPort?
    @ObservationIgnored private var gestureRunLoopSource: CFRunLoopSource?
    @ObservationIgnored private var telemetryTimer: Timer?
    @ObservationIgnored private var dpiDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var smartShiftDebounceTask: Task<Void, Never>?

    // Gesture & Smooth Scroll State
    @ObservationIgnored private var isGestureButtonHeld = false
    @ObservationIgnored private var gestureTriggeredDuringHold = false
    @ObservationIgnored private var gestureAccumulatedDelta: CGPoint = .zero
    @ObservationIgnored private let gestureDragThreshold: CGFloat = 36.0
    @ObservationIgnored private var lastSpaceOrTabSwitchTime: CFAbsoluteTime = 0
    @ObservationIgnored private var smoothScrollVelocityY: Double = 0
    @ObservationIgnored private var smoothScrollVelocityX: Double = 0
    @ObservationIgnored private var smoothScrollTimer: Timer?

    // Low-Battery Alert State
    @ObservationIgnored private var batteryAlertTimer: Timer?
    @ObservationIgnored private var hasSentLowBatteryAlert = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.configDefaultsKey),
           let decoded = try? JSONDecoder().decode(MXMasterConfig.self, from: data) {
            self.config = decoded
        } else {
            self.config = MXMasterConfig()
        }
        if let data = UserDefaults.standard.data(forKey: Self.cardOptionsDefaultsKey),
           let decoded = try? JSONDecoder().decode(MXMasterCardOptions.self, from: data) {
            self.cardOptions = decoded
        } else {
            self.cardOptions = MXMasterCardOptions()
        }
        AccessibilityPermission.shared.onChange { [weak self] in
            guard let self else { return }
            // A revoked permission leaves dead taps behind, so tear them down before re-evaluating.
            if !AccessibilityPermission.shared.isGranted { self.stopEventTap() }
            self.updateEventTapState()
        }
        // Bluetooth LE mice report battery through macOS power sources instead of HID++ events.
        PowerSource.onChange { [weak self] in
            guard let self, self.isConnected, !self.snapshot.hidppConnected else { return }
            self.refreshDeviceState()
        }
    }

    // MARK: - Lifecycle

    public func start() {
        setupHIDManager()
        refreshDeviceState()
        updateEventTapState()
        updateBatteryAlertTimer()
    }

    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        refreshDeviceState()

        telemetryTimer?.invalidate()
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isMonitoring else { return }
                self.refreshDeviceState()
            }
        }
    }

    public func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        telemetryTimer?.invalidate()
        telemetryTimer = nil
    }

    // MARK: - Persistence & Change Handling

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.configDefaultsKey)
        }
    }

    private func handleConfigDidChange(from oldValue: MXMasterConfig, to newValue: MXMasterConfig) {
        if oldValue.dpi != newValue.dpi {
            dpiDebounceTask?.cancel()
            let targetDPI = newValue.dpi
            dpiDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                self?.sendDPIToHardware(targetDPI)
            }
        }

        if oldValue.wheelMode != newValue.wheelMode
            || oldValue.smartShiftEnabled != newValue.smartShiftEnabled
            || oldValue.smartShiftThreshold != newValue.smartShiftThreshold {
            smartShiftDebounceTask?.cancel()
            smartShiftDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.sendSmartShiftToHardware(
                    wheelMode: self.config.wheelMode,
                    smartShiftEnabled: self.config.smartShiftEnabled,
                    threshold: self.config.smartShiftThreshold
                )
            }
        }

        if oldValue.gesturesEnabled != newValue.gesturesEnabled
            || oldValue.gestureButtonClickAction != newValue.gestureButtonClickAction
            || oldValue.modeShiftButtonAction != newValue.modeShiftButtonAction
            || oldValue.hapticPanelButtonAction != newValue.hapticPanelButtonAction {
            configureDivertedButtonsIfNeeded()
        }

        updateEventTapState()
    }

    /// Immediately pushes the current DPI, SmartShift, and button diversion configuration to the mouse.
    public func applyAllSettingsToHardware() {
        sendDPIToHardware(config.dpi)
        sendSmartShiftToHardware(
            wheelMode: config.wheelMode,
            smartShiftEnabled: config.smartShiftEnabled,
            threshold: config.smartShiftThreshold
        )
        configureDivertedButtonsIfNeeded()
        requestBatteryFromHIDPP()
    }

    /// Toggles between Ratchet and Free-Spin wheel modes.
    public func toggleWheelMode() {
        config.wheelMode = (config.wheelMode == .ratchet) ? .freeSpin : .ratchet
    }

    // MARK: - Low-Battery Alert

    /// HID++ mice send their own battery events and power-source changes are observed, so only a mouse that
    /// is visible solely through the IORegistry, which posts no change notifications, is still polled.
    private func updateBatteryAlertTimer() {
        guard cardOptions.lowBatteryAlertEnabled, isConnected, !snapshot.hidppConnected else {
            batteryAlertTimer?.invalidate()
            batteryAlertTimer = nil
            return
        }
        guard batteryAlertTimer == nil else { return }
        batteryAlertTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isMonitoring else { return }
                self.refreshDeviceState()
            }
        }
    }

    /// Posts one notification per discharge cycle once the battery reaches the configured threshold.
    private func evaluateLowBatteryAlert() {
        guard let battery = snapshot.batteryPercent else { return }
        if snapshot.isCharging || battery > cardOptions.lowBatteryThreshold {
            hasSentLowBatteryAlert = false
            return
        }
        guard cardOptions.lowBatteryAlertEnabled, !hasSentLowBatteryAlert else { return }
        hasSentLowBatteryAlert = true

        let content = UNMutableNotificationContent()
        content.title = "\(snapshot.deviceName) Battery Low"
        content.body = "Battery is at \(battery)%. Connect the USB-C cable to charge."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "mxMasterLowBattery", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - IOHIDManager & Hardware Discovery

    private func setupHIDManager() {
        guard hidManager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matchDict: [String: Any] = [
            kIOHIDVendorIDKey as String: HIDPPProtocol.logitechVendorID
        ]
        IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let mgr = Unmanaged<MXMasterManager>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                mgr.refreshDeviceState()
            }
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let mgr = Unmanaged<MXMasterManager>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                mgr.refreshDeviceState()
            }
        }, context)

        // Registered on the manager (not per device) so IOKit owns the report buffer; replies are filtered by sender.
        IOHIDManagerRegisterInputReportCallback(manager, { context, _, sender, _, reportID, report, reportLength in
            guard let context, let sender, reportLength > 0,
                  reportID == HIDPPProtocol.shortReportID || reportID == HIDPPProtocol.longReportID else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            let mgr = Unmanaged<MXMasterManager>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                guard mgr.activeHIDDevice === device else { return }
                mgr.handleIncomingHIDReport(reportID: UInt8(reportID & 0xFF), bytes: bytes)
            }
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        self.hidManager = manager

        hasInputMonitoringAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if hasInputMonitoringAccess {
            openHIDManager()
        } else {
            requestInputMonitoringAccess()
        }
    }

    /// Only called once Input Monitoring is granted: opening without access implicitly triggers the TCC prompt,
    /// which blocks the calling thread — and with our event taps on the main run loop that freezes all system input.
    private func openHIDManager() {
        guard let hidManager else { return }
        let openResult = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult != kIOReturnSuccess {
            dlog(String(format: "MX Master: IOHIDManagerOpen returned 0x%08x", openResult))
        }
    }

    /// Shows the Input Monitoring prompt off the main thread (`IOHIDRequestAccess` blocks until the user answers),
    /// then polls so access granted later in System Settings is picked up without relaunching.
    private func requestInputMonitoringAccess() {
        Task.detached(priority: .utility) {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        guard inputMonitoringTimer == nil else { return }
        inputMonitoringTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return }
                self.inputMonitoringTimer?.invalidate()
                self.inputMonitoringTimer = nil
                self.hasInputMonitoringAccess = true
                self.openHIDManager()
                // Force a fresh open + feature probe now that access is granted
                self.activeHIDDevice = nil
                self.refreshDeviceState()
            }
        }
    }

    /// Opens System Settings → Privacy & Security → Input Monitoring.
    public func openInputMonitoringSettings() {
        if !hasInputMonitoringAccess {
            requestInputMonitoringAccess()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Scans IOHIDManager, IORegistry, and IOPowerSources to detect the MX Master mouse and query its telemetry.
    public func refreshDeviceState() {
        let registryBattery = Self.readSystemBatteryForLogitechMouse()
        let candidate = findBestLogitechHIDDevice()

        if let candidate {
            let wasDisconnected = !isConnected || activeHIDDevice !== candidate.device
            activeHIDDevice = candidate.device
            activeDeviceIndex = candidate.deviceIndex
            isConnected = true

            if wasDisconnected {
                featureTable.removeAll()
                pressedDivertedCIDs.removeAll()
                releaseGestureHoldIfNeeded()
                // Skip opening without access: the open would trigger a blocking TCC prompt on the main thread.
                if hasInputMonitoringAccess {
                    let openResult = IOHIDDeviceOpen(candidate.device, IOOptionBits(kIOHIDOptionsTypeNone))
                    if openResult != kIOReturnSuccess {
                        dlog(String(format: "MX Master: IOHIDDeviceOpen returned 0x%08x", openResult))
                    }
                    probeHIDPPFeatures()
                }
            } else {
                requestBatteryFromHIDPP()
                requestDPIFromHIDPP()
                requestSmartShiftFromHIDPP()
            }

            let resolvedName = candidate.name.isEmpty ? "MX Master 4" : candidate.name
            let mergedBattery = snapshot.batteryPercent ?? registryBattery?.percentage
            let mergedCharging = registryBattery?.isCharging ?? snapshot.isCharging

            snapshot = MXMasterSnapshot(
                deviceName: resolvedName,
                productID: candidate.productID,
                transport: candidate.transport,
                batteryPercent: mergedBattery,
                isCharging: mergedCharging,
                hidppConnected: !featureTable.isEmpty,
                minDPI: 200,
                maxDPI: 8000,
                dpiStep: 50,
                reportedDPI: snapshot.reportedDPI ?? config.dpi,
                reportedWheelMode: snapshot.reportedWheelMode ?? config.wheelMode,
                reportedSmartShiftEnabled: snapshot.reportedSmartShiftEnabled ?? config.smartShiftEnabled,
                reportedSmartShiftThreshold: snapshot.reportedSmartShiftThreshold ?? config.smartShiftThreshold
            )
            if !hasInputMonitoringAccess {
                lastStatusMessage = "Input Monitoring permission needed to talk to the mouse"
            } else if featureTable.isEmpty {
                lastStatusMessage = "Connected via \(candidate.transport.rawValue) — waiting for HID++ reply…"
            } else {
                lastStatusMessage = "Connected via \(candidate.transport.rawValue)"
            }
        } else if let registryBattery {
            // Connected via Bluetooth LE where macOS HID event driver owns the device
            isConnected = true
            activeHIDDevice = nil
            snapshot = MXMasterSnapshot(
                deviceName: registryBattery.deviceName,
                productID: registryBattery.productID,
                transport: .bluetoothLE,
                batteryPercent: registryBattery.percentage,
                isCharging: registryBattery.isCharging,
                hidppConnected: false,
                minDPI: 200,
                maxDPI: 8000,
                dpiStep: 50,
                reportedDPI: config.dpi,
                reportedWheelMode: config.wheelMode,
                reportedSmartShiftEnabled: config.smartShiftEnabled,
                reportedSmartShiftThreshold: config.smartShiftThreshold
            )
            lastStatusMessage = "Connected via Bluetooth LE"
        } else {
            isConnected = false
            activeHIDDevice = nil
            featureTable.removeAll()
            snapshot = MXMasterSnapshot(
                deviceName: "MX Master 4",
                productID: 0,
                transport: .disconnected,
                batteryPercent: nil,
                isCharging: false,
                hidppConnected: false,
                minDPI: 200,
                maxDPI: 8000,
                dpiStep: 50,
                reportedDPI: nil,
                reportedWheelMode: nil,
                reportedSmartShiftEnabled: nil,
                reportedSmartShiftThreshold: nil
            )
            lastStatusMessage = "No MX Master detected (connect via Bluetooth or Logi Bolt)"
        }
    }

    private struct HIDCandidate {
        let device: IOHIDDevice
        let name: String
        let productID: Int
        let transport: MXConnectionTransport
        let deviceIndex: UInt8
        let score: Int
    }

    private func findBestLogitechHIDDevice() -> HIDCandidate? {
        guard let manager = hidManager,
              let devSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            return nil
        }

        var best: HIDCandidate?
        for device in devSet {
            let vendorID = Self.intProperty(kIOHIDVendorIDKey, of: device) ?? 0
            guard vendorID == HIDPPProtocol.logitechVendorID else { continue }

            let productID = Self.intProperty(kIOHIDProductIDKey, of: device) ?? 0
            let rawName = Self.stringProperty(kIOHIDProductKey, of: device) ?? ""
            let transportStr = (Self.stringProperty(kIOHIDTransportKey, of: device) ?? "").lowercased()
            let usagePage = Self.intProperty(kIOHIDPrimaryUsagePageKey, of: device) ?? 0
            let usage = Self.intProperty(kIOHIDPrimaryUsageKey, of: device) ?? 0

            // Exclude pure keyboards that aren't receivers or MX Master mice
            let lowerName = rawName.lowercased()
            if lowerName.contains("keyboard") || lowerName.contains("mx keys") {
                continue
            }

            let transport: MXConnectionTransport
            let deviceIndex: UInt8
            var score = 10

            if productID == HIDPPProtocol.boltReceiverProductID {
                transport = .logiBolt
                deviceIndex = 0x01 // First paired slot on Logi Bolt receiver
                score += 40
            } else if productID == HIDPPProtocol.unifyingReceiverProductID {
                transport = .unifying
                deviceIndex = 0x01
                score += 35
            } else if transportStr.contains("bluetooth") || transportStr.contains("ble") {
                transport = .bluetoothLE
                deviceIndex = 0xFF
                score += 50
            } else {
                transport = .usbWired
                deviceIndex = 0xFF
                score += 30
            }

            if lowerName.contains("mx master 4") {
                score += 100
            } else if lowerName.contains("mx master") {
                score += 80
            }

            // Prefer vendor-defined HID++ collection (0xFF00 or 0xFF43) for bidirectional feature reports
            if usagePage >= 0xFF00 {
                score += 60
            } else if usagePage == 0x01 && (usage == 0x02 || usage == 0x01) {
                score += 20
            }

            let displayName: String
            if lowerName.contains("mx master") {
                displayName = rawName
            } else if transport == .logiBolt || transport == .unifying {
                displayName = "MX Master 4"
            } else {
                displayName = rawName.isEmpty ? "MX Master 4" : rawName
            }

            let candidate = HIDCandidate(
                device: device,
                name: displayName,
                productID: productID,
                transport: transport,
                deviceIndex: deviceIndex,
                score: score
            )

            if best == nil || candidate.score > best!.score {
                best = candidate
            }
        }
        return best
    }

    private nonisolated static func intProperty(_ key: String, of device: IOHIDDevice) -> Int? {
        IOHIDDeviceGetProperty(device, key as CFString) as? Int
    }

    private nonisolated static func stringProperty(_ key: String, of device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    // MARK: - System Battery Fallback (IOPowerSources & IORegistry)

    private struct SystemMouseBattery {
        let deviceName: String
        let productID: Int
        let percentage: Int
        let isCharging: Bool
    }

    /// Reads Bluetooth LE / HID battery telemetry published to macOS IOPowerSources or IORegistry.
    private nonisolated static func readSystemBatteryForLogitechMouse() -> SystemMouseBattery? {
        // 1. Check IOPSCopyPowerSourcesInfo for accessory batteries (Bluetooth mice/trackpads)
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else {
                    continue
                }
                let name = (desc[kIOPSNameKey as String] as? String) ?? ""
                let lower = name.lowercased()
                let transport = ((desc[kIOPSTransportTypeKey as String] as? String) ?? "").lowercased()
                guard lower.contains("mx master") || lower.contains("logi") || (transport.contains("bluetooth") && lower.contains("mouse")) else {
                    continue
                }
                if let capacity = desc[kIOPSCurrentCapacityKey as String] as? Int, (1...100).contains(capacity) {
                    let isCharging = (desc[kIOPSIsChargingKey as String] as? Bool) ?? false
                    let displayName = lower.contains("mx master") ? name : "MX Master 4"
                    return SystemMouseBattery(deviceName: displayName, productID: 0, percentage: capacity, isCharging: isCharging)
                }
            }
        }

        // 2. Check IORegistry for IOHIDDevice / AppleDeviceManagementHIDEventService nodes with VendorID 0x046D and BatteryPercent
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else {
                continue
            }
            let vendor = dict["VendorID"] as? Int ?? 0
            let product = dict["Product"] as? String ?? ""
            let lower = product.lowercased()
            guard vendor == HIDPPProtocol.logitechVendorID || lower.contains("mx master") else {
                continue
            }
            if lower.contains("keyboard") || lower.contains("mx keys") {
                continue
            }
            if let percent = dict["BatteryPercent"] as? Int, (1...100).contains(percent) {
                let productID = dict["ProductID"] as? Int ?? 0
                let displayName = lower.contains("mx master") ? product : "MX Master 4"
                return SystemMouseBattery(deviceName: displayName, productID: productID, percentage: percent, isCharging: false)
            }
        }

        return nil
    }

    // MARK: - HID++ 2.0 Transport & Feature Negotiation

    private func sendHIDPPPacket(_ packet: [UInt8]) {
        guard let device = activeHIDDevice, !packet.isEmpty else { return }
        let reportID = CFIndex(packet[0])
        packet.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, reportID, base, buf.count)
            if result != kIOReturnSuccess {
                dlog(String(format: "MX Master: HID++ SetReport failed 0x%08x", result))
            }
        }
    }

    /// Resolves feature indices for UnifiedBattery, AdjustableDPI, SmartShift, and ReprogControlsV4.
    private func probeHIDPPFeatures() {
        let featuresToProbe: [UInt16] = [
            HIDPPProtocol.featureUnifiedBattery,
            HIDPPProtocol.featureBatteryStatus,
            HIDPPProtocol.featureAdjustableDPI,
            HIDPPProtocol.featureSmartShiftEnhanced,
            HIDPPProtocol.featureSmartShift,
            HIDPPProtocol.featureReprogControlsV4
        ]
        for (idx, featureID) in featuresToProbe.enumerated() {
            // Encode the feature lookup slot in the softwareID nibble (1...6) so replies map back unambiguously.
            let swID = UInt8(idx + 1)
            let packet = HIDPPProtocol.makeLongPacket(
                deviceIndex: activeDeviceIndex,
                featureIndex: 0x00,
                functionID: 0x00,
                swID: swID,
                params: [UInt8(featureID >> 8), UInt8(featureID & 0xFF)]
            )
            sendHIDPPPacket(packet)
        }
    }

    private func handleIncomingHIDReport(reportID: UInt8, bytes: [UInt8]) {
        var raw = bytes
        if !raw.isEmpty && raw[0] != reportID && (reportID == HIDPPProtocol.shortReportID || reportID == HIDPPProtocol.longReportID) {
            raw.insert(reportID, at: 0)
        }
        guard let norm = HIDPPProtocol.normalizeReport(raw), !HIDPPProtocol.isErrorResponse(norm) else {
            return
        }

        let featureIndex = norm[2]
        let swID = norm[3] & 0x0F

        // 1. Check if this is an IRoot (0x0000) feature lookup response
        if featureIndex == 0x00, let resolvedIndex = HIDPPProtocol.parseFeatureIndexReply(norm) {
            let probedFeatures: [UInt16] = [
                HIDPPProtocol.featureUnifiedBattery,
                HIDPPProtocol.featureBatteryStatus,
                HIDPPProtocol.featureAdjustableDPI,
                HIDPPProtocol.featureSmartShiftEnhanced,
                HIDPPProtocol.featureSmartShift,
                HIDPPProtocol.featureReprogControlsV4
            ]
            let slot = Int(swID) - 1
            if probedFeatures.indices.contains(slot) {
                let featureID = probedFeatures[slot]
                featureTable[featureID] = resolvedIndex
                onFeatureResolved(featureID: featureID, index: resolvedIndex)
            }
            return
        }

        // 2. UnifiedBattery (0x1004) or BatteryStatus (0x1000)
        if let unifiedIdx = featureTable[HIDPPProtocol.featureUnifiedBattery], featureIndex == unifiedIdx,
           let reading = HIDPPProtocol.parseBatteryReply(norm, expectedFeatureIndex: unifiedIdx, isUnifiedBattery: true) {
            updateSnapshotBattery(reading)
            return
        }
        if let legacyIdx = featureTable[HIDPPProtocol.featureBatteryStatus], featureIndex == legacyIdx,
           let reading = HIDPPProtocol.parseBatteryReply(norm, expectedFeatureIndex: legacyIdx, isUnifiedBattery: false) {
            updateSnapshotBattery(reading)
            return
        }

        // 3. AdjustableDPI (0x2201)
        if let dpiIdx = featureTable[HIDPPProtocol.featureAdjustableDPI], featureIndex == dpiIdx,
           let reportedDPI = HIDPPProtocol.parseSensorDPIReply(norm, expectedFeatureIndex: dpiIdx) {
            snapshot = MXMasterSnapshot(
                deviceName: snapshot.deviceName,
                productID: snapshot.productID,
                transport: snapshot.transport,
                batteryPercent: snapshot.batteryPercent,
                isCharging: snapshot.isCharging,
                hidppConnected: true,
                minDPI: snapshot.minDPI,
                maxDPI: snapshot.maxDPI,
                dpiStep: snapshot.dpiStep,
                reportedDPI: reportedDPI,
                reportedWheelMode: snapshot.reportedWheelMode,
                reportedSmartShiftEnabled: snapshot.reportedSmartShiftEnabled,
                reportedSmartShiftThreshold: snapshot.reportedSmartShiftThreshold
            )
            return
        }

        // 4. SmartShift (0x2111 or 0x2110)
        if let feature = smartShiftFeature, featureIndex == feature.index {
            // Only getRatchetControlMode replies carry the mode; ignore set acknowledgements and capabilities.
            let functionID = norm[3] >> 4
            guard functionID == (feature.isEnhanced ? 0x01 : 0x00) else { return }
        }
        if let feature = smartShiftFeature, featureIndex == feature.index,
           let reading = HIDPPProtocol.parseSmartShiftReply(norm, expectedFeatureIndex: feature.index) {
            snapshot = MXMasterSnapshot(
                deviceName: snapshot.deviceName,
                productID: snapshot.productID,
                transport: snapshot.transport,
                batteryPercent: snapshot.batteryPercent,
                isCharging: snapshot.isCharging,
                hidppConnected: true,
                minDPI: snapshot.minDPI,
                maxDPI: snapshot.maxDPI,
                dpiStep: snapshot.dpiStep,
                reportedDPI: snapshot.reportedDPI,
                reportedWheelMode: reading.wheelMode,
                reportedSmartShiftEnabled: reading.smartShiftEnabled,
                reportedSmartShiftThreshold: reading.threshold
            )
            return
        }

        // 5. Diverted Gesture/Thumb Button Events (0x1B04)
        if let reprogIdx = featureTable[HIDPPProtocol.featureReprogControlsV4], featureIndex == reprogIdx,
           let pressedCIDs = HIDPPProtocol.parseDivertedButtonsEvent(norm, expectedFeatureIndex: reprogIdx) {
            let pressed = Set(pressedCIDs)
            let previous = pressedDivertedCIDs
            pressedDivertedCIDs = pressed
            for cid in pressed.subtracting(previous) {
                handleDivertedControl(cid, isDown: true)
            }
            for cid in previous.subtracting(pressed) {
                handleDivertedControl(cid, isDown: false)
            }
        }
    }

    private func onFeatureResolved(featureID: UInt16, index: UInt8) {
        switch featureID {
        case HIDPPProtocol.featureUnifiedBattery, HIDPPProtocol.featureBatteryStatus:
            requestBatteryFromHIDPP()
        case HIDPPProtocol.featureAdjustableDPI:
            sendDPIToHardware(config.dpi)
        case HIDPPProtocol.featureSmartShiftEnhanced, HIDPPProtocol.featureSmartShift:
            sendSmartShiftToHardware(
                wheelMode: config.wheelMode,
                smartShiftEnabled: config.smartShiftEnabled,
                threshold: config.smartShiftThreshold
            )
        case HIDPPProtocol.featureReprogControlsV4:
            configureDivertedButtonsIfNeeded()
        default:
            break
        }
    }

    private func updateSnapshotBattery(_ reading: HIDPPProtocol.BatteryReading) {
        snapshot = MXMasterSnapshot(
            deviceName: snapshot.deviceName,
            productID: snapshot.productID,
            transport: snapshot.transport,
            batteryPercent: reading.percentage,
            isCharging: reading.isCharging,
            hidppConnected: true,
            minDPI: snapshot.minDPI,
            maxDPI: snapshot.maxDPI,
            dpiStep: snapshot.dpiStep,
            reportedDPI: snapshot.reportedDPI,
            reportedWheelMode: snapshot.reportedWheelMode,
            reportedSmartShiftEnabled: snapshot.reportedSmartShiftEnabled,
            reportedSmartShiftThreshold: snapshot.reportedSmartShiftThreshold
        )
    }

    private func requestBatteryFromHIDPP() {
        if let idx = featureTable[HIDPPProtocol.featureUnifiedBattery] {
            sendHIDPPPacket(HIDPPProtocol.getUnifiedBatteryStatusPacket(deviceIndex: activeDeviceIndex, featureIndex: idx))
        } else if let idx = featureTable[HIDPPProtocol.featureBatteryStatus] {
            sendHIDPPPacket(HIDPPProtocol.getLegacyBatteryStatusPacket(deviceIndex: activeDeviceIndex, featureIndex: idx))
        }
    }

    private func requestDPIFromHIDPP() {
        if let idx = featureTable[HIDPPProtocol.featureAdjustableDPI] {
            sendHIDPPPacket(HIDPPProtocol.getSensorDPIPacket(deviceIndex: activeDeviceIndex, featureIndex: idx))
        }
    }

    private func sendDPIToHardware(_ dpi: Int) {
        let clamped = MXMasterConfig.clampedDPI(dpi)
        if let idx = featureTable[HIDPPProtocol.featureAdjustableDPI] {
            sendHIDPPPacket(HIDPPProtocol.setSensorDPIPacket(deviceIndex: activeDeviceIndex, featureIndex: idx, dpi: clamped))
        }
        snapshot = MXMasterSnapshot(
            deviceName: snapshot.deviceName,
            productID: snapshot.productID,
            transport: snapshot.transport,
            batteryPercent: snapshot.batteryPercent,
            isCharging: snapshot.isCharging,
            hidppConnected: snapshot.hidppConnected,
            minDPI: snapshot.minDPI,
            maxDPI: snapshot.maxDPI,
            dpiStep: snapshot.dpiStep,
            reportedDPI: clamped,
            reportedWheelMode: snapshot.reportedWheelMode,
            reportedSmartShiftEnabled: snapshot.reportedSmartShiftEnabled,
            reportedSmartShiftThreshold: snapshot.reportedSmartShiftThreshold
        )
    }

    /// Resolved SmartShift feature index, preferring Enhanced (`0x2111`, used by MX Master 3S / 4) over `0x2110`.
    private var smartShiftFeature: (index: UInt8, isEnhanced: Bool)? {
        if let idx = featureTable[HIDPPProtocol.featureSmartShiftEnhanced] { return (idx, true) }
        if let idx = featureTable[HIDPPProtocol.featureSmartShift] { return (idx, false) }
        return nil
    }

    private func requestSmartShiftFromHIDPP() {
        guard let feature = smartShiftFeature else { return }
        sendHIDPPPacket(HIDPPProtocol.getSmartShiftPacket(
            deviceIndex: activeDeviceIndex,
            featureIndex: feature.index,
            isEnhanced: feature.isEnhanced
        ))
    }

    private func sendSmartShiftToHardware(wheelMode: MXWheelMode, smartShiftEnabled: Bool, threshold: Int) {
        if let feature = smartShiftFeature {
            let packet = HIDPPProtocol.setSmartShiftPacket(
                deviceIndex: activeDeviceIndex,
                featureIndex: feature.index,
                isEnhanced: feature.isEnhanced,
                wheelMode: wheelMode,
                smartShiftEnabled: smartShiftEnabled,
                threshold: threshold
            )
            sendHIDPPPacket(packet)
        }
        snapshot = MXMasterSnapshot(
            deviceName: snapshot.deviceName,
            productID: snapshot.productID,
            transport: snapshot.transport,
            batteryPercent: snapshot.batteryPercent,
            isCharging: snapshot.isCharging,
            hidppConnected: snapshot.hidppConnected,
            minDPI: snapshot.minDPI,
            maxDPI: snapshot.maxDPI,
            dpiStep: snapshot.dpiStep,
            reportedDPI: snapshot.reportedDPI,
            reportedWheelMode: wheelMode,
            reportedSmartShiftEnabled: smartShiftEnabled,
            reportedSmartShiftThreshold: threshold
        )
    }

    private func configureDivertedButtonsIfNeeded() {
        guard let idx = featureTable[HIDPPProtocol.featureReprogControlsV4] else { return }
        let diversions: [(UInt16, Bool)] = [
            (HIDPPProtocol.cidGestureThumbButton, config.gesturesEnabled || config.gestureButtonClickAction != .systemDefault),
            (HIDPPProtocol.cidModeShiftButton, config.modeShiftButtonAction != .systemDefault),
            (HIDPPProtocol.cidHapticPanelButton, config.hapticPanelButtonAction != .systemDefault)
        ]
        for (cid, diverted) in diversions {
            sendHIDPPPacket(HIDPPProtocol.setControlDivertedPacket(
                deviceIndex: activeDeviceIndex,
                featureIndex: idx,
                controlID: cid,
                diverted: diverted
            ))
        }
    }

    /// Routes a press/release edge of a HID++-diverted control to its configured action.
    private func handleDivertedControl(_ cid: UInt16, isDown: Bool) {
        switch cid {
        case HIDPPProtocol.cidGestureThumbButton:
            handleDivertedGestureButtonState(isDown: isDown)
        case HIDPPProtocol.cidModeShiftButton:
            if isDown { performButtonAction(config.modeShiftButtonAction) }
        case HIDPPProtocol.cidHapticPanelButton:
            if isDown { performButtonAction(config.hapticPanelButtonAction) }
        default:
            break
        }
    }

    // MARK: - Event Tap (Scrolling, Thumbwheel, Buttons & Hold-Drag Gestures)

    private var needsEventTap: Bool {
        config.standardVerticalScroll
            || config.smoothScrolling
            || config.invertThumbwheel
            || config.thumbwheelAction != .horizontalScroll
            || config.middleButtonAction != .systemDefault
            || config.backButtonAction != .systemDefault
            || config.forwardButtonAction != .systemDefault
            || config.gestureButtonClickAction != .systemDefault
            || config.gesturesEnabled
    }

    private func updateEventTapState() {
        if needsEventTap {
            startEventTapIfNeeded()
        } else {
            stopEventTap()
        }
    }

    private func startEventTapIfNeeded() {
        guard eventTap == nil else { return }
        // Started again from the permission change handler once the user grants access.
        guard AccessibilityPermission.shared.isGranted else { return }

        let mask: CGEventMask =
            (1 << CGEventType.scrollWheel.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mxMasterEventTapCallback,
            userInfo: nil
        ) else {
            dlog("Failed to create MX Master event tap")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.eventTap = tap
        self.runLoopSource = source

        let gestureMask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)
        if let gestureTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: gestureMask,
            callback: mxMasterEventTapCallback,
            userInfo: nil
        ) {
            CGEvent.tapEnable(tap: gestureTap, enable: false)
            let gestureSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gestureTap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), gestureSource, .commonModes)
            self.gestureTap = gestureTap
            self.gestureRunLoopSource = gestureSource
        }
    }

    private func setGestureTapEnabled(_ enabled: Bool) {
        if let gestureTap {
            CGEvent.tapEnable(tap: gestureTap, enable: enabled)
        }
    }

    /// Clears a stuck hold (e.g. the mouse disconnected mid-gesture) so the cursor is never left frozen.
    private func releaseGestureHoldIfNeeded() {
        guard isGestureButtonHeld else { return }
        isGestureButtonHeld = false
        gestureTriggeredDuringHold = false
        gestureAccumulatedDelta = .zero
        setGestureTapEnabled(false)
    }

    private func stopEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let gestureTap {
            CGEvent.tapEnable(tap: gestureTap, enable: false)
        }
        if let gestureRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), gestureRunLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        gestureTap = nil
        gestureRunLoopSource = nil
        isGestureButtonHeld = false
    }

    fileprivate func reenableTapAfterTimeout() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        setGestureTapEnabled(isGestureButtonHeld && config.gesturesEnabled)
    }

    // MARK: - Event Handling Logic

    private static let syntheticEventMarker: Int64 = 0x4D58_4D34 // 'MXM4'

    fileprivate func handleCGEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        // Never re-process synthetic events posted by our own smooth scroller or button synthesizer
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return passThrough
        }

        switch type {
        case .scrollWheel:
            return handleScrollWheelEvent(event)

        case .otherMouseDown, .otherMouseUp:
            let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
            let isDown = (type == .otherMouseDown)
            return handleOtherMouseButton(buttonNumber: Int(buttonNumber), isDown: isDown, event: event)

        case .otherMouseDragged, .mouseMoved:
            if isGestureButtonHeld && config.gesturesEnabled {
                let dx = CGFloat(event.getDoubleValueField(.mouseEventDeltaX))
                let dy = CGFloat(event.getDoubleValueField(.mouseEventDeltaY))
                processGestureDragDelta(dx: dx, dy: dy)
                return nil // Freeze cursor while performing a hold-and-drag gesture
            }
            return passThrough

        default:
            return passThrough
        }
    }

    private func handleScrollWheelEvent(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        // Continuous scroll events come from the built-in Trackpad or Magic Mouse; only transform discrete wheel ticks!
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        guard !isContinuous else { return passThrough }

        var axis1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1) // Vertical wheel
        var axis2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2) // Horizontal thumbwheel

        // 1. Handle Horizontal Thumbwheel
        if axis2 != 0 {
            if config.invertThumbwheel {
                axis2 = -axis2
            }

            switch config.thumbwheelAction {
            case .horizontalScroll:
                event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: axis2)
                let ptX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
                if ptX != 0 && config.invertThumbwheel {
                    event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: -ptX)
                }

            case .displayBrightness:
                let key: MediaKey = axis2 > 0 ? .brightnessUp : .brightnessDown
                if let displayID = NSScreen.underPointer?.displayID {
                    _ = DisplayStateModel.shared.handleMediaKey(key, on: displayID)
                }
                if axis1 == 0 { return nil }

            case .displayVolume:
                let key: MediaKey = axis2 > 0 ? .volumeUp : .volumeDown
                if let displayID = NSScreen.underPointer?.displayID {
                    _ = DisplayStateModel.shared.handleMediaKey(key, on: displayID)
                }
                if axis1 == 0 { return nil }

            case .switchSpaces:
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastSpaceOrTabSwitchTime > 0.28 {
                    lastSpaceOrTabSwitchTime = now
                    performButtonAction(axis2 > 0 ? .spaceRight : .spaceLeft)
                }
                if axis1 == 0 { return nil }

            case .switchTabs:
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastSpaceOrTabSwitchTime > 0.16 {
                    lastSpaceOrTabSwitchTime = now
                    // ⇧⌘] (next tab) or ⇧⌘[ (previous tab)
                    let keyCode = UInt16(axis2 > 0 ? kVK_ANSI_RightBracket : kVK_ANSI_LeftBracket)
                    postKeyCombo(keyCode: keyCode, flags: [.maskCommand, .maskShift])
                }
                if axis1 == 0 { return nil }

            case .zoom:
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastSpaceOrTabSwitchTime > 0.12 {
                    lastSpaceOrTabSwitchTime = now
                    let keyCode = UInt16(axis2 > 0 ? kVK_ANSI_Equal : kVK_ANSI_Minus)
                    postKeyCombo(keyCode: keyCode, flags: [.maskCommand])
                }
                if axis1 == 0 { return nil }
            }
        }

        // 2. Handle Vertical Scroll Wheel (Direction & Smooth Scrolling)
        if axis1 != 0 {
            if config.standardVerticalScroll {
                axis1 = -axis1
            }

            if config.smoothScrolling {
                enqueueSmoothScroll(verticalTicks: Double(axis1) * config.scrollSpeedMultiplier)
                return nil
            } else {
                let scaled = Int64((Double(axis1) * config.scrollSpeedMultiplier).rounded())
                let finalAxis1 = scaled == 0 ? (axis1 > 0 ? 1 : -1) : scaled
                event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: finalAxis1)
                let ptY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
                if ptY != 0 {
                    let sign: Double = config.standardVerticalScroll ? -1.0 : 1.0
                    event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: ptY * sign * config.scrollSpeedMultiplier)
                }
            }
        }

        return passThrough
    }

    private func enqueueSmoothScroll(verticalTicks: Double) {
        // Each discrete mouse notch adds pixel velocity (~26 px per tick) decayed smoothly at 120 Hz
        smoothScrollVelocityY += verticalTicks * 9.5
        guard smoothScrollTimer == nil else { return }

        smoothScrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stepSmoothScroll()
            }
        }
    }

    private func stepSmoothScroll() {
        if abs(smoothScrollVelocityY) < 0.45 {
            smoothScrollVelocityY = 0
            smoothScrollTimer?.invalidate()
            smoothScrollTimer = nil
            return
        }

        let stepPixels = Int32(smoothScrollVelocityY.rounded())
        smoothScrollVelocityY *= 0.84 // Smooth exponential momentum decay

        guard stepPixels != 0,
              let src = CGEventSource(stateID: .hidSystemState),
              let scrollEvent = CGEvent(
                  scrollWheelEvent2Source: src,
                  units: .pixel,
                  wheelCount: 1,
                  wheel1: stepPixels,
                  wheel2: 0,
                  wheel3: 0
              ) else { return }

        scrollEvent.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        scrollEvent.post(tap: .cgSessionEventTap)
    }

    private func handleOtherMouseButton(buttonNumber: Int, isDown: Bool, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        switch buttonNumber {
        case 2: // Middle Button (Wheel click)
            guard config.middleButtonAction != .systemDefault else { return passThrough }
            if isDown {
                performButtonAction(config.middleButtonAction)
            }
            return nil

        case 3: // Back Button
            guard config.backButtonAction != .systemDefault else { return passThrough }
            if isDown {
                performButtonAction(config.backButtonAction)
            }
            return nil

        case 4: // Forward Button
            guard config.forwardButtonAction != .systemDefault else { return passThrough }
            if isDown {
                performButtonAction(config.forwardButtonAction)
            }
            return nil

        case 5, 6: // Thumb / Gesture Button (when exposed as standard HID button 5/6)
            if config.gesturesEnabled {
                handleDivertedGestureButtonState(isDown: isDown)
                return nil
            }
            guard config.gestureButtonClickAction != .systemDefault else { return passThrough }
            if isDown {
                performButtonAction(config.gestureButtonClickAction)
            }
            return nil

        default:
            return passThrough
        }
    }

    private func handleDivertedGestureButtonState(isDown: Bool) {
        if isDown {
            isGestureButtonHeld = true
            gestureTriggeredDuringHold = false
            gestureAccumulatedDelta = .zero
            setGestureTapEnabled(config.gesturesEnabled)
        } else {
            let wasHeld = isGestureButtonHeld
            let didDrag = gestureTriggeredDuringHold
            isGestureButtonHeld = false
            gestureTriggeredDuringHold = false
            gestureAccumulatedDelta = .zero
            setGestureTapEnabled(false)

            if wasHeld && !didDrag {
                performButtonAction(config.gestureButtonClickAction)
            }
        }
    }

    private func processGestureDragDelta(dx: CGFloat, dy: CGFloat) {
        guard !gestureTriggeredDuringHold else { return }
        gestureAccumulatedDelta.x += dx
        gestureAccumulatedDelta.y += dy

        let absX = abs(gestureAccumulatedDelta.x)
        let absY = abs(gestureAccumulatedDelta.y)
        guard max(absX, absY) >= gestureDragThreshold else { return }

        gestureTriggeredDuringHold = true
        if absY >= absX {
            // Screen coordinates: negative dy is moving mouse UP, positive dy is moving mouse DOWN
            if gestureAccumulatedDelta.y < 0 {
                performButtonAction(config.gestureUpAction)
            } else {
                performButtonAction(config.gestureDownAction)
            }
        } else {
            if gestureAccumulatedDelta.x < 0 {
                performButtonAction(config.gestureLeftAction)
            } else {
                performButtonAction(config.gestureRightAction)
            }
        }
    }

    // MARK: - Action Execution

    public func performButtonAction(_ action: MXButtonAction) {
        switch action {
        case .systemDefault:
            break
        case .missionControl:
            openSystemAction(appNamed: "Mission Control", fallbackKeyCode: UInt16(kVK_UpArrow), fallbackFlags: [.maskControl])
        case .appExpose:
            postSymbolicHotKey(SymbolicHotKey.appExpose, fallbackKeyCode: UInt16(kVK_DownArrow), fallbackFlags: [.maskControl])
        case .showDesktop:
            postSymbolicHotKey(SymbolicHotKey.showDesktop, fallbackKeyCode: UInt16(kVK_F11), fallbackFlags: [])
        case .launchpad:
            openSystemAction(appNamed: "Launchpad", fallbackKeyCode: UInt16(kVK_F4), fallbackFlags: [])
        case .spaceLeft:
            postSymbolicHotKey(SymbolicHotKey.moveLeftASpace, fallbackKeyCode: UInt16(kVK_LeftArrow), fallbackFlags: [.maskControl])
        case .spaceRight:
            postSymbolicHotKey(SymbolicHotKey.moveRightASpace, fallbackKeyCode: UInt16(kVK_RightArrow), fallbackFlags: [.maskControl])
        case .navigateBack:
            postKeyCombo(keyCode: UInt16(kVK_ANSI_LeftBracket), flags: [.maskCommand])
        case .navigateForward:
            postKeyCombo(keyCode: UInt16(kVK_ANSI_RightBracket), flags: [.maskCommand])
        case .playPause:
            postMediaKey(nxKeyType: 16) // NX_KEYTYPE_PLAY
        case .mutePointerDisplay:
            if let displayID = NSScreen.underPointer?.displayID {
                _ = DisplayStateModel.shared.handleMediaKey(.mute, on: displayID)
            }
        case .toggleMacBookScreen:
            DisplayStateModel.shared.toggleBuiltinDisplay()
        case .toggleCaffeine:
            DisplayStateModel.shared.toggleCaffeine()
        case .toggleWheelMode:
            toggleWheelMode()
        case .copy:
            postKeyCombo(keyCode: UInt16(kVK_ANSI_C), flags: [.maskCommand])
        case .paste:
            postKeyCombo(keyCode: UInt16(kVK_ANSI_V), flags: [.maskCommand])
        }
    }

    private func openSystemAction(appNamed: String, fallbackKeyCode: UInt16, fallbackFlags: CGEventFlags) {
        let path = "/System/Applications/\(appNamed).app"
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else {
            postKeyCombo(keyCode: fallbackKeyCode, flags: fallbackFlags)
        }
    }

    /// IDs of Mission Control shortcuts in `com.apple.symbolichotkeys` (System Settings → Keyboard Shortcuts).
    private enum SymbolicHotKey {
        static let appExpose = 33
        static let showDesktop = 36
        static let moveLeftASpace = 79
        static let moveRightASpace = 81
    }

    /// Posts the shortcut the user has actually assigned to a system action, since WindowServer only reacts to
    /// the configured combination. Falls back to the macOS default when the entry has never been customized.
    private func postSymbolicHotKey(_ id: Int, fallbackKeyCode: UInt16, fallbackFlags: CGEventFlags) {
        let hotKeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        guard let entry = hotKeys?[String(id)] as? [String: Any] else {
            postKeyCombo(keyCode: fallbackKeyCode, flags: fallbackFlags)
            return
        }
        // A disabled shortcut can't be triggered at all; WindowServer would ignore any synthesized keystroke.
        if let enabled = entry["enabled"] as? Bool, !enabled {
            dlog("MX Master: system shortcut \(id) is disabled in Keyboard Shortcuts")
            return
        }
        // parameters = (character, virtual key code, modifier mask using NSEvent/CGEventFlags bit positions)
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Int],
              parameters.count >= 3,
              parameters[1] != 0xFFFF else {
            postKeyCombo(keyCode: fallbackKeyCode, flags: fallbackFlags)
            return
        }
        postKeyCombo(keyCode: UInt16(parameters[1]), flags: CGEventFlags(rawValue: UInt64(parameters[2])))
    }

    private func postKeyCombo(keyCode: UInt16, flags: CGEventFlags) {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
            return
        }
        // Real arrow key presses carry the Fn + NumericPad flags; without them the WindowServer ignores
        // synthesized ⌃← / ⌃→ / ⌃↓ (Space switching, App Exposé).
        let arrowKeys: Set<Int> = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
        var effectiveFlags = flags
        if arrowKeys.contains(Int(keyCode)) {
            effectiveFlags.formUnion([.maskSecondaryFn, .maskNumericPad])
        }
        down.flags = effectiveFlags
        up.flags = effectiveFlags
        down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postMediaKey(nxKeyType: Int) {
        for isDown in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: isDown ? 0xA00 : 0xB00)
            let data1 = (nxKeyType << 16) | (isDown ? (0xA << 8) : (0xB << 8))
            if let nsEvent = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) {
                nsEvent.cgEvent?.post(tap: .cghidEventTap)
            }
        }
    }
}

// MARK: - Event Tap C Callback

private nonisolated func mxMasterEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated {
            MXMasterManager.shared.reenableTapAfterTimeout()
        }
        return Unmanaged.passUnretained(event)
    }

    return MainActor.assumeIsolated {
        MXMasterManager.shared.handleCGEvent(type: type, event: event)
    }
}
