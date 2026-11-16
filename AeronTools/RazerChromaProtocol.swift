import Foundation

// MARK: - RazerChromaProtocol

/// Razer's Chroma control protocol, as spoken by the Thunderbolt 4 Dock Chroma's lighting controller
/// (a small USB HID device inside the dock). Every request and reply is one 90-byte feature report without a
/// report ID: status, transaction ID, a data size, a command class and ID, up to 80 argument bytes and an XOR
/// checksum. The controller stores what it's given, so the lighting stays as set without the app.
///
/// Layout and commands follow the OpenRazer project's "extended matrix" commands, confirmed against a
/// Thunderbolt 4 Dock Chroma (firmware 1.0).
enum RazerChromaProtocol {
    nonisolated static let vendorID = 0x1532
    /// The dock's lighting controller.
    nonisolated static let dockChromaProductID = 0x0F21
    /// The dock's own USB 2 and USB 3 hubs. The USB-A ports and the built-in Ethernet adapter hang off them.
    nonisolated static let dockUSB2HubProductID = 0x0F2F
    nonisolated static let dockUSB3HubProductID = 0x0F30
    /// The controller's HID interface is a consumer-page collection carrying the vendor feature report.
    nonisolated static let usagePage = 0x0C
    nonisolated static let usage = 0x01

    nonisolated static let reportLength = 90
    nonisolated static let transactionID: UInt8 = 0x1F
    /// Store settings in the controller's memory, so they survive the dock losing power.
    nonisolated static let varStore: UInt8 = 0x01
    /// The dock has one lighting zone: its underglow.
    nonisolated static let zone: UInt8 = 0x00
    /// Speed byte Razer uses for the wave effect.
    nonisolated static let waveSpeed: UInt8 = 0x28

    /// The first byte of a reply.
    nonisolated enum Status: UInt8 {
        case busy = 0x01
        case success = 0x02
        case failure = 0x03
        case timeout = 0x04
        case notSupported = 0x05
    }

    nonisolated struct Command: Equatable {
        let commandClass: UInt8
        let id: UInt8
        /// Bytes of arguments the controller expects (or returns).
        let size: UInt8

        nonisolated static let firmware = Command(commandClass: 0x00, id: 0x81, size: 0x02)
        nonisolated static let serial = Command(commandClass: 0x00, id: 0x82, size: 0x16)
        nonisolated static let getEffect = Command(commandClass: 0x0F, id: 0x82, size: 0x0C)
        nonisolated static let getBrightness = Command(commandClass: 0x0F, id: 0x84, size: 0x03)
        nonisolated static let setBrightness = Command(commandClass: 0x0F, id: 0x04, size: 0x03)

        /// Setting an effect takes a size that depends on the effect, so it's built per request.
        nonisolated static func setEffect(size: UInt8) -> Command {
            Command(commandClass: 0x0F, id: 0x02, size: size)
        }
    }

    // MARK: Packets

