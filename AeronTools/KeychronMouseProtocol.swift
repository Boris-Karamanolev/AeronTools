import Foundation

// MARK: - KeychronMouseProtocol

/// Keychron's 4K mouse protocol (Keychron Launcher's "4k" protocol), on the vendor collection 0xFF0A / 0x01 of
/// the 4K Link receiver and of the mouse on its USB cable. Bluetooth doesn't carry it.
///
/// Every packet is 64 bytes on report 0: [command, 0, 0x80 | length, sub-command, payload…, checksum], where
/// the checksum in byte 63 is 0xA1 minus the sum of bytes 0…62. Through the receiver, 0x40 on byte 0 sends the
/// packet on to the mouse, and the mouse's replies come back with it set; without it the receiver answers itself.
/// Replies echo bytes 0 and 3.
///
/// Settings block (read 0x04/0x81/0x01, written whole with 0x04/0xB5/0x02, then saved with 0x0A/0x81/0x01):
///   [4]      flags: bit 0 angle snapping, bit 5 motion sync
///   [5]      report rate code: 125 Hz × 2^code (0 = 125 Hz, 3 = 1 kHz, 5 = 4 kHz)
///   [6]      enabled-stage mask (1, 3, 7, 15, 31); [7] active stage
///   [8…27]   five stages of X then Y DPI, little-endian
///   [43]     lift-off distance in mm (1 or 2)
/// Power (0x01/0x81/0x01): [5] charge state, [6] battery percent, [8] active DPI stage, [9] report rate code,
/// [10] the highest report rate code the current link allows (5 on the receiver, 3 on the cable). The mouse also
/// sends this on its own when the DPI button is pressed or charging starts or stops. The receiver's own answer,
/// which it also sends whenever the mouse joins or leaves it, has 0x0A in [4] while the mouse is linked.
/// Version (0x00/0x81/0x00): [4…5] model ID, little-endian.
enum KeychronMouseProtocol {
    nonisolated static let vendorID = 0x3434
    nonisolated static let usagePage = 0xFF0A
    nonisolated static let usage = 0x01
    /// The Keychron 4K Link receiver.
    nonisolated static let receiverProductID = 0xD038
    /// The M3 Mini 4K (aluminium), on its USB cable and over Bluetooth.
    nonisolated static let m3MiniProductID = 0xD041
    /// The model ID the M3 Mini 4K (aluminium) reports through the receiver.
    nonisolated static let m3MiniModelID: UInt16 = 0x0622

    nonisolated static let packetLength = 64
    nonisolated static let dpiRange = 100...26_000
    nonisolated static let dpiStep = 50
    nonisolated static let stageCount = 5
    nonisolated static let liftOffDistances = [1, 2]
    /// The rates Keychron Launcher offers. Code 1 (250 Hz) exists but isn't offered.
    nonisolated static let reportRates = [125, 500, 1000, 2000, 4000]

    nonisolated static let routeBit: UInt8 = 0x40
    nonisolated static let linkedState: UInt8 = 0x0A

    struct Command: Equatable {
        let id: UInt8
        let length: UInt8
        let sub: UInt8

        nonisolated static let version = Command(id: 0x00, length: 0x81, sub: 0x00)
        nonisolated static let power = Command(id: 0x01, length: 0x81, sub: 0x01)
        nonisolated static let readSettings = Command(id: 0x04, length: 0x81, sub: 0x01)
        nonisolated static let writeSettings = Command(id: 0x04, length: 0xB5, sub: 0x02)
        nonisolated static let save = Command(id: 0x0A, length: 0x81, sub: 0x01)
        nonisolated static let readButtons = Command(id: 0x03, length: 0x81, sub: 0x01)
        nonisolated static let writeButton = Command(id: 0x03, length: 0x85, sub: 0x04)
    }

