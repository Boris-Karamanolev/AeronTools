import Foundation

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