    nonisolated static func packet(_ command: Command, arguments: [UInt8] = []) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: reportLength)
        packet[1] = transactionID
        packet[5] = command.size
        packet[6] = command.commandClass
        packet[7] = command.id
        for (offset, byte) in arguments.prefix(80).enumerated() {
            packet[8 + offset] = byte
        }
        packet[88] = checksum(packet)
        return packet
    }

    /// XOR of bytes 2 through 87.
    nonisolated static func checksum(_ packet: [UInt8]) -> UInt8 {
        packet[2..<88].reduce(0, ^)
    }

    /// The reply's status, if it answers `packet` (same command class and ID).
    nonisolated static func status(of reply: [UInt8], answering packet: [UInt8]) -> Status? {
        guard reply.count >= reportLength, reply[6] == packet[6], reply[7] == packet[7] else { return nil }
        return Status(rawValue: reply[0])
    }

    nonisolated static func getEffectPacket() -> [UInt8] {
        packet(.getEffect, arguments: [varStore, zone])
    }

    nonisolated static func getBrightnessPacket() -> [UInt8] {
        packet(.getBrightness, arguments: [varStore, zone])
    }

    nonisolated static func setBrightnessPacket(_ brightness: UInt8) -> [UInt8] {
        packet(.setBrightness, arguments: [varStore, zone, brightness])
    }

    /// Nil for a lighting without a mode: there's nothing the app knows how to send.
    nonisolated static func setEffectPacket(_ lighting: Lighting) -> [UInt8]? {
        let header = [varStore, zone]
        switch lighting.mode {
        case nil:
            return nil
        case .off:
            return packet(.setEffect(size: 0x06), arguments: header + [0x00])
        case .staticColor:
            return packet(.setEffect(size: 0x09), arguments: header + [0x01, 0x00, 0x00, 0x01] + lighting.primary.bytes)
        case .breathing:
            switch lighting.breathing {
            case .single:
                return packet(.setEffect(size: 0x09), arguments: header + [0x02, 0x01, 0x00, 0x01] + lighting.primary.bytes)
            case .dual:
                return packet(.setEffect(size: 0x0C),
                              arguments: header + [0x02, 0x02, 0x00, 0x02] + lighting.primary.bytes + lighting.secondary.bytes)
            case .random:
                return packet(.setEffect(size: 0x06), arguments: header + [0x02, 0x00, 0x00, 0x00])
            }
        case .spectrum:
            return packet(.setEffect(size: 0x06), arguments: header + [0x03])
        case .wave:
            return packet(.setEffect(size: 0x06), arguments: header + [0x04, lighting.waveDirection.rawValue, waveSpeed])
        }
    }

    // MARK: Replies

    /// Firmware as "major.minor".
    nonisolated static func parseFirmware(_ reply: [UInt8]) -> String? {
        guard reply.count >= reportLength else { return nil }
        return "\(reply[8]).\(reply[9])"
    }

    /// The serial number: ASCII, padded with zeros.
    nonisolated static func parseSerial(_ reply: [UInt8]) -> String? {
        guard reply.count >= reportLength else { return nil }
        let bytes = reply[8..<(8 + Int(Command.serial.size))].prefix { $0 != 0 }
        let serial = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return serial.isEmpty ? nil : serial
    }

    /// Brightness, 0…255.
    nonisolated static func parseBrightness(_ reply: [UInt8]) -> UInt8? {
        guard reply.count >= reportLength else { return nil }
        return reply[10]
    }

    /// The stored effect, laid out like a set-effect request: store, zone, effect, two parameters, a color count
    /// and the colors. Fields the effect doesn't use keep their values from `previous`, so colors picked for one
    /// effect are still there when switching back to it. Nil `mode` means an effect the app doesn't offer.
    nonisolated static func parseLighting(_ reply: [UInt8], previous: Lighting) -> Lighting? {
        guard reply.count >= reportLength else { return nil }
        var lighting = previous
        let parameter = reply[11]
        let colorCount = Int(reply[13])
        let colors = (0..<min(colorCount, 2)).map { index in
            RGB(red: reply[14 + index * 3], green: reply[15 + index * 3], blue: reply[16 + index * 3])
        }
        switch reply[10] {
        case 0x00:
            lighting.mode = .off
        case 0x01:
            lighting.mode = .staticColor
            if let color = colors.first { lighting.primary = color }
        case 0x02:
            lighting.mode = .breathing
            switch parameter {
            case 0x01: lighting.breathing = .single
            case 0x02: lighting.breathing = .dual
            default: lighting.breathing = .random
            }
            if let color = colors.first { lighting.primary = color }
            if colors.count > 1 { lighting.secondary = colors[1] }
        case 0x03:
            lighting.mode = .spectrum
        case 0x04:
            lighting.mode = .wave
            lighting.waveDirection = WaveDirection(rawValue: parameter) ?? .leftToRight
        default:
            lighting.mode = nil
        }
        return lighting
    }

    // MARK: Lighting

    nonisolated struct RGB: Equatable, Codable {
        var red: UInt8
        var green: UInt8
        var blue: UInt8

        nonisolated var bytes: [UInt8] { [red, green, blue] }

        nonisolated static let razerGreen = RGB(red: 0x44, green: 0xD6, blue: 0x2C)
        nonisolated static let blue = RGB(red: 0x00, green: 0x7A, blue: 0xFF)
    }

    nonisolated enum Mode: CaseIterable, Identifiable {
        case off, staticColor, breathing, spectrum, wave

        nonisolated var id: Self { self }

        var title: String {
            switch self {
            case .off: return "Off"
            case .staticColor: return "Static"
            case .breathing: return "Breathing"
            case .spectrum: return "Spectrum Cycling"
            case .wave: return "Wave"
            }
        }
    }

    nonisolated enum BreathingStyle: CaseIterable, Identifiable {
        case single, dual, random

        nonisolated var id: Self { self }

        var title: String {
            switch self {
            case .single: return "One Color"
            case .dual: return "Two Colors"
            case .random: return "Random"
            }
        }
    }

    nonisolated enum WaveDirection: UInt8, CaseIterable, Identifiable {
        case leftToRight = 0x01
        case rightToLeft = 0x02

        nonisolated var id: Self { self }

        var title: String {
            switch self {
            case .leftToRight: return "Left to Right"
            case .rightToLeft: return "Right to Left"
            }
        }
    }

    /// The whole lighting configuration. Only the fields the mode uses are sent.
    nonisolated struct Lighting: Equatable {
        /// Nil while the dock runs an effect the app doesn't offer (set by Razer Synapse on another computer).
        var mode: Mode?
        var primary = RGB.razerGreen
        var secondary = RGB.blue
        var breathing = BreathingStyle.single
        var waveDirection = WaveDirection.leftToRight
    }
}
