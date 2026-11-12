import Foundation
import IOKit.hid

// MARK: - HIDPPHub

/// The one HID manager for every Logitech receiver and USB-cable device the HID++ connectors use. It matches
/// every Logitech HID++ collection (vendor usage page 0xFF00) once, so the matching never changes while open;
/// each connector picks its own product IDs. Pointer movement and key presses never reach the app.
/// Attach/detach and reports arrive on the main run loop.
///
/// Each (device, HID++ index) pair has exactly one `HIDPPSession`, shared by every connector, so all requests
/// to a device go through one queue and every reply reaches the session that asked. Connectors searching the
/// same receivers can't collide.
@MainActor
final class HIDPPHub {
    static let shared = HIDPPHub()

    private var manager: IOHIDManager?
    private(set) var isOpen = false

    private struct SessionKey: Hashable {
        let device: ObjectIdentifier
        let index: UInt8
    }
    private var sessions: [SessionKey: HIDPPSession] = [:]
    /// Receivers already asked to report devices connecting and disconnecting.
    private var notifyingReceivers: Set<ObjectIdentifier> = []
    private var changeListeners: [() -> Void] = []
    private var isChangeScheduled = false

    private init() {}

    /// `onChange` runs after Logitech devices are attached or removed (once per burst).
    func watch(onChange: @escaping () -> Void) {
        changeListeners.append(onChange)
        if manager == nil {
            start()
        }
    }

    /// The attached devices with one of `productIDs`, once opened.
    func devices(productIDs: [Int]) -> [IOHIDDevice] {
        guard isOpen, let manager, let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return devices.filter { productIDs.contains(Self.productID(of: $0)) }
    }

    /// The session for one device behind `device`: a receiver slot (1…6) or a direct link (0xFF).
    func session(for device: IOHIDDevice, index: UInt8) -> HIDPPSession {
        let key = SessionKey(device: ObjectIdentifier(device), index: index)
        if let session = sessions[key] { return session }
        let session = HIDPPSession(device: device, deviceIndex: index)
        sessions[key] = session
        return session
    }

    /// Finds the first paired device that `matches`, across every attached receiver with one of `productIDs`
    /// and the given slots, from the receivers' pairing records (which answer even while a device sleeps).
    func findPairedDevice(
        productIDs: [Int],
        slots: ClosedRange<UInt8>,
        matches: (HIDPPSession.PairedDevice) -> Bool
    ) async -> (session: HIDPPSession, paired: HIDPPSession.PairedDevice)? {
        for receiver in devices(productIDs: productIDs) {
            let family: HIDPPSession.ReceiverFamily =
                Self.productID(of: receiver) == HIDPPProtocol.boltReceiverProductID ? .bolt : .unifying
            for slot in slots {
                if Task.isCancelled { return nil }
                let session = session(for: receiver, index: slot)
                if notifyingReceivers.insert(ObjectIdentifier(receiver)).inserted {
                    await session.enableReceiverConnectionNotifications()
                }
                if let paired = await session.receiverPairedDevice(family: family), matches(paired) {
                    return (session, paired)
                }
            }
        }
        return nil
    }

    /// Opening without Input Monitoring would show a blocking permission prompt, so this waits until it's
    /// granted; connectors call it again when the popover opens.
    @discardableResult
    func openIfPermitted() -> Bool {
        guard let manager, !isOpen, InputMonitoringPermission.isGranted else { return isOpen }
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        isOpen = result == kIOReturnSuccess
        if !isOpen {
            dlog(String(format: "HID++ hub: IOHIDManagerOpen returned 0x%08x", result))
        }
        return isOpen
    }

    nonisolated static func productID(of device: IOHIDDevice) -> Int {
        IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
    }

    // MARK: Private

