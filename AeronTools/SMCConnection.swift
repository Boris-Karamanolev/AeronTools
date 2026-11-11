import Foundation
import IOKit

// MARK: - SMCConnection

/// Minimal read-only client for the AppleSMC user client.
final class SMCConnection {
    /// Shared connection used by both the wattage and thermal managers; nil if the SMC can't be opened.
    /// An open but idle user client costs nothing, so it's kept for the app's lifetime.
    static let shared = SMCConnection()

    /// Polling cadence shared by the wattage and thermal cards (and the menu bar stat). The SMC refreshes
    /// its keys about once per second; 5 s keeps the readings useful while waking the app far less often.
    static let pollInterval: TimeInterval = 5.0

    private var connection: io_connect_t = 0
    /// Key metadata never changes at runtime, so it's cached to halve the number of SMC calls per read.
    private var keyInfoCache: [UInt32: SMCKeyInfo] = [:]

    private static let handleYPCEvent: UInt32 = 2
    private static let cmdReadKey: UInt8 = 5
    private static let cmdGetKeyInfo: UInt8 = 9

    private init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit {
        IOServiceClose(connection)
    }

    /// Reads a key and decodes it as a number according to its SMC data type.
    func readValue(_ key: String) -> Double? {
        guard let (type, bytes) = read(key) else { return nil }
        switch type {
        case "flt " where bytes.count >= 4:
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "fpe2" where bytes.count >= 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0
        case "sp78" where bytes.count >= 2:
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256.0
        case "ui8 ", "ui16", "ui32":
            return Double(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        default:
            return nil
        }
    }

    private func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        let code = Self.fourCharCode(key)
        guard let info = keyInfo(for: code) else { return nil }

        var input = SMCParamStruct()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Self.cmdReadKey
        guard let output = call(input) else { return nil }

        let size = min(Int(info.dataSize), 32)
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
        return (Self.string(from: info.dataType), bytes)
    }

    private func keyInfo(for code: UInt32) -> SMCKeyInfo? {
        if let cached = keyInfoCache[code] { return cached }
        var input = SMCParamStruct()
        input.key = code
        input.data8 = Self.cmdGetKeyInfo
        guard let output = call(input) else { return nil }
        keyInfoCache[code] = output.keyInfo
        return output.keyInfo
    }

    private func call(_ input: SMCParamStruct) -> SMCParamStruct? {
        var input = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection, Self.handleYPCEvent,
            &input, MemoryLayout<SMCParamStruct>.stride,
            &output, &outputSize
        )
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private static func fourCharCode(_ string: String) -> UInt32 {
        string.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func string(from code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - SMC Kernel Structures

// Mirrors the kernel's 80-byte SMCParamStruct. Swift places a field after the previous
// struct's *size* (not stride), so explicit padding is needed after `keyInfo`.

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfo()
    var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
        = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}
