import SwiftUI
import IOKit.hid
import CoreBluetooth

// MARK: - KeychronM3MiniConnector

/// The Keychron M3 Mini 4K (aluminium), on its 4K Link receiver, its USB cable, or Bluetooth.
///
/// Receiver and cable: battery, charging and settings over Keychron's 4K protocol (`KeychronMouseProtocol`).
/// Settings are written to the mouse and saved there, so it keeps them without the app. Bluetooth doesn't carry
/// that protocol, so there only the battery level is read, from the standard GATT battery service.
///
/// Event-driven: device attach/detach from IOHIDManager; the receiver reports the mouse joining or leaving it;
/// the mouse reports DPI button presses and charging on its own; the Bluetooth battery level is a notification.
@Observable
@MainActor
final class KeychronM3MiniConnector {
    static let shared = KeychronM3MiniConnector()

    private static let name = "Keychron M3 Mini 4K"
    private static let replyTimeout: Duration = .seconds(1)

    /// The receiver says the mouse is linked to it (and it's this model, as far as it's known).
    private(set) var isOnReceiver = false
    private(set) var isOnCable = false
    private(set) var isOnBluetooth = false
    /// The mouse answered its last request (or reported something since).
    private(set) var isAwake = false
    private(set) var batteryPercent: Int?
    private(set) var isCharging = false
    /// The settings block as last read from the mouse, with the app's pending changes applied.
    private(set) var settings: KeychronMouseProtocol.Settings?
    /// The fastest report rate the current link allows: 4 kHz on the receiver, 1 kHz on the cable.
    private(set) var maxReportRateHz: Int?
    /// Each side button's action, from what the mouse has stored; a nil action is something the app doesn't
    /// offer (e.g. set in Keychron Launcher). Nil until read.
    private(set) var sideButtons: [KeychronMouseProtocol.SideButton: AccessoryButtonAction?]?

    /// The receiver and cable vendor interfaces, opened to talk to the mouse.
    @ObservationIgnored private var manager: IOHIDManager?
    @ObservationIgnored private var isOpen = false
    /// The mouse's Bluetooth HID device, watched for attach and detach only and never opened.
    @ObservationIgnored private var bluetoothWatcher: IOHIDManager?
    @ObservationIgnored private let bluetoothBattery = KeychronBluetoothBattery()

    @ObservationIgnored private var receiver: IOHIDDevice?
    @ObservationIgnored private var cable: IOHIDDevice?
    /// The model behind the receiver, once it has answered the version request.
    @ObservationIgnored private var receiverModelID: UInt16?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    private struct Waiter {
        let device: IOHIDDevice
        let packet: [UInt8]
        let continuation: CheckedContinuation<[UInt8]?, Never>
    }
    @ObservationIgnored private var waiter: Waiter?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var queueTail: Task<Void, Never>?

    /// The newest settings waiting to be written; rapid changes collapse into them.
    @ObservationIgnored private var pendingSettings: KeychronMouseProtocol.Settings?
    @ObservationIgnored private var isWriting = false

    private init() {}

    /// Where requests for the mouse go: straight to it on the cable, or routed through the receiver.
    private var target: (device: IOHIDDevice, routed: Bool)? {
        if let cable { return (cable, false) }
        if let receiver, isOnReceiver { return (receiver, true) }
        return nil
    }

    /// Settings can be read and written (receiver or cable, not Bluetooth).
    var canConfigure: Bool { target != nil && settings != nil }

    // MARK: Devices

