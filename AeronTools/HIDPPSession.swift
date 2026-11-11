import Foundation
import IOKit.hid

// MARK: - HIDPPSession

/// Request/response HID++ 2.0 conversation with one device behind one HID interface (a receiver slot or a
/// direct Bluetooth/USB link). Shared by all Logitech connectors: identification, feature lookup, feature
/// enumeration, and routing of the events the device pushes on its own.
///
/// Requests run one at a time and are matched to replies by feature index, function and software ID,
/// so it can share a device with other code that uses different software IDs.
@MainActor
final class HIDPPSession {
    /// Software ID used to tag this session's requests (other code on the same device uses other IDs).
    private static let softwareID: UInt8 = 0x0B
    private static let replyTimeout: Duration = .seconds(1)

    let device: IOHIDDevice
    let deviceIndex: UInt8

    /// Unsolicited packets (software ID 0): battery changes, button events and similar notifications.
    var onEvent: (([UInt8]) -> Void)?

    private(set) var featureIndices: [UInt16: UInt8] = [:]

    /// The request being answered. Replies echo bytes 1–3 of the request (index, feature/sub-ID, function/register),
    /// and long register reads also echo the sub-address in byte 4.
    private struct Waiter {
        let packet: [UInt8]
        let continuation: CheckedContinuation<[UInt8]?, Never>
    }

    private var waiter: Waiter?
    private var timeoutTask: Task<Void, Never>?
    private var queueTail: Task<Void, Never>?

    init(device: IOHIDDevice, deviceIndex: UInt8) {
        self.device = device
        self.deviceIndex = deviceIndex
    }

    // MARK: Identification

    struct Identity: Equatable {
        let name: String
        let kind: DeviceKind
    }

    /// `DeviceName.getDeviceType` values.
    enum DeviceKind: UInt8 {
        case keyboard = 0, remoteControl, numpad, mouse, touchpad, trackball, presenter, receiver
        case unknown = 0xFF

        var isPointingDevice: Bool { self == .mouse || self == .trackball || self == .touchpad }
    }

    /// Reads the device's own name and type. Returns nil when no device answers on this slot
    /// (e.g. a receiver whose paired device is off), which is how connectors decide to show nothing.
    func identify() async -> Identity? {
        guard let nameIndex = await featureIndex(for: HIDPPProtocol.featureDeviceName),
              let countReply = await request(featureIndex: nameIndex, function: 0x00) else { return nil }

        let length = Int(countReply[4])
        var bytes: [UInt8] = []
        while bytes.count < length {
            guard let chunk = await request(featureIndex: nameIndex, function: 0x01, params: [UInt8(bytes.count)]) else {
                return nil
            }
            let received = chunk[4...].prefix(length - bytes.count)
            guard !received.isEmpty else { break }
            bytes.append(contentsOf: received)
        }

        let kindReply = await request(featureIndex: nameIndex, function: 0x02)
        let kind = kindReply.flatMap { DeviceKind(rawValue: $0[4]) } ?? .unknown
        let name = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : Identity(name: name, kind: kind)
    }

    // MARK: Receiver (HID++ 1.0)

    struct PairedDevice: Equatable {
        let name: String
        let isPointingDevice: Bool
    }

    /// Reads the receiver's pairing records for this session's slot. Unlike `identify()`, this works while the
    /// device is asleep, because the receiver answers for it. Returns nil if nothing is paired in the slot.
    func receiverPairedDevice() async -> PairedDevice? {
        let slotOffset = deviceIndex &- 1
        guard let info = await request(packet: Self.receiverRegisterRead(sub: 0x20 &+ slotOffset)),
              let nameReply = await request(packet: Self.receiverRegisterRead(sub: 0x40 &+ slotOffset)) else { return nil }

        // Pairing info: [.., sub, destination, interval, wpid hi, wpid lo, .., .., kind, ..]; kind 2 = mouse,
        // 8 = trackball, 9 = touchpad.
        let kind = info[4 + 7] & 0x0F
        let length = min(Int(nameReply[5]), nameReply.count - 6)
        guard length > 0 else { return nil }
        let name = String(decoding: nameReply[6..<(6 + length)], as: UTF8.self)
        return PairedDevice(name: name, isPointingDevice: [0x02, 0x08, 0x09].contains(kind))
    }