    private func start() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: HIDPPProtocol.logitechVendorID,
            kIOHIDDeviceUsagePageKey as String: 0xFF00
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let hub = Unmanaged<HIDPPHub>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hub.devicesChanged() }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let hub = Unmanaged<HIDPPHub>.fromOpaque(context).takeUnretainedValue()
            let removed = ObjectIdentifier(device)
            MainActor.assumeIsolated { hub.deviceRemoved(removed) }
        }, context)
        IOHIDManagerRegisterInputReportCallback(manager, { context, _, sender, _, reportID, report, length in
            guard let context, let sender, length > 0,
                  reportID == HIDPPProtocol.shortReportID || reportID == HIDPPProtocol.longReportID else { return }
            var bytes = Array(UnsafeBufferPointer(start: report, count: length))
            if bytes.first != UInt8(reportID) {
                bytes.insert(UInt8(reportID), at: 0)
            }
            let device = ObjectIdentifier(Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue())
            let hub = Unmanaged<HIDPPHub>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hub.deliver(bytes, from: device) }
        }, context)

        // The callbacks run on the main run loop, which is why they can assume main-actor isolation.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        self.manager = manager
        openIfPermitted()
    }

    /// Every session on the device sees the report: receiver register replies use index 0xFF whichever slot
    /// asked, and each session ignores what isn't its own.
    private func deliver(_ report: [UInt8], from device: ObjectIdentifier) {
        for (key, session) in sessions where key.device == device {
            session.handle(report: report)
        }
    }

    private func deviceRemoved(_ device: ObjectIdentifier) {
        sessions = sessions.filter { $0.key.device != device }
        notifyingReceivers.remove(device)
        devicesChanged()
    }

    /// Devices attach in bursts (every receiver at launch), so listeners run once after the burst.
    private func devicesChanged() {
        guard !isChangeScheduled else { return }
        isChangeScheduled = true
        Task { @MainActor in
            self.isChangeScheduled = false
            for listener in self.changeListeners { listener() }
        }
    }
}

// MARK: - Battery

extension HIDPPSession {
    struct BatteryFeature: Equatable {
        let index: UInt8
        let isUnified: Bool
    }

    /// Finds the device's battery feature: UnifiedBattery (0x1004), or the older BatteryStatus (0x1000).
    func batteryFeature() async -> BatteryFeature? {
        if let index = await featureIndex(for: HIDPPProtocol.featureUnifiedBattery) {
            return BatteryFeature(index: index, isUnified: true)
        }
        if let index = await featureIndex(for: HIDPPProtocol.featureBatteryStatus) {
            return BatteryFeature(index: index, isUnified: false)
        }
        return nil
    }

    /// Reads the current level: UnifiedBattery.getStatus is function 1, BatteryStatus's is function 0.
    func readBattery(_ feature: BatteryFeature) async -> HIDPPProtocol.BatteryReading? {
        guard let reply = await request(featureIndex: feature.index, function: feature.isUnified ? 0x01 : 0x00) else { return nil }
        return Self.batteryReading(from: reply, feature: feature)
    }

    /// Parses a battery reply, or one of the battery events the device pushes on its own (same layout).
    static func batteryReading(from report: [UInt8], feature: BatteryFeature) -> HIDPPProtocol.BatteryReading? {
        HIDPPProtocol.parseBatteryReply(report, expectedFeatureIndex: feature.index, isUnifiedBattery: feature.isUnified)
    }
}

// MARK: - HIDPPReceiverDevice

/// One accessory on a Logitech receiver, with everything every receiver accessory needs: finding it across
/// receivers and slots, naming it (the receiver's short name while it sleeps, its own full name when awake),
/// following it waking and sleeping, and its battery. Devices that also work over a USB cable (e.g. while
/// charging) leave the receiver and appear as their own USB device; while plugged in, that link is used instead.
/// A connector owns one of these and adds its device's own features through `onOnline` and `onEvent`.
/// Event-driven throughout: nothing is polled.
@Observable
@MainActor
final class HIDPPReceiverDevice {
    private(set) var deviceName: String?
    /// Answering right now; false while it sleeps (the receiver still knows it's paired).
    private(set) var isOnline = false
    private(set) var batteryPercent: Int?
    private(set) var isCharging = false
    private(set) var session: HIDPPSession?
    /// Connected by its USB cable rather than through a receiver.
    private(set) var isWired = false

    var isAvailable: Bool { deviceName != nil }

    /// Runs each time the device comes online (first found, and after every wake): load its features here.
    @ObservationIgnored var onOnline: ((HIDPPSession) async -> Void)?
    /// Events the device pushes that aren't battery or link changes.
    @ObservationIgnored var onEvent: (([UInt8]) -> Void)?
    /// The device went away (receiver unplugged or unpaired) or fell asleep: drop device-specific state.
    @ObservationIgnored var onOffline: (() -> Void)?

