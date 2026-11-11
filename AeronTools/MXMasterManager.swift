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
            updateBatteryAlertTimer()
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
            updateBatteryAlertTimer()
            evaluateLowBatteryAlert()
        }
    }

    public internal(set) var isConnected: Bool = false
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
    @ObservationIgnored var inputMonitoringTimer: Timer?

    @ObservationIgnored var eventTap: CFMachPort?
    @ObservationIgnored var runLoopSource: CFRunLoopSource?
    /// Pointer-motion tap, enabled only while the gesture button is held so ordinary mouse movement never
    /// round-trips through the main thread.
    @ObservationIgnored var gestureTap: CFMachPort?
    @ObservationIgnored var gestureRunLoopSource: CFRunLoopSource?
    @ObservationIgnored private var telemetryTimer: Timer?
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

    // Low-Battery Alert State
    @ObservationIgnored private var batteryAlertTimer: Timer?
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
        AccessibilityPermission.shared.onChange { [weak self] in
            guard let self else { return }
            // A revoked permission leaves dead taps behind, so tear them down before re-evaluating.
            if !AccessibilityPermission.shared.isGranted { self.stopEventTap() }
            self.updateEventTapState()
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
        updateEventTapState()
        updateBatteryAlertTimer()
    }

    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        refreshDeviceState()

        telemetryTimer?.invalidate()
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Connecting is picked up by the HID matching callback, so only a connected mouse needs refreshing.
                guard let self, self.isMonitoring, self.isConnected else { return }
                self.refreshDeviceState()
            }
        }
    }

    public func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        telemetryTimer?.invalidate()
        telemetryTimer = nil
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

        if oldValue.gesturesEnabled != newValue.gesturesEnabled
            || oldValue.gestureButtonClickAction != newValue.gestureButtonClickAction
            || oldValue.modeShiftButtonAction != newValue.modeShiftButtonAction
            || oldValue.hapticPanelButtonAction != newValue.hapticPanelButtonAction {
            configureDivertedButtonsIfNeeded()
        }

        updateEventTapState()
    }

    /// Immediately pushes the current DPI, SmartShift, and button diversion configuration to the mouse.
    public func applyAllSettingsToHardware() {
        sendDPIToHardware(config.dpi)
        sendSmartShiftToHardware(
            wheelMode: config.wheelMode,
            smartShiftEnabled: config.smartShiftEnabled,
            threshold: config.smartShiftThreshold
        )
        configureDivertedButtonsIfNeeded()
        requestBatteryFromHIDPP()
    }

    /// Toggles between Ratchet and Free-Spin wheel modes.
    public func toggleWheelMode() {
        config.wheelMode = (config.wheelMode == .ratchet) ? .freeSpin : .ratchet
    }

    // MARK: - Low-Battery Alert

    /// HID++ mice send their own battery events and power-source changes are observed, so only a mouse that
    /// is visible solely through the IORegistry, which posts no change notifications, is still polled.
    private func updateBatteryAlertTimer() {
        guard cardOptions.lowBatteryAlertEnabled, isConnected, !snapshot.hidppConnected else {
            batteryAlertTimer?.invalidate()
            batteryAlertTimer = nil
            return
        }
        guard batteryAlertTimer == nil else { return }
        batteryAlertTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isMonitoring else { return }
                self.refreshDeviceState()
            }
        }
    }

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
