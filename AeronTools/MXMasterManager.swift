import Foundation
import CoreGraphics
import IOKit.hid
import Observation

// MARK: - MXMasterManager

@Observable
@MainActor
public final class MXMasterManager {
    public static let shared = MXMasterManager()

    private static let configDefaultsKey = "mxMasterConfig"

    public var config: MXMasterConfig {
        didSet {
            saveConfig()
            handleConfigDidChange(from: oldValue, to: config)
        }
    }

    public internal(set) var snapshot: MXMasterSnapshot = MXMasterSnapshot(
        deviceName: "MX Master 4",
        productID: 0,
        transport: .disconnected,
        batteryPercent: nil,
        isCharging: false,
        hidppConnected: false,
        minDPI: 200,
        maxDPI: 8000,
        dpiStep: 50,
        reportedDPI: nil,
        reportedWheelMode: nil,
        reportedSmartShiftEnabled: nil,
        reportedSmartShiftThreshold: nil
    ) {
        didSet {
            AccessoryBatteryAlerts.shared.report(
                id: id, name: snapshot.deviceName, percent: snapshot.batteryPercent, isCharging: snapshot.isCharging
            )
        }
    }

    public internal(set) var isConnected: Bool = false
    /// True once the device has confirmed it is an MX Master: by its HID++ name behind a receiver, or by
    /// its product name over a direct link. A receiver alone, or another Logitech device on it, never counts.
    public internal(set) var isIdentified: Bool = false
    /// Input Monitoring (TCC ListenEvent) is required to open the mouse's HID++ channel.
    public internal(set) var hasInputMonitoringAccess: Bool = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    public private(set) var isMonitoring: Bool = false

    // MARK: Private State

    @ObservationIgnored var hidManager: IOHIDManager?
    @ObservationIgnored var activeHIDDevice: IOHIDDevice?
    @ObservationIgnored var activeDeviceIndex: UInt8 = 0xFF
    @ObservationIgnored var featureTable: [UInt16: UInt8] = [:]
    @ObservationIgnored var pressedDivertedCIDs: Set<UInt16> = []
    @ObservationIgnored var inputMonitoringObserver: NSObjectProtocol?
    /// Asks a receiver-connected device for its name; shares the device with the MX feature code.
    @ObservationIgnored var identitySession: HIDPPSession?
    @ObservationIgnored var identifyTask: Task<Void, Never>?
    /// The latest push of control diversions; a newer one replaces it.
    @ObservationIgnored var diversionTask: Task<Void, Never>?

    /// Save button remaps to the mouse, so buttons with a native equivalent keep it without the app.
    public var savesToMouse: Bool = UserDefaults.standard.object(forKey: "mxMaster.saveToMouse") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(savesToMouse, forKey: "mxMaster.saveToMouse")
            // Turning it off also runs a save, which puts every button back to itself.
            scheduleMouseSave()
        }
    }
    public internal(set) var mouseSaveState: MouseSaveState = .idle
    @ObservationIgnored var mouseSaveTask: Task<Void, Never>?
    /// The mouse's controls by CID, read once per connection.
    @ObservationIgnored var controlInfos: [UInt16: HIDPPProtocol.ControlInfo] = [:]
    /// Remaps written in this run, to notice a mouse that forgets them when it powers off.
    @ObservationIgnored var savedRemaps: [UInt16: UInt16] = [:]

    @ObservationIgnored private var dpiDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var smartShiftDebounceTask: Task<Void, Never>?

    // Gesture & Smooth Scroll State
    @ObservationIgnored var gestureTracker = MXGestureTracker()
    @ObservationIgnored var lastSpaceOrTabSwitchTime: CFAbsoluteTime = 0
    @ObservationIgnored var smoothScrollVelocityY: Double = 0
    @ObservationIgnored private var smoothScrollVelocityX: Double = 0
    @ObservationIgnored var smoothScrollTimer: Timer?
    /// Fractional lines carried between notches when smooth scrolling is off.
    @ObservationIgnored var pendingLineScroll: Double = 0

    // Low-Battery Alert State

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.configDefaultsKey),
           let decoded = try? JSONDecoder().decode(MXMasterConfig.self, from: data) {
            self.config = decoded
        } else {
            self.config = MXMasterConfig()
        }
        // Bluetooth LE mice report battery through macOS power sources instead of HID++ events.
        PowerSource.onChange { [weak self] in
            guard let self, self.isConnected, !self.snapshot.hidppConnected else { return }
            self.refreshDeviceState()
        }
    }

    // MARK: - Lifecycle

    public func start() {
        setupHIDManager()
        refreshDeviceState()
    }

    /// Fetches fresh state once when the card is shown. After that everything is event-driven: the mouse
    /// broadcasts HID++ battery changes, Bluetooth LE battery arrives via power source notifications, and
    /// connects/disconnects come from the HID manager callbacks.
    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        refreshDeviceState()
    }

    public func stopMonitoring() {
        isMonitoring = false
    }

    // MARK: - Persistence & Change Handling

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.configDefaultsKey)
        }
    }

    private func handleConfigDidChange(from oldValue: MXMasterConfig, to newValue: MXMasterConfig) {
        if oldValue.dpi != newValue.dpi {
            dpiDebounceTask?.cancel()
            let targetDPI = newValue.dpi
            dpiDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled else { return }
                self?.sendDPIToHardware(targetDPI)
            }
        }

        if oldValue.wheelMode != newValue.wheelMode
            || oldValue.smartShiftEnabled != newValue.smartShiftEnabled
            || oldValue.smartShiftThreshold != newValue.smartShiftThreshold {
            smartShiftDebounceTask?.cancel()
            smartShiftDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.sendSmartShiftToHardware(
                    wheelMode: self.config.wheelMode,
                    smartShiftEnabled: self.config.smartShiftEnabled,
                    threshold: self.config.smartShiftThreshold
                )
            }
        }

        // Scroll, thumbwheel, button and gesture settings all live on the mouse as HID++ diversions.
        applyInputDiversion()

        if savesToMouse, Self.buttonActions(oldValue).map(\.action) != Self.buttonActions(newValue).map(\.action) {
            scheduleMouseSave()
        }
    }

    /// Immediately pushes the current DPI, SmartShift, and button diversion configuration to the mouse.
    public func applyAllSettingsToHardware() {
        sendDPIToHardware(config.dpi)
        sendSmartShiftToHardware(
            wheelMode: config.wheelMode,
            smartShiftEnabled: config.smartShiftEnabled,
            threshold: config.smartShiftThreshold
        )
        applyInputDiversion()
        requestBatteryFromHIDPP()
    }

    /// Toggles between Ratchet and Free-Spin wheel modes.
    public func toggleWheelMode() {
        config.wheelMode = (config.wheelMode == .ratchet) ? .freeSpin : .ratchet
    }
}
