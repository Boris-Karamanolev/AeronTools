import Foundation
import CoreGraphics
import IOKit.hid
import Observation
import UserNotifications

// MARK: - MXMasterManager

@Observable
@MainActor
public final class MXMasterManager {
    public static let shared = MXMasterManager()

    private static let configDefaultsKey = "mxMasterConfig"
    private static let cardOptionsDefaultsKey = "mxMasterCardOptions"

    public var config: MXMasterConfig {
        didSet {
            saveConfig()
            handleConfigDidChange(from: oldValue, to: config)
        }
    }

    public var cardOptions: MXMasterCardOptions {
        didSet {
            if let data = try? JSONEncoder().encode(cardOptions) {
                UserDefaults.standard.set(data, forKey: Self.cardOptionsDefaultsKey)
            }
            if cardOptions.lowBatteryAlertEnabled && !oldValue.lowBatteryAlertEnabled {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
            if cardOptions.lowBatteryThreshold != oldValue.lowBatteryThreshold {
                hasSentLowBatteryAlert = false
            }
            evaluateLowBatteryAlert()
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
            evaluateLowBatteryAlert()
        }
    }

    public internal(set) var isConnected: Bool = false
    /// True once the device has confirmed it is an MX Master: by its HID++ name behind a receiver, or by
    /// its product name over a direct link. A receiver alone, or another Logitech device on it, never counts.
    public internal(set) var isIdentified: Bool = false
    /// Input Monitoring (TCC ListenEvent) is required to open the mouse's HID++ channel.
    public internal(set) var hasInputMonitoringAccess: Bool = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    public private(set) var isMonitoring: Bool = false
    public internal(set) var lastStatusMessage: String = "Searching for Logitech MX Master…"

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

    @ObservationIgnored private var dpiDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var smartShiftDebounceTask: Task<Void, Never>?

    // Gesture & Smooth Scroll State
    @ObservationIgnored var isGestureButtonHeld = false
    @ObservationIgnored var gestureTriggeredDuringHold = false
    @ObservationIgnored var gestureAccumulatedDelta: CGPoint = .zero
    @ObservationIgnored let gestureDragThreshold: CGFloat = 36.0
    @ObservationIgnored var lastSpaceOrTabSwitchTime: CFAbsoluteTime = 0
    @ObservationIgnored var smoothScrollVelocityY: Double = 0
    @ObservationIgnored private var smoothScrollVelocityX: Double = 0
    @ObservationIgnored var smoothScrollTimer: Timer?
    /// Fractional lines carried between notches when smooth scrolling is off.
    @ObservationIgnored var pendingLineScroll: Double = 0

    // Low-Battery Alert State
    @ObservationIgnored private var hasSentLowBatteryAlert = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.configDefaultsKey),
           let decoded = try? JSONDecoder().decode(MXMasterConfig.self, from: data) {
            self.config = decoded
        } else {
            self.config = MXMasterConfig()
        }
        if let data = UserDefaults.standard.data(forKey: Self.cardOptionsDefaultsKey),
           let decoded = try? JSONDecoder().decode(MXMasterCardOptions.self, from: data) {
            self.cardOptions = decoded
        } else {
            self.cardOptions = MXMasterCardOptions()
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

    // MARK: - Low-Battery Alert

    /// HID++ mice send their own battery events and power-source changes are observed, so only a mouse that
    /// is visible solely through the IORegistry, which posts no change notifications, is still polled.
    /// Posts one notification per discharge cycle once the battery reaches the configured threshold.
    private func evaluateLowBatteryAlert() {
        guard let battery = snapshot.batteryPercent else { return }
        if snapshot.isCharging || battery > cardOptions.lowBatteryThreshold {
            hasSentLowBatteryAlert = false
            return
        }
        guard cardOptions.lowBatteryAlertEnabled, !hasSentLowBatteryAlert else { return }
        hasSentLowBatteryAlert = true

        let content = UNMutableNotificationContent()
        content.title = "\(snapshot.deviceName) Battery Low"
        content.body = "Battery is at \(battery)%. Connect the USB-C cable to charge."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "mxMasterLowBattery", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
