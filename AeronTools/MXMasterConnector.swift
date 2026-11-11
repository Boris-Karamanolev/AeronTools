import SwiftUI

// MARK: - MX Master as an AccessoryConnector

/// `start()` is provided by `MXMasterManager` itself.
extension MXMasterManager: AccessoryConnector {
    var id: String { "logitech.mx-master" }
    var displayName: String { "MX Master" }
    var systemImage: String { "magicmouse" }

    var isAvailable: Bool { isConnected && isIdentified }
    var accessoryName: String { isAvailable ? snapshot.deviceName : displayName }
    var connection: AccessoryConnection? {
        guard isAvailable else { return nil }
        switch snapshot.transport {
        case .bluetoothLE: return .bluetooth
        case .logiBolt, .unifying: return .receiver
        case .usbWired: return .usbCable
        case .disconnected: return nil
        }
    }
    /// The MX's receiver reports reconnects but not sleep, so an identified MX counts as awake.
    var isAwake: Bool { isAvailable }
    var batteryPercent: Int? { snapshot.batteryPercent }
    var isCharging: Bool { snapshot.isCharging }

    func stop() {
        releaseInputDiversion()
    }

    func systemDidWake() {
        refreshDeviceState()
        applyAllSettingsToHardware()
    }

    func popoverWillShow() {
        // Input Monitoring has no change notification, so a grant made in System Settings is picked up here.
        recheckInputMonitoringAccess()
        refreshDeviceState()
    }

    func setCardVisible(_ visible: Bool) {
        visible ? startMonitoring() : stopMonitoring()
    }

    func makeSettingsView() -> AnyView {
        AnyView(MXMasterSettingsTabView())
    }
}