    /// Asks the receiver to report when its devices connect or disconnect (HID++ 1.0 notification 0x41),
    /// so a sleeping device waking up arrives as an event instead of needing polling.
    func enableReceiverConnectionNotifications() async {
        // Register 0x00 (notification flags): bit 8 = wireless (connect/disconnect) notifications.
        _ = await request(packet: [HIDPPProtocol.shortReportID, 0xFF, 0x80, 0x00, 0x00, 0x01, 0x00])
    }

    private static func receiverRegisterRead(sub: UInt8) -> [UInt8] {
        [HIDPPProtocol.shortReportID, 0xFF, HIDPPProtocol.readLongRegister, 0xB5, sub, 0x00, 0x00]
    }

    // MARK: Features

    /// Resolves a feature's runtime index via `IRoot.getFeature`, caching the result.
    func featureIndex(for featureID: UInt16) async -> UInt8? {
        if let cached = featureIndices[featureID] { return cached }
        guard let reply = await request(
            featureIndex: 0x00, function: 0x00,
            params: [UInt8(featureID >> 8), UInt8(featureID & 0xFF)]
        ), reply[4] != 0 else { return nil }
        featureIndices[featureID] = reply[4]
        return reply[4]
    }

    /// Lists every feature the device implements, via `IFeatureSet` (`0x0001`).
    func enumerateFeatures() async -> [UInt16] {
        guard let setIndex = await featureIndex(for: HIDPPProtocol.featureFeatureSet),
              let countReply = await request(featureIndex: setIndex, function: 0x00) else { return [] }
        var features: [UInt16] = []
        // Index 0 is IRoot itself; the count excludes it.
        for index in 1...max(1, Int(countReply[4])) {
            guard let reply = await request(featureIndex: setIndex, function: 0x01, params: [UInt8(index)]) else { continue }
            let featureID = (UInt16(reply[4]) << 8) | UInt16(reply[5])
            features.append(featureID)
            featureIndices[featureID] = UInt8(index)
        }
        return features
    }

    /// Drops cached feature indices; they change if a different device is paired to the same slot.
    func reset() {
        featureIndices.removeAll()
    }

    // MARK: Requests

    /// Sends one request and waits for its reply. Returns the normalized reply, or nil on an error reply or timeout.
    func request(featureIndex: UInt8, function: UInt8, params: [UInt8] = []) async -> [UInt8]? {
        let previous = queueTail
        let task = Task<[UInt8]?, Never> {
            await previous?.value
            return await self.sendAndWait(featureIndex: featureIndex, function: function, params: params)
        }
        queueTail = Task { _ = await task.value }
        return await task.value
    }

    private func sendAndWait(featureIndex: UInt8, function: UInt8, params: [UInt8]) async -> [UInt8]? {
        await sendAndWait(packet: HIDPPProtocol.makeLongPacket(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionID: function,
            swID: Self.softwareID,
            params: params
        ))
    }

    /// Sends a request immediately without waiting for its reply. Only for app termination, where there's no
    /// time to await anything; the write itself completes synchronously.
    func sendWithoutReply(featureIndex: UInt8, function: UInt8, params: [UInt8] = []) {
        _ = send(HIDPPProtocol.makeLongPacket(
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionID: function,
            swID: Self.softwareID,
            params: params
        ))
    }

    /// Sends any prebuilt packet (HID++ 2.0 or 1.0) through the same one-at-a-time queue.
    func request(packet: [UInt8]) async -> [UInt8]? {
        let previous = queueTail
        let task = Task<[UInt8]?, Never> {
            await previous?.value
            return await self.sendAndWait(packet: packet)
        }
        queueTail = Task { _ = await task.value }
        return await task.value
    }

