import Foundation
import IOKit
import SystemConfiguration

// MARK: - DockModel

/// A Thunderbolt 4 dock or hub built on Intel's Thunderbolt controller (JHL8440), and where its ports are.
///
/// The controller has its own USB 2 and USB 3 hubs. Their ports 1–3 are the downstream Thunderbolt ports, so a
/// USB-C device's hub port tells which Thunderbolt port it's in. The dock maker uses the controller's other
/// ports for the rest: USB-A ports, its own hub, an Ethernet adapter or a firmware device.
nonisolated struct DockModel: Equatable {
    /// Where the USB-A ports are.
    enum USBAPlacement: Equatable {
        /// Directly on the controller's hubs: controller hub port → USB-A number.
        case controllerPorts([Int: Int])
        /// Ports 1… of the dock's own hubs (these product IDs), which sit on the controller's hubs.
        case dockHubs(productIDs: Set<Int>)
    }

    let vendorID: Int
    /// A USB device inside the dock that identifies it; the controller's hubs are found above it.
    let anchorProductID: Int
    /// The dock's Thunderbolt switch reports the vendor ID and this model ID.
    let switchModelID: Int
    var thunderboltPortCount = 3
    let usbAPortCount: Int
    let usbAPlacement: USBAPlacement
    let hasEthernet: Bool

    /// Razer Thunderbolt 4 Dock Chroma: 3 Thunderbolt, 4 USB-A on Razer's hubs, Gigabit Ethernet.
    static let razerThunderbolt4 = DockModel(
        vendorID: 0x1532, anchorProductID: 0x0F2F,
        switchModelID: 0x122E, usbAPortCount: 4,
        usbAPlacement: .dockHubs(productIDs: [0x0F2F, 0x0F30]),
        hasEthernet: true
    )

    /// Satechi Thunderbolt 4 Slim Hub Pro (ST-HT4SHM): 3 Thunderbolt and 1 USB-A on controller port 4. Its
    /// anchor is the hub's billboard and firmware device, on controller port 5.
    static let satechiSlimHubPro = DockModel(
        vendorID: 0x310E, anchorProductID: 0x0952, switchModelID: 0x0952, usbAPortCount: 1,
        usbAPlacement: .controllerPorts([4: 1]), hasEthernet: false
    )
}

// MARK: - DockTopology

/// What's plugged into a dock, worked out from the IORegistry.
enum DockTopology {
    nonisolated static let hubClass = 0x09
    /// USB-C alternate-mode announcement devices. On a Thunderbolt port one means a display cable or adapter.
    nonisolated static let billboardClass = 0x11

    /// One USB device as read from the IORegistry.
    nonisolated struct USBNode: Equatable {
        let id: UInt64
        /// The hub it's attached to; nil on a root port.
        let parentID: UInt64?
        let locationID: UInt32
        let vendorID: Int
        let productID: Int
        let name: String
        let vendorName: String?
        let deviceClass: Int
        /// IOKit's "Device Speed": 0 low, 1 full, 2 high, 3 SuperSpeed, 4 SuperSpeed+ 10 Gb/s, 5 20 Gb/s.
        let speed: Int?
        /// The network interface the device provides, e.g. "en7".
        var networkInterface: String?
        var serialNumber: String?
    }

    /// One Thunderbolt switch (a dock, display or drive) as read from the IORegistry.
    nonisolated struct ThunderboltNode: Equatable {
        let id: UInt64
        /// The switch it's plugged into; nil for the Mac's own.
        let parentSwitchID: UInt64?
        let vendorID: Int?
        let modelID: Int?
        let vendorName: String?
        let modelName: String?
    }

    nonisolated struct AttachedDevice: Identifiable, Equatable {
        let id: UInt64
        let name: String
        let detail: String
        let systemImage: String
        /// A hub with nothing on it; dropped when the same port has real devices.
        var isEmptyHub = false
    }