    fileprivate func setUp() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = [KeychronMouseProtocol.receiverProductID, KeychronMouseProtocol.m3MiniProductID].map { productID in
            [
                kIOHIDVendorIDKey: KeychronMouseProtocol.vendorID,
                kIOHIDProductIDKey: productID,
                kIOHIDDeviceUsagePageKey: KeychronMouseProtocol.usagePage,
                kIOHIDDeviceUsageKey: KeychronMouseProtocol.usage,
            ] as [String: Any]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let connector = Unmanaged<KeychronM3MiniConnector>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { connector.attached(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let connector = Unmanaged<KeychronM3MiniConnector>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { connector.removed(device) }
        }, context)
        IOHIDManagerRegisterInputReportCallback(manager, { context, _, sender, _, _, report, length in
            guard let context, let sender, length > 3 else { return }
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            let connector = Unmanaged<KeychronM3MiniConnector>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { connector.handle(report: bytes, from: device) }
        }, context)
        // The callbacks run on the main run loop, which is why they can assume main-actor isolation.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        self.manager = manager
        openIfPermitted()

        // Matching works without opening, so the Bluetooth mouse is only noticed, never opened.
        let watcher = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(watcher, [
            kIOHIDVendorIDKey: KeychronMouseProtocol.vendorID,
            kIOHIDProductIDKey: KeychronMouseProtocol.m3MiniProductID,
            kIOHIDTransportKey: "Bluetooth Low Energy",
        ] as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(watcher, { context, _, _, device in
            guard let context else { return }
            let connector = Unmanaged<KeychronM3MiniConnector>.fromOpaque(context).takeUnretainedValue()
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
            MainActor.assumeIsolated { connector.bluetoothChanged(attachedName: name) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(watcher, { context, _, _, _ in
            guard let context else { return }
            let connector = Unmanaged<KeychronM3MiniConnector>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { connector.bluetoothChanged(attachedName: nil) }
        }, context)
        IOHIDManagerScheduleWithRunLoop(watcher, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        bluetoothWatcher = watcher

        bluetoothBattery.onChange = { [weak self] in self?.bluetoothBatteryChanged() }
    }

    /// Opening without Input Monitoring could show a blocking permission prompt, so this waits until it's
    /// granted, like the HID++ connectors; it's tried again when the popover opens.
    private func openIfPermitted() {
        guard let manager, !isOpen, InputMonitoringPermission.isGranted else { return }
        isOpen = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
    }

    private func attached(_ device: IOHIDDevice) {
        if HIDPPHub.productID(of: device) == KeychronMouseProtocol.receiverProductID {
            receiver = device
            receiverModelID = nil
        } else {
            cable = device
            isOnCable = true
        }
        refresh()
    }

    private func removed(_ device: IOHIDDevice) {
        if device == receiver {
            receiver = nil
            isOnReceiver = false
        } else if device == cable {
            cable = nil
            isOnCable = false
        }
        if waiter?.device == device {
            finish(with: nil)
        }
        if target == nil {
            linkLost()
        } else {
            refresh()
        }
    }

    /// The mouse can no longer be reached over the receiver or cable.
    private func linkLost() {
        refreshTask?.cancel()
        settings = nil
        pendingSettings = nil
        maxReportRateHz = nil
        sideButtons = nil
        isAwake = isOnBluetooth
        if isOnBluetooth {
            bluetoothBatteryChanged()
        } else {
            batteryPercent = nil
            isCharging = false
        }
    }

    private func bluetoothChanged(attachedName name: String?) {
        isOnBluetooth = name != nil
        if let name {
            bluetoothBattery.start(peripheralName: name)
            if target == nil { isAwake = true }
        } else {
            bluetoothBattery.stop()
            if target == nil { linkLost() }
        }
    }

    /// Over Bluetooth the battery level is all there is, and charging can't be told.
    private func bluetoothBatteryChanged() {
        guard target == nil else { return }
        batteryPercent = bluetoothBattery.percent
        isCharging = false
        reportBattery()
    }

    // MARK: Reading

    /// Asks the receiver whether the mouse is linked, then reads the mouse's power and settings. Runs on attach,
    /// link changes, wake and when the popover opens.
    private func refresh() {
        guard isOpen else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            if cable == nil, let receiver {
                // The receiver answers this itself, whether or not the mouse is awake.
                if let reply = await request(.power, on: receiver, routed: false) {
                    receiverLinkChanged(isLinked: reply[4] == KeychronMouseProtocol.linkedState, refreshing: false)
                }
                guard isOnReceiver, !Task.isCancelled else { return }
                if receiverModelID == nil,
                   let version = await request(.version, on: receiver, routed: true),
                   let model = KeychronMouseProtocol.modelID(fromVersion: version) {
                    receiverModelID = model
                    // Another Keychron 4K mouse on the same kind of receiver belongs to no one here.
                    guard model == KeychronMouseProtocol.m3MiniModelID else {
                        receiverLinkChanged(isLinked: false, refreshing: false)
                        return
                    }
                }
            }
            await loadMouse()
        }
    }

    private func loadMouse() async {
        guard let target, !Task.isCancelled else { return }
        guard let reply = await request(.power, on: target.device, routed: target.routed),
              let power = KeychronMouseProtocol.Power(reply) else {
            isAwake = false
            return
        }
        apply(power)
        if pendingSettings == nil, !isWriting,
           let reply = await request(.readSettings, on: target.device, routed: target.routed),
           let read = KeychronMouseProtocol.Settings(reply),
           pendingSettings == nil, !isWriting {
            settings = read
        }
        await loadSideButtons(from: target)
    }

    /// Reads the side buttons and keeps them in step with the app: a factory-fresh button gets its default
    /// (⌘[ or ⌘]), and a button still holding what the app wrote is rewritten if that action's shortcut has
    /// changed on this Mac since. A button changed elsewhere is left alone and the app's choice forgotten.
    private func loadSideButtons(from target: (device: IOHIDDevice, routed: Bool)) async {
        guard let reply = await request(.readButtons, on: target.device, routed: target.routed) else { return }
        var buttons: [KeychronMouseProtocol.SideButton: AccessoryButtonAction?] = [:]
        for button in KeychronMouseProtocol.SideButton.allCases {
            guard let entry = KeychronMouseProtocol.assignment(of: button, inButtonMap: reply) else { continue }
            let saved = savedSideButton(button)
            if let saved, entry == saved.written {
                if let expected = KeychronMouseProtocol.assignment(for: saved.action, on: button), expected != entry {
                    await writeSideButton(button, action: saved.action, assignment: expected, to: target)
                }
                buttons[button] = saved.action
            } else if saved == nil, entry == button.factoryAssignment,
                      let assignment = KeychronMouseProtocol.assignment(for: button.defaultAction, on: button),
                      await writeSideButton(button, action: button.defaultAction, assignment: assignment, to: target) {
                buttons[button] = button.defaultAction
            } else {
                if saved != nil { UserDefaults.standard.removeObject(forKey: Self.sideButtonKey(button)) }
                buttons[button] = KeychronMouseProtocol.action(for: entry, on: button)
            }
        }
        sideButtons = buttons
    }

    /// Writes one button's entry and saves it on the mouse, remembering what was written and why.
    @discardableResult
    private func writeSideButton(
        _ button: KeychronMouseProtocol.SideButton,
        action: AccessoryButtonAction,
        assignment: [UInt8],
        to target: (device: IOHIDDevice, routed: Bool)
    ) async -> Bool {
        let payload = [UInt8(button.rawValue)] + assignment
        guard await request(.writeButton, payload: payload[...], on: target.device, routed: target.routed) != nil else {
            return false
        }
        _ = await request(.save, on: target.device, routed: target.routed)
        let saved = SavedSideButton(action: action, written: assignment)
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: Self.sideButtonKey(button))
        return true
    }

    /// The action the app last set on a button, and the entry it wrote for it.
    private struct SavedSideButton: Codable, Equatable {
        let action: AccessoryButtonAction
        let written: [UInt8]
    }

    private static func sideButtonKey(_ button: KeychronMouseProtocol.SideButton) -> String {
        "keychron.m3mini.sideButton.\(button.rawValue)"
    }

    private func savedSideButton(_ button: KeychronMouseProtocol.SideButton) -> SavedSideButton? {
        UserDefaults.standard.data(forKey: Self.sideButtonKey(button))
            .flatMap { try? JSONDecoder().decode(SavedSideButton.self, from: $0) }
    }

    private func receiverLinkChanged(isLinked: Bool, refreshing: Bool) {
        let isOurs = receiverModelID.map { $0 == KeychronMouseProtocol.m3MiniModelID } ?? true
        let linked = isLinked && isOurs
        guard linked != isOnReceiver else { return }
        isOnReceiver = linked
        if !linked { receiverModelID = nil }
        guard cable == nil else { return }
        if linked {
            if refreshing { refresh() }
        } else {
            linkLost()
        }
    }

    private func apply(_ power: KeychronMouseProtocol.Power) {
        isAwake = true
        batteryPercent = power.percent
        isCharging = power.isCharging
        if let max = power.maxReportRateHz { maxReportRateHz = max }
        if settings?.activeStage != power.activeStage, pendingSettings == nil {
            settings?.activeStage = power.activeStage
        }
        reportBattery()
    }

    private func reportBattery() {
        AccessoryBatteryAlerts.shared.report(id: id, name: Self.name, percent: batteryPercent, isCharging: isCharging)
    }

    // MARK: Writing

    /// Sets the DPI of the active stage.
    func setDPI(_ dpi: Int) {
        update { $0.setDPI(KeychronMouseProtocol.clampDPI(dpi), stage: $0.activeStage) }
    }

    func setReportRate(_ hz: Int) {
        update { $0.reportRateHz = hz }
    }

    func setLiftOff(millimeters: Int) {
        update { $0.liftOffMillimeters = millimeters }
    }

    func setMotionSync(_ isOn: Bool) {
        update { $0.isMotionSyncOn = isOn }
    }

    func setAngleSnapping(_ isOn: Bool) {
        update { $0.isAngleSnappingOn = isOn }
    }

    /// Stores the action's shortcut on the mouse, which then sends it itself, then reads back what it kept.
    func setSideButton(_ button: KeychronMouseProtocol.SideButton, to action: AccessoryButtonAction) {
        guard let target, let assignment = KeychronMouseProtocol.assignment(for: action, on: button),
              sideButtons?[button] != .some(action) else { return }
        sideButtons?[button] = action
        Task { [weak self] in
            await self?.writeSideButton(button, action: action, assignment: assignment, to: target)
            await self?.loadSideButtons(from: target)
        }
    }

    private func update(_ change: (inout KeychronMouseProtocol.Settings) -> Void) {
        guard var updated = settings else { return }
        change(&updated)
        guard updated != settings else { return }
        settings = updated
        pendingSettings = updated
        flushWrites()
    }

    /// Writes the newest settings block and saves it on the mouse, one at a time, then reads back what the mouse
    /// kept. The whole block goes back as read, so values the app doesn't show are left as they were.
    private func flushWrites() {
        guard !isWriting, target != nil else { return }
        isWriting = true
        Task { [weak self] in
            while let self, let pending = self.pendingSettings, let target = self.target {
                self.pendingSettings = nil
                var written = await self.request(.writeSettings, payload: pending.block, on: target.device, routed: target.routed)
                if written == nil {
                    // Right after a report rate change the link resyncs and the next request can go unanswered.
                    try? await Task.sleep(for: .milliseconds(500))
                    written = await self.request(.writeSettings, payload: pending.block, on: target.device, routed: target.routed)
                }
                if written != nil {
                    _ = await self.request(.save, on: target.device, routed: target.routed)
                }
                guard self.pendingSettings == nil else { continue }
                if let reply = await self.request(.readSettings, on: target.device, routed: target.routed),
                   let read = KeychronMouseProtocol.Settings(reply), self.pendingSettings == nil {
                    self.settings = read
                }
            }
            self?.isWriting = false
        }
    }

    // MARK: Requests

    /// Sends one packet and waits for its reply, one request at a time. Nil if nothing answers in time, which
    /// through the receiver means the mouse is asleep.
    private func request(
        _ command: KeychronMouseProtocol.Command,
        payload: ArraySlice<UInt8> = [],
        on device: IOHIDDevice,
        routed: Bool
    ) async -> [UInt8]? {
        let packet = KeychronMouseProtocol.packet(command, routed: routed, payload: payload)
        let previous = queueTail
        let task = Task<[UInt8]?, Never> {
            await previous?.value
            return await self.sendAndWait(packet, to: device)
        }
        queueTail = Task { _ = await task.value }
        let reply = await task.value
        if routed || device == cable {
            if reply != nil { isAwake = true } else if device == target?.device { isAwake = false }
        }
        return reply
    }

    private func sendAndWait(_ packet: [UInt8], to device: IOHIDDevice) async -> [UInt8]? {
        await withCheckedContinuation { continuation in
            waiter = Waiter(device: device, packet: packet, continuation: continuation)
            let result = packet.withUnsafeBufferPointer { buffer in
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, buffer.baseAddress!, buffer.count)
            }
            guard result == kIOReturnSuccess else {
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

    private func finish(with reply: [UInt8]?) {
        guard let current = waiter else { return }
        waiter = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        current.continuation.resume(returning: reply)
    }

    // MARK: Incoming Reports

    private func handle(report: [UInt8], from device: IOHIDDevice) {
        if let current = waiter, current.device == device, KeychronMouseProtocol.isReply(report, to: current.packet) {
            finish(with: report)
            return
        }
        guard report[3] == KeychronMouseProtocol.Command.power.sub else { return }
        let command = report[0] & ~KeychronMouseProtocol.routeBit
        let isRouted = report[0] & KeychronMouseProtocol.routeBit != 0
        if device == receiver, !isRouted, command == KeychronMouseProtocol.Command.power.id {
            // The receiver's own report: the mouse joined it (woke, or came back from the cable or Bluetooth) or left.
            receiverLinkChanged(isLinked: report[4] == KeychronMouseProtocol.linkedState, refreshing: true)
        } else if device == target?.device, command == KeychronMouseProtocol.Command.power.id,
                  let power = KeychronMouseProtocol.Power(report) {
            // The mouse's own report: the DPI button, or charging starting or stopping.
            apply(power)
            if settings == nil { refresh() }
        }
    }
}

// MARK: - AccessoryConnector

extension KeychronM3MiniConnector: AccessoryConnector {
    var id: String { "keychron.m3mini" }
    var displayName: String { "M3 Mini" }
    var systemImage: String { "computermouse" }

    var isAvailable: Bool { connection != nil }
    var accessoryName: String { Self.name }
    var connection: AccessoryConnection? {
        if isOnCable { return .usbCable }
        if isOnReceiver { return .receiver }
        if isOnBluetooth { return .bluetooth }
        return nil
    }

    func start() {
        setUp()
    }

    /// Settings live on the mouse, so there's nothing to hand back.
    func stop() {}

    func systemDidWake() {
        refresh()
    }

    func popoverWillShow() {
        let wasOpen = isOpen
        openIfPermitted()
        // Opening delivers every attached device, which refreshes on its own.
        if wasOpen { refresh() }
    }

    func setCardVisible(_ visible: Bool) {}

    func makeSettingsView() -> AnyView {
        AnyView(KeychronM3MiniSettingsView(connector: self))
    }
}

// MARK: - Bluetooth Battery

/// Reads the mouse's battery level from the GATT battery service while it's on Bluetooth, and follows its
/// notifications. CoreBluetooth (and its permission prompt) only starts once the mouse is seen on Bluetooth.
@MainActor
private final class KeychronBluetoothBattery: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")

    private(set) var percent: Int?
    var onChange: (() -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var peripheralName: String?

    func start(peripheralName name: String) {
        peripheralName = name
        if let central {
            connect(using: central)
        } else {
            // Delegate calls arrive on the main queue.
            central = CBCentralManager(delegate: self, queue: nil)
        }
    }

    func stop() {
        peripheralName = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        setPercent(nil)
    }

    /// The mouse is already connected to the Mac; this connects the app to it as well, to read the battery.
    private func connect(using central: CBCentralManager) {
        guard central.state == .poweredOn, peripheral == nil, let peripheralName else { return }
        guard let found = central.retrieveConnectedPeripherals(withServices: [Self.batteryService])
            .first(where: { $0.name == peripheralName }) else { return }
        peripheral = found
        found.delegate = self
        central.connect(found)
    }

    private func setPercent(_ value: Int?) {
        guard value != percent else { return }
        percent = value
        onChange?()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            connect(using: central)
        } else {
            peripheral = nil
            setPercent(nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.batteryService])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        self.peripheral = nil
        setPercent(nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.batteryService }) else { return }
        peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let level = service.characteristics?.first(where: { $0.uuid == Self.batteryLevel }) else { return }
        peripheral.readValue(for: level)
        peripheral.setNotifyValue(true, for: level)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.batteryLevel, let byte = characteristic.value?.first, byte <= 100 else { return }
        setPercent(Int(byte))
    }
}

// MARK: - Settings Sections

/// The M3 Mini page: mouse-specific sections only. The Accessories tab adds the device section and battery
/// alerts, and disables everything while the mouse isn't connected.
private struct KeychronM3MiniSettingsView: View {
    let connector: KeychronM3MiniConnector

    private static let dpiPresets = [400, 800, 1600, 3200, 6400]

    var body: some View {
        if connector.canConfigure, let settings = connector.settings {
            SettingsSection(title: "Performance", footer: "DPI applies to the mouse's current stage; the button under the wheel switches between its stages. Changes are saved to the mouse, so it keeps them without Aeron Tools. Higher report rates use more battery.") {
                DPIControl(
                    dpi: settings.dpi(stage: settings.activeStage),
                    presets: Self.dpiPresets,
                    range: KeychronMouseProtocol.dpiRange,
                    onCommit: connector.setDPI
                )
                if let rate = settings.reportRateHz {
                    Picker("Report Rate", selection: Binding(get: { rate }, set: { connector.setReportRate($0) })) {
                        ForEach(reportRates(current: rate), id: \.self) { hz in
                            Text(hz >= 1000 ? "\(hz / 1000) kHz" : "\(hz) Hz").tag(hz)
                        }
                    }
                }
            }
            SettingsSection(title: "Sensor") {
                Picker("Lift-off distance", selection: Binding(get: { settings.liftOffMillimeters }, set: { connector.setLiftOff(millimeters: $0) })) {
                    ForEach(KeychronMouseProtocol.liftOffDistances, id: \.self) { millimeters in
                        Text("\(millimeters) mm").tag(millimeters)
                    }
                }
                Toggle("Motion sync", isOn: Binding(get: { settings.isMotionSyncOn }, set: { connector.setMotionSync($0) }))
                Toggle("Angle snapping", isOn: Binding(get: { settings.isAngleSnappingOn }, set: { connector.setAngleSnapping($0) }))
            }
        }
        if connector.canConfigure, let buttons = connector.sideButtons {
            SettingsSection(title: "Side Buttons", footer: "Saved to the mouse, which sends each action's shortcut itself, so the buttons work without Aeron Tools and over Bluetooth. Shortcuts follow Keyboard Shortcuts in System Settings; if you change one there, it's updated on the mouse the next time it connects. Mouse Button 4 and 5 only go back and forward in some apps.") {
                ForEach(KeychronMouseProtocol.SideButton.allCases) { button in
                    if let action = buttons[button] {
                        sideButtonPicker(button, action: action)
                    }
                }
            }
        }
        if !connector.canConfigure, connector.connection == .bluetooth {
            SettingsSection(title: "Settings", footer: "Over Bluetooth the mouse only reports its battery level. Connect it with the 4K Link receiver or its USB cable to change DPI, sensor and button settings. Settings already saved to the mouse still apply.") {
                LabeledContent("DPI, sensor and buttons", value: "Receiver or cable only")
            }
        }
    }

    private func sideButtonPicker(_ button: KeychronMouseProtocol.SideButton, action current: AccessoryButtonAction?) -> some View {
        // Actions whose shortcut is turned off on this Mac can't be sent, so they aren't offered.
        let actions = KeychronMouseProtocol.buttonActions.filter {
            $0 == current || KeychronMouseProtocol.assignment(for: $0, on: button) != nil
        }
        return Picker(button.title, selection: Binding<AccessoryButtonAction?>(
            get: { current },
            set: { action in
                if let action { connector.setSideButton(button, to: action) }
            }
        )) {
            if current == nil {
                Text("Custom").tag(AccessoryButtonAction?.none)
            }
            ForEach(actions) { action in
                Text(title(of: action, on: button)).tag(Optional(action))
            }
        }
    }

    private func title(of action: AccessoryButtonAction, on button: KeychronMouseProtocol.SideButton) -> String {
        if action == .systemDefault { return button == .back ? "Mouse Button 4" : "Mouse Button 5" }
        return action == button.defaultAction ? "\(action.title) (Default)" : action.title
    }

    /// The rates the current link allows, plus the mouse's current one so the picker always shows it.
    private func reportRates(current: Int) -> [Int] {
        let max = connector.maxReportRateHz ?? KeychronMouseProtocol.reportRates.last ?? current
        return Set(KeychronMouseProtocol.reportRates.filter { $0 <= max } + [current]).sorted()
    }
}