    private func sendAndWait(packet: [UInt8]) async -> [UInt8]? {
        await withCheckedContinuation { continuation in
            waiter = Waiter(packet: packet, continuation: continuation)
            guard send(packet) else {
                finish(with: nil)
                return
            }
            timeoutTask = Task {
                try? await Task.sleep(for: Self.replyTimeout)
                guard !Task.isCancelled else { return }
                self.finish(with: nil)
            }
        }
    }

    private func send(_ packet: [UInt8]) -> Bool {
        packet.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return false }
            return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(packet[0]), base, buffer.count)
                == kIOReturnSuccess
        }
    }

    private func finish(with reply: [UInt8]?) {
        guard let current = waiter else { return }
        waiter = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        current.continuation.resume(returning: reply)
    }

    // MARK: Incoming Reports

    /// Feed every report from this device's interface here. Returns true only for replies to this session's
    /// own requests; events are forwarded to `onEvent` but still reported as unhandled so other code sharing
    /// the device sees them too.
    @discardableResult
    func handle(report: [UInt8]) -> Bool {
        guard let norm = HIDPPProtocol.normalizeReport(report) else { return false }

        if let current = waiter, norm[1] == current.packet[1] {
            let sent = current.packet
            // HID++ 2.0 error: [id, index, 0xFF, featureIndex, function|swID, code]
            // HID++ 1.0 error: [id, index, 0x8F, subID, address, code] — e.g. the paired device is asleep.
            if (norm[2] == 0xFF || norm[2] == 0x8F), norm[3] == sent[2], norm[4] == sent[3] {
                finish(with: nil)
                return true
            }
            let isLongRegisterRead = sent[2] == HIDPPProtocol.readLongRegister
            if norm[2] == sent[2], norm[3] == sent[3], !isLongRegisterRead || norm[4] == sent[4] {
                finish(with: norm)
                return true
            }
        }

        guard norm[1] == deviceIndex else { return false }

        // Software ID 0 marks notifications the device sends on its own.
        if norm[2] != 0xFF, norm[2] != 0x8F, norm[3] & 0x0F == 0 {
            onEvent?(norm)
        }
        return false
    }
}

// MARK: - Feature Names

extension HIDPPProtocol {
    /// HID++ 1.0 sub-ID for reading a long (16-byte) receiver register.
    static let readLongRegister: UInt8 = 0x83

    /// Human-readable names for commonly seen HID++ 2.0 features, for the device's feature list in Settings.
    static func featureName(_ featureID: UInt16) -> String {
        switch featureID {
        case 0x0000: return "Root"
        case 0x0001: return "Feature Set"
        case 0x0003: return "Device Information"
        case 0x0005: return "Device Name"
        case 0x0007: return "Device Friendly Name"
        case 0x00C2: return "DFU Control"
        case 0x00D0: return "DFU"
        case 0x1000: return "Battery Status"
        case 0x1001: return "Battery Voltage"
        case 0x1004: return "Unified Battery"
        case 0x1300: return "LED Control"
        case 0x1814: return "Change Host"
        case 0x1815: return "Hosts Info"
        case 0x1B04: return "Reprogrammable Controls v4"
        case 0x1B0C: return "Analog Triggers"
        case 0x1D4B: return "Wireless Device Status"
        case 0x1F20: return "ADC Measurement"
        case 0x2110: return "SmartShift"
        case 0x2111: return "SmartShift Enhanced"
        case 0x2121: return "Hi-Res Wheel"
        case 0x2150: return "Thumbwheel"
        case 0x2201: return "Adjustable DPI"
        case 0x2202: return "Extended Adjustable DPI"
        case 0x8010: return "Gaming G-Keys"
        case 0x8060: return "Report Rate"
        case 0x8061: return "Extended Report Rate"
        case 0x8070: return "Color LED Effects"
        case 0x8071: return "RGB Effects"
        case 0x8090: return "Mode Status"
        case 0x8100: return "Onboard Profiles"
        case 0x8110: return "Mouse Button Spy"
        default: return "Unknown"
        }
    }
}