    nonisolated struct Port: Identifiable, Equatable {
        enum Kind { case thunderbolt, usbA }

        let kind: Kind
        let number: Int
        var devices: [AttachedDevice]

        var id: String { "\(kind)-\(number)" }

        var title: String {
            switch kind {
            case .thunderbolt: return "Thunderbolt \(number)"
            case .usbA: return "USB-A \(number)"
            }
        }
    }

    nonisolated struct Layout: Equatable {
        /// The dock is connected.
        var isPresent = false
        var thunderbolt: [Port]
        var usbA: [Port]
        /// The built-in Ethernet adapter's interface, e.g. "en7".
        var ethernetInterface: String?
        /// The serial number of the dock's identifying USB device, if it has one.
        var serialNumber: String?

        /// Every port, empty.
        init(model: DockModel) {
            thunderbolt = (0..<model.thunderboltPortCount).map { Port(kind: .thunderbolt, number: $0 + 1, devices: []) }
            usbA = (0..<model.usbAPortCount).map { Port(kind: .usbA, number: $0 + 1, devices: []) }
        }
    }

    // MARK: Building the Layout

    nonisolated static func layout(model: DockModel, usb: [USBNode], thunderbolt: [ThunderboltNode]) -> Layout {
        var layout = Layout(model: model)
        guard let anchor = usb.first(where: { $0.vendorID == model.vendorID && $0.productID == model.anchorProductID }) else {
            return layout
        }
        layout.isPresent = true
        layout.serialNumber = anchor.serialNumber

        let byID = Dictionary(usb.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let children = Dictionary(grouping: usb, by: \.parentID)

        // The controller's USB 2 hub is the root of the anchor's tree; its USB 3 twin is the other root hub on
        // the same bus (the bus is the top byte of a location ID).
        var root = anchor
        while let parentID = root.parentID, let parent = byID[parentID] { root = parent }
        let bus = root.locationID >> 24
        let controllerHubs = usb.filter { $0.parentID == nil && $0.deviceClass == hubClass && $0.locationID >> 24 == bus }

        let thunderboltPorts = 1...model.thunderboltPortCount
        var thunderboltDevices: [Int: [AttachedDevice]] = [:]
        var usbADevices: [Int: [AttachedDevice]] = [:]
        for hub in controllerHubs {
            for child in children[hub.id] ?? [] {
                let port = portNumber(of: child.locationID, under: hub.locationID)
                if thunderboltPorts.contains(port) {
                    thunderboltDevices[port, default: []] += child.deviceClass == billboardClass
                        ? [displayAdapter(child)]
                        : attachedDevices(from: child, children: children)
                    continue
                }
                switch model.usbAPlacement {
                case .controllerPorts(let numbers):
                    if let number = numbers[port] {
                        usbADevices[number, default: []] += attachedDevices(from: child, children: children)
                        continue
                    }
                case .dockHubs(let productIDs):
                    if child.vendorID == model.vendorID && productIDs.contains(child.productID) {
                        for device in children[child.id] ?? [] {
                            let dockPort = portNumber(of: device.locationID, under: child.locationID)
                            if (1...model.usbAPortCount).contains(dockPort) {
                                usbADevices[dockPort, default: []] += attachedDevices(from: device, children: children)
                            } else if device.vendorID != model.vendorID, let interface = device.networkInterface {
                                layout.ethernetInterface = interface
                            }
                        }
                        continue
                    }
                }
                // Something built into the dock.
                if model.hasEthernet, child.vendorID != model.vendorID, let interface = child.networkInterface {
                    layout.ethernetInterface = interface
                }
            }
        }

        // Thunderbolt devices directly behind the dock's switch (daisy-chained ones belong to them). Which port
        // they're in can't be told, so they take the free Thunderbolt ports in order.
        let dockSwitch = thunderbolt.first { $0.vendorID == model.vendorID && $0.modelID == model.switchModelID }
        var chained = thunderbolt.filter { dockSwitch != nil && $0.parentSwitchID == dockSwitch?.id }.map { node in
            AttachedDevice(id: node.id, name: thunderboltName(node), detail: "Thunderbolt",
                           systemImage: systemImage(forName: node.modelName ?? "", deviceClass: nil, fallback: "bolt.horizontal"))
        }
        for port in thunderboltPorts where thunderboltDevices[port] == nil && !chained.isEmpty {
            thunderboltDevices[port] = [chained.removeFirst()]
        }

        layout.thunderbolt = thunderboltPorts.map { Port(kind: .thunderbolt, number: $0, devices: merged(thunderboltDevices[$0] ?? [])) }
        layout.usbA = layout.usbA.map { Port(kind: .usbA, number: $0.number, devices: merged(usbADevices[$0.number] ?? [])) }
        return layout
    }

    /// The hub port a device is on. A location ID holds one hex digit per tier below the bus byte, so the
    /// child's digit at the first tier the hub leaves empty is its port.
    nonisolated static func portNumber(of child: UInt32, under hub: UInt32) -> Int {
        for shift in stride(from: 20, through: 0, by: -4) where (hub >> shift) & 0xF == 0 {
            return Int((child >> shift) & 0xF)
        }
        return 0
    }

    /// A billboard straight on a Thunderbolt port: a USB-C display cable or adapter running in DisplayPort mode.
    private nonisolated static func displayAdapter(_ node: USBNode) -> AttachedDevice {
        let vendor = node.vendorName?.split(separator: " ").first.map(String.init)
        return AttachedDevice(id: node.id, name: "USB-C Display Adapter",
                              detail: vendor.map { "Alternate mode · \($0)" } ?? "Alternate mode", systemImage: "display")
    }

    private nonisolated static func isBillboard(_ node: USBNode) -> Bool {
        node.deviceClass == billboardClass || node.name.lowercased().contains("billboard")
    }

    /// A device as listed under its port. A hub is replaced by the devices behind it, leaving out the billboard
    /// devices hubs in monitors carry.
    private nonisolated static func attachedDevices(from node: USBNode, children: [UInt64?: [USBNode]]) -> [AttachedDevice] {
        guard node.deviceClass == hubClass else {
            return [AttachedDevice(id: node.id, name: displayName(node), detail: speedTitle(node.speed) ?? "USB",
                                   systemImage: systemImage(forName: node.name, deviceClass: node.deviceClass))]
        }
        let leaves = descendants(of: node, children: children).filter { $0.deviceClass != hubClass && !isBillboard($0) }
        guard !leaves.isEmpty else {
            return [AttachedDevice(id: node.id, name: displayName(node), detail: "Hub with nothing connected",
                                   systemImage: "rectangle.connected.to.line.below", isEmptyHub: true)]
        }
        return leaves.map { leaf in
            let speed = speedTitle(leaf.speed).map { "\($0) · " } ?? ""
            return AttachedDevice(id: leaf.id, name: displayName(leaf), detail: "\(speed)Through \(node.name)",
                                  systemImage: systemImage(forName: leaf.name, deviceClass: leaf.deviceClass))
        }
    }

    private nonisolated static func descendants(of node: USBNode, children: [UInt64?: [USBNode]]) -> [USBNode] {
        (children[node.id] ?? []).sorted { $0.locationID < $1.locationID }.flatMap { [$0] + descendants(of: $0, children: children) }
    }

    /// A USB 3 hub shows up on both the USB 2 and USB 3 trees; only list it empty if nothing is behind either.
    private nonisolated static func merged(_ devices: [AttachedDevice]) -> [AttachedDevice] {
        let real = devices.filter { !$0.isEmptyHub }
        return real.isEmpty ? Array(devices.prefix(1)) : real
    }

    /// The product name, led by the vendor's name when the product doesn't say it (e.g. "Logitech USB Receiver").
    nonisolated static func displayName(_ node: USBNode) -> String {
        guard let vendor = node.vendorName?.split(separator: " ").first.map(String.init),
              vendor.lowercased() != "generic",
              !node.name.lowercased().contains(vendor.lowercased()) else { return node.name }
        return "\(vendor) \(node.name)"
    }

    private nonisolated static func thunderboltName(_ node: ThunderboltNode) -> String {
        let name = [node.vendorName, node.modelName].compactMap { $0 }.joined(separator: " ")
        return name.isEmpty ? "Thunderbolt Device" : name
    }

    nonisolated static func speedTitle(_ speed: Int?) -> String? {
        switch speed {
        case 0: return "1.5 Mb/s"
        case 1: return "12 Mb/s"
        case 2: return "480 Mb/s"
        case 3: return "5 Gb/s"
        case 4: return "10 Gb/s"
        case 5: return "20 Gb/s"
        default: return nil
        }
    }

    /// A symbol from the product name, or its USB class when the name doesn't say.
    nonisolated static func systemImage(forName name: String, deviceClass: Int?, fallback: String = "cable.connector") -> String {
        let lower = name.lowercased()
        let keywords: [(words: [String], symbol: String)] = [
            (["controller", "xbox", "gamepad", "joystick"], "gamecontroller"),
            (["headset", "headphone"], "headphones"),
            (["mic"], "mic"),
            (["camera", "webcam"], "web.camera"),
            (["keyboard"], "keyboard"),
            (["mouse"], "computermouse"),
            (["receiver", "dongle", "bluetooth", "link"], "dot.radiowaves.left.and.right"),
            (["monitor", "display"], "display"),
            (["light"], "lightbulb.led"),
            (["audio", "speaker", "dac"], "hifispeaker"),
            (["disk", "drive", "ssd", "flash", "storage", "card"], "externaldrive"),
            (["hub"], "rectangle.connected.to.line.below"),
        ]
        if let match = keywords.first(where: { $0.words.contains(where: lower.contains) }) {
            return match.symbol
        }
        switch deviceClass {
        case 0x01: return "hifispeaker"
        case 0x08: return "externaldrive"
        case 0x0E: return "web.camera"
        default: return fallback
        }
    }

    // MARK: Reading the IORegistry

    nonisolated static func scanUSB() -> [USBNode] {
        services(matching: "IOUSBHostDevice").map { service in
            defer { IOObjectRelease(service) }
            let deviceClass: Int = property(service, "bDeviceClass") ?? 0
            var parentID: UInt64?
            var parent: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(service, "IOUSB", &parent) == KERN_SUCCESS {
                if IOObjectConformsTo(parent, "IOUSBHostDevice") != 0 { parentID = entryID(parent) }
                IOObjectRelease(parent)
            }
            // Hubs would find their downstream devices' interfaces, so only devices are searched.
            let interface = deviceClass == hubClass ? nil : IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, "BSD Name" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)
            ) as? String
            return USBNode(
                id: entryID(service),
                parentID: parentID,
                locationID: property(service, "locationID") ?? 0,
                vendorID: property(service, "idVendor") ?? 0,
                productID: property(service, "idProduct") ?? 0,
                name: property(service, "USB Product Name") ?? property(service, "kUSBProductString") ?? "USB Device",
                vendorName: property(service, "USB Vendor Name"),
                deviceClass: deviceClass,
                speed: property(service, "Device Speed"),
                networkInterface: interface.flatMap { $0.hasPrefix("en") ? $0 : nil },
                serialNumber: property(service, "kUSBSerialNumberString")
            )
        }
    }

    nonisolated static func scanThunderbolt() -> [ThunderboltNode] {
        services(matching: "IOThunderboltSwitch").map { service in
            defer { IOObjectRelease(service) }
            return ThunderboltNode(
                id: entryID(service),
                parentSwitchID: parentSwitchID(of: service),
                vendorID: property(service, "Device Vendor ID"),
                modelID: property(service, "Device Model ID"),
                vendorName: property(service, "Device Vendor Name"),
                modelName: property(service, "Device Model Name")
            )
        }
    }

    /// Switches hang off ports of the switch above them, a few levels up the service plane.
    private nonisolated static func parentSwitchID(of service: io_registry_entry_t) -> UInt64? {
        var entry = service
        IOObjectRetain(entry)
        defer { IOObjectRelease(entry) }
        for _ in 0..<8 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(entry)
            entry = parent
            if IOObjectConformsTo(entry, "IOThunderboltSwitch") != 0 { return entryID(entry) }
        }
        return nil
    }

    /// Matching services; the caller releases each.
    private nonisolated static func services(matching className: String) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            result.append(service)
        }
        return result
    }

    private nonisolated static func entryID(_ entry: io_registry_entry_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        return id
    }

    private nonisolated static func property<T>(_ entry: io_registry_entry_t, _ key: String) -> T? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? T
    }
}

