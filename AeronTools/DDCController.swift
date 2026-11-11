import Foundation
import CoreGraphics
import IOKit

// MARK: - MonitorIdentity

/// EDID-derived identity that survives reconnects and reboots, unlike CGDirectDisplayID.
/// Two identical monitors without serial numbers share an identity; callers disambiguate by display ID order.
nonisolated struct MonitorIdentity: Hashable, Sendable {
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32

    init(vendor: UInt32, model: UInt32, serial: UInt32) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
    }

    init(displayID: CGDirectDisplayID) {
        self.init(vendor: CGDisplayVendorNumber(displayID),
                  model: CGDisplayModelNumber(displayID),
                  serial: CGDisplaySerialNumber(displayID))
    }

    var key: String { "\(vendor)-\(model)-\(serial)" }
}

// MARK: - DDC/CI Protocol

/// Pure packet encoding/decoding for MCCS over DDC/CI, kept separate from I/O so it can be unit tested.
nonisolated enum DDCProtocol {
    static let chipAddress: UInt32 = 0x37
    static let dataAddress: UInt32 = 0x51
    /// Host address (0x6E) XOR sub-address (0x51) seeds every checksum.
    private static let checksumSeed: UInt8 = 0x6E ^ 0x51

    static func checksummed(_ bytes: [UInt8]) -> [UInt8] {
        bytes + [bytes.reduce(checksumSeed, ^)]
    }

    static func setVCPPacket(_ vcp: UInt8, value: UInt16) -> [UInt8] {
        checksummed([0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    static func getVCPPacket(_ vcp: UInt8) -> [UInt8] {
        checksummed([0x82, 0x01, vcp])
    }

    static func capabilitiesPacket(offset: Int) -> [UInt8] {
        checksummed([0x83, 0xF3, UInt8((offset >> 8) & 0xFF), UInt8(offset & 0xFF)])
    }

    /// Parses a "Get VCP Feature" reply: 6E 88 02 <result> <vcp> <type> <maxHi> <maxLo> <curHi> <curLo> <chk>.
    static func parseVCPReply(_ reply: [UInt8], vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        guard reply.count >= 10, reply[2] == 0x02, reply[3] == 0x00, reply[4] == vcp else { return nil }
        let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        return (current, max)
    }

    /// Parses one capabilities fragment: 6E <0x80|len> E3 <offHi> <offLo> <data...>. Returns nil for a malformed
    /// or out-of-order fragment and an empty array at the end of the string.
    static func parseCapabilitiesFragment(_ reply: [UInt8], offset: Int) -> [UInt8]? {
        guard reply.count >= 5, reply[2] == 0xE3, (Int(reply[3]) << 8 | Int(reply[4])) == offset else { return nil }
        let length = Int(reply[1] & 0x7F) - 3
        guard length > 0 else { return [] }
        return Array(reply[5..<min(reply.count, 5 + length)])
    }

    /// Input source codes listed for VCP 0x60 in a capabilities string, e.g. "... 60(0F 11 12 ) ..." → [0x0F, 0x11, 0x12].
    static func inputSources(fromCapabilities caps: String) -> [UInt8] {
        let upper = caps.uppercased()
        var searchStart = upper.startIndex
        while let range = upper.range(of: "60(", range: searchStart..<upper.endIndex) {
            searchStart = range.upperBound
            // Skip longer codes that merely end in "60", e.g. "E260(".
            if range.lowerBound > upper.startIndex {
                let previous = upper[upper.index(before: range.lowerBound)]
                if previous.isHexDigit { continue }
            }
            guard let close = upper[range.upperBound...].firstIndex(of: ")") else { return [] }
            return upper[range.upperBound..<close]
                .split(separator: " ")
                .compactMap { UInt8($0, radix: 16) }
        }
        return []
    }
}

// MARK: - DDCController

/// Talks DDC/CI to external monitors on Apple silicon through IOAVService, one service per monitor.
/// All I2C traffic is serialized on a private queue; monitors misbehave when commands overlap or arrive too fast.
nonisolated final class DDCController: @unchecked Sendable {
    static let shared = DDCController()

    private typealias CreateFunc = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?
    private typealias I2CFunc = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private let createService: CreateFunc?
    private let writeI2C: I2CFunc?
    private let readI2C: I2CFunc?

    private let queue = DispatchQueue(label: "com.aeronlabs.AeronTools.ddc", qos: .userInitiated)
    // Guarded by `queue`.
    private var cachedServices: [(identity: MonitorIdentity, service: AnyObject)]?
    private var pendingWrites: [WriteKey: UInt16] = [:]
    private var isDraining = false

    private struct WriteKey: Hashable {
        let displayID: CGDirectDisplayID
        let vcp: UInt8
    }

    /// MCCS recommends ~50 ms between commands; faster bursts get dropped by many monitors.
    private static let commandSpacing: useconds_t = 50_000
    private static let replyDelay: useconds_t = 40_000

    private init() {
        let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        func load<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle ?? rtldDefault, name).map { unsafeBitCast($0, to: type) }
        }
        createService = load("IOAVServiceCreateWithService", as: CreateFunc.self)
        writeI2C = load("IOAVServiceWriteI2C", as: I2CFunc.self)
        readI2C = load("IOAVServiceReadI2C", as: I2CFunc.self)
    }

    var isAvailable: Bool { createService != nil && writeI2C != nil }

    /// Drops cached services; call after displays are added or removed.
    func invalidate() {
        queue.async { self.cachedServices = nil }
    }

    /// Async so callers never block behind queued I2C traffic (a capabilities read can take seconds).
    func hasService(for displayID: CGDirectDisplayID) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.service(for: displayID) != nil) }
        }
    }

    /// Queues a write. Rapid writes to the same control (slider drags) collapse into the latest value.
    func write(_ vcp: UInt8, value: UInt16, to displayID: CGDirectDisplayID) {
        queue.async {
            self.pendingWrites[WriteKey(displayID: displayID, vcp: vcp)] = value
            self.drainWrites()
        }
    }

    func read(_ vcp: UInt8, from displayID: CGDirectDisplayID) async -> (current: UInt16, max: UInt16)? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.readSync(vcp, from: displayID)) }
        }
    }

    /// Reads the MCCS capabilities string (takes a few seconds; cache the result).
    func capabilities(for displayID: CGDirectDisplayID) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.capabilitiesSync(for: displayID)) }
        }
    }

    // MARK: Queue-confined helpers

    private func drainWrites() {
        guard !isDraining else { return }
        isDraining = true
        while let (key, value) = pendingWrites.first {
            pendingWrites.removeValue(forKey: key)
            if let service = service(for: key.displayID) {
                send(DDCProtocol.setVCPPacket(key.vcp, value: value), to: service)
            }
            usleep(Self.commandSpacing)
        }
        isDraining = false
    }

    @discardableResult
    private func send(_ packet: [UInt8], to service: AnyObject) -> Bool {
        guard let writeI2C else { return false }
        var bytes = packet
        return bytes.withUnsafeMutableBytes { buffer in
            writeI2C(service, DDCProtocol.chipAddress, DDCProtocol.dataAddress, buffer.baseAddress!, UInt32(buffer.count))
        } == kIOReturnSuccess
    }

    private func receive(count: Int, from service: AnyObject) -> [UInt8]? {
        guard let readI2C else { return nil }
        var reply = [UInt8](repeating: 0, count: count)
        let status = reply.withUnsafeMutableBytes { buffer in
            readI2C(service, DDCProtocol.chipAddress, DDCProtocol.dataAddress, buffer.baseAddress!, UInt32(buffer.count))
        }
        return status == kIOReturnSuccess ? reply : nil
    }

    private func readSync(_ vcp: UInt8, from displayID: CGDirectDisplayID) -> (current: UInt16, max: UInt16)? {
        guard let service = service(for: displayID) else { return nil }
        for _ in 0..<4 {
            send(DDCProtocol.getVCPPacket(vcp), to: service)
            usleep(Self.replyDelay)
            if let reply = receive(count: 12, from: service),
               let value = DDCProtocol.parseVCPReply(reply, vcp: vcp) {
                usleep(Self.commandSpacing)
                return value
            }
            usleep(Self.commandSpacing)
        }
        return nil
    }

    private func capabilitiesSync(for displayID: CGDirectDisplayID) -> String? {
        guard let service = service(for: displayID) else { return nil }
        var data: [UInt8] = []
        var offset = 0
        while offset < 4096 {
            var fragment: [UInt8]?
            for _ in 0..<5 {
                send(DDCProtocol.capabilitiesPacket(offset: offset), to: service)
                usleep(Self.replyDelay)
                if let reply = receive(count: 38, from: service),
                   let parsed = DDCProtocol.parseCapabilitiesFragment(reply, offset: offset) {
                    fragment = parsed
                    break
                }
                usleep(Self.commandSpacing)
            }
            guard let fragment else { return data.isEmpty ? nil : String(decoding: data, as: UTF8.self) }
            if fragment.isEmpty { break }
            data += fragment
            offset += fragment.count
        }
        return String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
    }

    // MARK: Service discovery

    /// Pairs the display with its DCPAVServiceProxy by EDID identity. Monitors sharing an identity are paired in
    /// display ID order; a lone external monitor is used even if its identity couldn't be read.
    private func service(for displayID: CGDirectDisplayID) -> AnyObject? {
        if cachedServices == nil {
            cachedServices = discoverServices()
        }
        guard let services = cachedServices, !services.isEmpty else { return nil }

        let identity = MonitorIdentity(displayID: displayID)
        let matches = services.filter { $0.identity == identity }
        if matches.count == 1 { return matches[0].service }
        if matches.count > 1 {
            let twins = onlineExternalDisplays().filter { MonitorIdentity(displayID: $0) == identity }.sorted()
            if let index = twins.firstIndex(of: displayID), index < matches.count {
                return matches[index].service
            }
            return nil
        }
        return services.count == 1 ? services[0].service : nil
    }

    private func discoverServices() -> [(identity: MonitorIdentity, service: AnyObject)] {
        guard let createService else { return [] }
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var result: [(identity: MonitorIdentity, service: AnyObject)] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External",
                  let service = createService(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            result.append((identity: Self.identity(ofAncestorsOf: entry) ?? MonitorIdentity(vendor: 0, model: 0, serial: 0),
                           service: service))
        }
        return result
    }

    /// The framebuffer above each DCPAVServiceProxy carries the monitor's EDID attributes.
    private static func identity(ofAncestorsOf entry: io_registry_entry_t) -> MonitorIdentity? {
        var current = entry
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<12 {
            if let attributes = IORegistryEntryCreateCFProperty(current, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let product = attributes["ProductAttributes"] as? [String: Any] {
                let vendor = (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value ?? 0
                let model = (product["ProductID"] as? NSNumber)?.uint32Value ?? 0
                let serial = (product["SerialNumber"] as? NSNumber)?.uint32Value ?? 0
                return MonitorIdentity(vendor: vendor, model: model, serial: serial)
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(current)
            current = parent
        }
        return nil
    }

    private func onlineExternalDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(32, &ids, &count)
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
    }
}

// MARK: - Input Sources

nonisolated enum InputSource {
    /// MCCS 2.2 names for VCP 0x60 values. Vendors reuse codes freely, so unknown values fall back to hex.
    static func name(for code: UInt8) -> String {
        switch code {
        case 0x01: return "VGA 1"
        case 0x02: return "VGA 2"
        case 0x03: return "DVI 1"
        case 0x04: return "DVI 2"
        case 0x05: return "Composite 1"
        case 0x06: return "Composite 2"
        case 0x07: return "S-Video 1"
        case 0x08: return "S-Video 2"
        case 0x0C: return "Component 1"
        case 0x0D: return "Component 2"
        case 0x0E: return "Component 3"
        case 0x0F: return "DisplayPort 1"
        case 0x10: return "DisplayPort 2"
        case 0x11: return "HDMI 1"
        case 0x12: return "HDMI 2"
        case 0x1B: return "USB-C"
        default: return String(format: "Input 0x%02X", code)
        }
    }

    /// Used when a monitor doesn't report its inputs.
    static let commonCodes: [UInt8] = [0x0F, 0x10, 0x11, 0x12, 0x1B]
}