    /// A finished packet: the command, `payload` from byte 4, and the checksum.
    nonisolated static func packet(_ command: Command, routed: Bool, payload: ArraySlice<UInt8> = []) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: packetLength)
        packet[0] = routed ? command.id | routeBit : command.id
        packet[2] = command.length
        packet[3] = command.sub
        for (offset, byte) in payload.prefix(packetLength - 5).enumerated() {
            packet[4 + offset] = byte
        }
        packet[packetLength - 1] = 0xA1 &- packet[0..<(packetLength - 1)].reduce(0, &+)
        return packet
    }

    /// Whether `report` answers `packet`: the same command byte (routing included) and sub-command.
    nonisolated static func isReply(_ report: [UInt8], to packet: [UInt8]) -> Bool {
        report.count > 3 && report[0] == packet[0] && report[3] == packet[3]
    }

    // MARK: Replies

    struct Power: Equatable {
        let percent: Int?
        let isCharging: Bool
        let activeStage: Int
        /// The fastest report rate the current link allows; nil if the mouse didn't say.
        let maxReportRateHz: Int?

        /// Charge state 1 is charging and 2 is full; full counts as charging so no low-battery alert fires.
        nonisolated init?(_ report: [UInt8]) {
            guard report.count > 8, report[3] == Command.power.sub else { return nil }
            percent = report[6] <= 100 ? Int(report[6]) : nil
            isCharging = report[5] != 0
            activeStage = Int(report[8])
            maxReportRateHz = report.count > 10 ? KeychronMouseProtocol.reportRateHz(code: report[10]) : nil
        }
    }

    nonisolated static func modelID(fromVersion report: [UInt8]) -> UInt16? {
        guard report.count > 5 else { return nil }
        return UInt16(report[4]) | UInt16(report[5]) << 8
    }

    /// The settings block as the mouse stores it. Writes send it back whole, so bytes the app doesn't
    /// understand keep the mouse's own values.
    struct Settings: Equatable {
        /// Bytes 4…55 of the read reply, which are bytes 4…55 of the write.
        private(set) var block: ArraySlice<UInt8>

        nonisolated init?(_ report: [UInt8]) {
            guard report.count >= 56, report[3] == Command.readSettings.sub else { return nil }
            block = report[4...55]
        }

        private static let angleSnappingBit: UInt8 = 0x01
        private static let motionSyncBit: UInt8 = 0x20

        /// Stages the DPI button cycles through, from the enabled-stage mask.
        var stageCount: Int {
            min(max(block[6].nonzeroBitCount, 1), KeychronMouseProtocol.stageCount)
        }

        var activeStage: Int {
            get { min(Int(block[7]), stageCount - 1) }
            set { block[7] = UInt8(clamping: newValue) }
        }

        func dpi(stage: Int) -> Int {
            let offset = 8 + stage * 4
            return Int(block[offset]) | Int(block[offset + 1]) << 8
        }

        /// Sets both axes of one stage.
        mutating func setDPI(_ dpi: Int, stage: Int) {
            let offset = 8 + stage * 4
            for axis in [offset, offset + 2] {
                block[axis] = UInt8(dpi & 0xFF)
                block[axis + 1] = UInt8(dpi >> 8)
            }
        }

        var reportRateHz: Int? {
            get { KeychronMouseProtocol.reportRateHz(code: block[5]) }
            set {
                guard let newValue, let code = KeychronMouseProtocol.reportRateCode(hz: newValue) else { return }
                block[5] = code
            }
        }

        var liftOffMillimeters: Int {
            get { Int(block[43]) }
            set { block[43] = UInt8(clamping: newValue) }
        }

        var isMotionSyncOn: Bool {
            get { block[4] & Self.motionSyncBit != 0 }
            set { setFlag(Self.motionSyncBit, newValue) }
        }

        var isAngleSnappingOn: Bool {
            get { block[4] & Self.angleSnappingBit != 0 }
            set { setFlag(Self.angleSnappingBit, newValue) }
        }

        private mutating func setFlag(_ bit: UInt8, _ isOn: Bool) {
            block[4] = isOn ? block[4] | bit : block[4] & ~bit
        }
    }

    // MARK: Buttons

    /// The side buttons' slots in the button map. The map (read 0x03/0x81/0x01) holds four bytes per button
    /// from byte 4; one button is written with 0x03/0x85/0x04 [slot, four bytes], then saved. Each slot says
    /// what the button sends: a mouse button [0x01, 0, 0xF0 + button, 0], or a key with HID modifier bits
    /// [0x00, modifiers, HID usage, 0]. The mouse sends it itself, on every link, with or without the app.
    enum SideButton: Int, CaseIterable, Identifiable {
        case back = 3
        case forward = 4

        nonisolated var id: Int { rawValue }

        nonisolated var title: String {
            self == .back ? "Back Button" : "Forward Button"
        }

        /// The factory assignment: mouse button 4 or 5. Many Mac apps ignore those, so it isn't the default here.
        nonisolated var factoryAssignment: [UInt8] {
            [0x01, 0x00, self == .back ? 0xF3 : 0xF4, 0x00]
        }

        /// What the button does until it's changed: ⌘[ or ⌘], which every Mac app treats as back and forward.
        nonisolated var defaultAction: AccessoryButtonAction {
            self == .back ? .navigateBack : .navigateForward
        }
    }

    /// Actions the mouse can send on its own, each as this Mac's shortcut for it. System Default is the plain
    /// mouse button (4 or 5), which only some apps treat as back and forward.
    nonisolated static let buttonActions: [AccessoryButtonAction] = [
        .navigateBack, .navigateForward, .missionControl, .appExpose, .showDesktop, .spaceLeft, .spaceRight,
        .copy, .paste, .systemDefault,
    ]

    /// The button map entry that performs `action` on `button`, with this Mac's shortcut for it (custom Mission
    /// Control shortcuts included). Nil if the mouse can't do it on its own: the action isn't a shortcut, or its
    /// shortcut is turned off or uses a key the mouse can't send.
    static func assignment(for action: AccessoryButtonAction, on button: SideButton) -> [UInt8]? {
        if action == .systemDefault { return button.factoryAssignment }
        return AccessoryActions.shortcut(for: action).flatMap { keyAssignment($0) }
    }

    /// The offered action a button map entry performs; nil for anything else (e.g. set in Keychron Launcher).
    static func action(for assignment: [UInt8], on button: SideButton) -> AccessoryButtonAction? {
        buttonActions.first { self.assignment(for: $0, on: button) == assignment }
    }

    /// A shortcut as a key entry: [0x00, HID modifier bits, HID usage, 0].
    static func keyAssignment(_ shortcut: AccessoryActions.Shortcut) -> [UInt8]? {
        guard let key = shortcut.hidKey else { return nil }
        return [0x00, key.modifiers, key.usage, 0x00]
    }

    /// One button's entry from a button map reply.
    nonisolated static func assignment(of button: SideButton, inButtonMap report: [UInt8]) -> [UInt8]? {
        let offset = 4 + button.rawValue * 4
        guard report.count >= offset + 4, report[3] == Command.readButtons.sub else { return nil }
        return Array(report[offset..<(offset + 4)])
    }

    nonisolated static func reportRateHz(code: UInt8) -> Int? {
        code <= 5 ? 125 << Int(code) : nil
    }

    nonisolated static func reportRateCode(hz: Int) -> UInt8? {
        (0...5).first { 125 << $0 == hz }.map(UInt8.init)
    }

    /// Rounds to the mouse's 50 DPI steps, within its range.
    nonisolated static func clampDPI(_ dpi: Int) -> Int {
        let rounded = Int((Double(dpi) / Double(dpiStep)).rounded()) * dpiStep
        return min(max(rounded, dpiRange.lowerBound), dpiRange.upperBound)
    }
}