// MARK: - DockPortMonitor

/// Follows what's plugged into one dock. USB and Thunderbolt attach and detach notifications trigger a rescan,
/// and the Ethernet link state comes from the System Configuration store. Nothing is polled.
@Observable
@MainActor
final class DockPortMonitor {
    let model: DockModel
    private(set) var layout: DockTopology.Layout
    /// A cable with a live link is in the Ethernet port; nil while the adapter isn't known.
    private(set) var isEthernetLinkActive: Bool?

    @ObservationIgnored private var notificationPort: IONotificationPortRef?
    @ObservationIgnored private var iterators: [io_iterator_t] = []
    @ObservationIgnored private var store: SCDynamicStore?
    @ObservationIgnored private var rescanTask: Task<Void, Never>?

    init(model: DockModel) {
        self.model = model
        layout = DockTopology.Layout(model: model)
    }

    func start() {
        guard notificationPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, .main)
        notificationPort = port
        let context = Unmanaged.passUnretained(self).toOpaque()
        for className in ["IOUSBHostDevice", "IOThunderboltSwitch"] {
            for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var iterator: io_iterator_t = 0
                let result = IOServiceAddMatchingNotification(port, type, IOServiceMatching(className), { context, iterator in
                    DockPortMonitor.drain(iterator)
                    guard let context else { return }
                    let monitor = Unmanaged<DockPortMonitor>.fromOpaque(context).takeUnretainedValue()
                    // Delivered on the main queue, set above.
                    MainActor.assumeIsolated { monitor.scheduleRescan() }
                }, context, &iterator)
                guard result == KERN_SUCCESS else { continue }
                // Draining arms the notification.
                Self.drain(iterator)
                iterators.append(iterator)
            }
        }

        if model.hasEthernet {
            var storeContext = SCDynamicStoreContext(version: 0, info: context, retain: nil, release: nil, copyDescription: nil)
            store = SCDynamicStoreCreate(nil, "AeronTools.Dock" as CFString, { _, _, info in
                guard let info else { return }
                let monitor = Unmanaged<DockPortMonitor>.fromOpaque(info).takeUnretainedValue()
                MainActor.assumeIsolated { monitor.readEthernetLink() }
            }, &storeContext)
            if let store { SCDynamicStoreSetDispatchQueue(store, .main) }
        }

        scheduleRescan()
    }

    /// A rescan, e.g. after the Mac wakes.
    func refresh() {
        scheduleRescan()
    }

    private nonisolated static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }

    /// Plugging in a hub brings a burst of notifications; they're collected into one scan, run off the main actor.
    private func scheduleRescan() {
        rescanTask?.cancel()
        let model = model
        rescanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let layout = await Task.detached(priority: .utility) {
                DockTopology.layout(model: model, usb: DockTopology.scanUSB(), thunderbolt: DockTopology.scanThunderbolt())
            }.value
            guard let self, !Task.isCancelled else { return }
            let interfaceChanged = layout.ethernetInterface != self.layout.ethernetInterface
            if layout != self.layout { self.layout = layout }
            if interfaceChanged { watchEthernet() }
        }
    }

    private func linkKey(_ interface: String) -> String {
        "State:/Network/Interface/\(interface)/Link"
    }

    private func watchEthernet() {
        guard let store else { return }
        let keys = layout.ethernetInterface.map { [linkKey($0)] } ?? []
        SCDynamicStoreSetNotificationKeys(store, keys as CFArray, nil)
        readEthernetLink()
    }

    private func readEthernetLink() {
        guard let store, let interface = layout.ethernetInterface else {
            isEthernetLinkActive = nil
            return
        }
        let link = SCDynamicStoreCopyValue(store, linkKey(interface) as CFString) as? [String: Any]
        isEthernetLinkActive = link?["Active"] as? Bool ?? false
    }
}
