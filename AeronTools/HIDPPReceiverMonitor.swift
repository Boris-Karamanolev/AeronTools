import Foundation
import IOKit.hid

// MARK: - HIDPPReceiverMonitor

/// Watches the HID++ interface of Logitech receivers (vendor usage page 0xFF00) and delivers their reports.
/// Shared by every receiver-based connector: attach/detach and reports arrive as callbacks on the main run
/// loop, and only the HID++ collection is matched, so pointer movement and key presses never reach the app.
@MainActor
final class HIDPPReceiverMonitor {
    private let productIDs: [Int]
    private var manager: IOHIDManager?
    private(set) var isOpen = false

    /// A matching receiver was attached or removed.
    var onReceiversChanged: (() -> Void)?
    /// A HID++ report from a receiver, with its report ID as the first byte.
    var onReport: (([UInt8], IOHIDDevice) -> Void)?

    init(productIDs: [Int]) {
        self.productIDs = productIDs
    }

    /// The attached receivers, once opened.
    var receivers: [IOHIDDevice] {
        guard isOpen, let manager, let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return Array(devices)
    }

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = productIDs.map { productID in
            [
                kIOHIDVendorIDKey as String: HIDPPProtocol.logitechVendorID,
                kIOHIDProductIDKey as String: productID,
                kIOHIDDeviceUsagePageKey as String: 0xFF00
            ]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let monitor = Unmanaged<HIDPPReceiverMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.onReceiversChanged?() }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let monitor = Unmanaged<HIDPPReceiverMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.onReceiversChanged?() }
        }, context)
        IOHIDManagerRegisterInputReportCallback(manager, { context, _, sender, _, reportID, report, length in
            guard let context, let sender, length > 0,
                  reportID == HIDPPProtocol.shortReportID || reportID == HIDPPProtocol.longReportID else { return }
            var bytes = Array(UnsafeBufferPointer(start: report, count: length))
            if bytes.first != UInt8(reportID) {
                bytes.insert(UInt8(reportID), at: 0)
            }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            let monitor = Unmanaged<HIDPPReceiverMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                #if DEBUG
                HIDPPTrace.record(bytes)
                #endif
                monitor.onReport?(bytes, device)
            }
        }, context)

        // The callbacks run on the main run loop, which is why they can assume main-actor isolation.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        self.manager = manager
        openIfPermitted()
    }

    /// Opening without Input Monitoring would show a blocking permission prompt, so this waits until it's
    /// granted; connectors call it again when the popover opens or the app becomes active.
    @discardableResult
    func openIfPermitted() -> Bool {
        guard let manager, !isOpen, InputMonitoringPermission.isGranted else { return isOpen }
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        isOpen = result == kIOReturnSuccess
        if !isOpen {
            dlog(String(format: "HID++ receiver monitor: IOHIDManagerOpen returned 0x%08x", result))
        }
        return isOpen
    }

    nonisolated static func productID(of device: IOHIDDevice) -> Int {
        IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
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
