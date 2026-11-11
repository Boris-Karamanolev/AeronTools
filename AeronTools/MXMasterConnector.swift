import SwiftUI

// MARK: - MX Master as an AccessoryConnector

/// `start()` and `isConnected` are provided by `MXMasterManager` itself.
extension MXMasterManager: AccessoryConnector {
    var id: String { "logitech.mx-master" }
    var displayName: String { "MX Master" }
    var systemImage: String { "magicmouse" }

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

    func makeCardView() -> AnyView {
        AnyView(MXMasterCardView())
    }

    func makeSettingsView() -> AnyView {
        AnyView(MXMasterSettingsTabView())
    }
}