    @ObservationIgnored private let hub = HIDPPHub.shared
    @ObservationIgnored private let receiverIDs: [Int]
    @ObservationIgnored private let wiredProductIDs: [Int]
    @ObservationIgnored private let slots: ClosedRange<UInt8>
    @ObservationIgnored private let matches: (HIDPPSession.PairedDevice) -> Bool
    @ObservationIgnored private let alertID: String
    @ObservationIgnored private var identifyTask: Task<Void, Never>?
    @ObservationIgnored private var batteryFeature: HIDPPSession.BatteryFeature?

    /// - Parameters:
    ///   - productIDs: The receivers the device can be paired to.
    ///   - wiredProductIDs: The device's own product IDs when connected by USB cable.
    ///   - alertID: Identifies the device for low-battery alerts.
    ///   - matches: Picks this connector's device from a receiver's pairing records (kind and short name).
    init(
        productIDs: [Int], wiredProductIDs: [Int] = [], slots: ClosedRange<UInt8>, alertID: String,
        matches: @escaping (HIDPPSession.PairedDevice) -> Bool
    ) {
        self.receiverIDs = productIDs
        self.wiredProductIDs = wiredProductIDs
        self.slots = slots
        self.alertID = alertID
        self.matches = matches
    }

    func start() {
        hub.watch { [weak self] in self?.refresh() }
        refresh()
    }

    /// Picks up an Input Monitoring grant, then finds and identifies the device again.
    func popoverWillShow() {
        if hub.isOpen || hub.openIfPermitted() {
            refresh()
        }
    }

    /// Finds the device (cable first, then every receiver) and identifies it. A newer refresh replaces an older one.
    func refresh() {
        identifyTask?.cancel()
        identifyTask = Task { [weak self] in
            guard let self else { return }
            // Plugged in by cable: the device answers directly, as HID++ device index 0xFF.
            if let cable = self.hub.devices(productIDs: self.wiredProductIDs).first {
                await self.connect(self.hub.session(for: cable, index: 0xFF), wired: true)
                return
            }
            let found = await self.hub.findPairedDevice(productIDs: self.receiverIDs, slots: self.slots, matches: self.matches)
            guard !Task.isCancelled else { return }
            guard let found else {
                self.clear()
                return
            }
            if self.deviceName == nil {
                self.deviceName = found.paired.name
            }
            await self.connect(found.session, wired: false)
        }
    }

    /// Awake, the device answers with its full name and battery. Feature indices are per device and per link,
    /// so never reuse ones learned before.
    private func connect(_ session: HIDPPSession, wired: Bool) async {
        guard !Task.isCancelled else { return }
        if self.session !== session {
            // Only the current link's events count: a receiver reporting the link down once the cable is plugged
            // in must not reset the cable connection.
            self.session?.onEvent = nil
            if isOnline { goOffline() }
            self.session = session
        }
        session.onEvent = { [weak self] event in self?.handle(event: event) }
        isWired = wired
        session.reset()
        guard let identity = await session.identify(), !Task.isCancelled else {
            if !Task.isCancelled { goOffline() }
            return
        }
        isOnline = true
        deviceName = identity.name
        batteryFeature = await session.batteryFeature()
        if let feature = batteryFeature, let reading = await session.readBattery(feature) {
            apply(reading)
        }
        guard !Task.isCancelled else { return }
        await onOnline?(session)
    }

    private func handle(event: [UInt8]) {
        // HID++ 1.0 device-connection notification from the receiver: byte 4 bit 6 set means the link is down.
        if event[2] == 0x41 {
            if event[4] & 0x40 != 0 {
                goOffline()
            } else {
                refresh()
            }
            return
        }
        if let feature = batteryFeature, let reading = HIDPPSession.batteryReading(from: event, feature: feature) {
            apply(reading)
            return
        }
        onEvent?(event)
    }

    private func apply(_ reading: HIDPPProtocol.BatteryReading) {
        if batteryPercent != reading.percentage { batteryPercent = reading.percentage }
        if isCharging != reading.isCharging { isCharging = reading.isCharging }
        AccessoryBatteryAlerts.shared.report(id: alertID, name: deviceName ?? "", percent: batteryPercent, isCharging: isCharging)
    }

    private func goOffline() {
        guard isOnline || batteryFeature != nil else { return }
        isOnline = false
        batteryFeature = nil
        onOffline?()
    }

    private func clear() {
        session?.onEvent = nil
        session = nil
        isWired = false
        batteryFeature = nil
        deviceName = nil
        isOnline = false
        batteryPercent = nil
        isCharging = false
        onOffline?()
    }
}
