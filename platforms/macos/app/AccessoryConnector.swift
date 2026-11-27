import SwiftUI
import IOKit.hid
import UserNotifications

// MARK: - Input Monitoring

/// HID access for the engine's input loop. macOS posts no change notification, so the settings
/// screen re-checks when the app becomes active.
enum InputMonitoringPermission {
    static var isGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func request() {
        Task.detached(priority: .utility) {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Low Battery Alerts

@Observable
@MainActor
final class AccessoryBatteryAlerts {
    static let shared = AccessoryBatteryAlerts()

    private static let enabledKey = "accessoryLowBatteryAlert"
    private static let thresholdKey = "accessoryLowBatteryThreshold"
    private static let legacyMXOptionsKey = "mxMasterCardOptions"

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled && !oldValue {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        }
    }

    var threshold: Int {
        didSet {
            UserDefaults.standard.set(threshold, forKey: Self.thresholdKey)
            alerted.removeAll()
        }
    }

    @ObservationIgnored private var alerted: Set<String> = []

    private init() {
        let defaults = UserDefaults.standard
        struct LegacyOptions: Decodable {
            var lowBatteryAlertEnabled: Bool?
            var lowBatteryThreshold: Int?
        }
        let legacy = defaults.data(forKey: Self.legacyMXOptionsKey)
            .flatMap { try? JSONDecoder().decode(LegacyOptions.self, from: $0) }
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? legacy?.lowBatteryAlertEnabled ?? true
        threshold = defaults.object(forKey: Self.thresholdKey) as? Int ?? legacy?.lowBatteryThreshold ?? 15
    }

    func report(id: String, name: String, percent: Int?, isCharging: Bool) {
        guard let percent else { return }
        if isCharging || percent > threshold {
            alerted.remove(id)
            return
        }
        guard isEnabled, !alerted.contains(id) else { return }
        alerted.insert(id)

        let content = UNMutableNotificationContent()
        content.title = "\(name) Battery Low"
        content.body = "Battery is at \(percent)%. Connect it to charge."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "lowBattery.\(id)", content: content, trigger: nil))
    }
}

// MARK: - Pages

private struct AccessoryPage: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let name: String
    let connected: Bool
    let status: String
    let batteryPercent: Int?
    let isCharging: Bool
    let hasBattery: Bool
}

private func accessoryPages(from accessories: CoreAccessoriesSnapshot?) -> [AccessoryPage] {
    let mx = accessories?.mxMaster
    let keys = accessories?.mxKeyboard
    let gMouse = accessories?.logitechGMouse
    let gKeys = accessories?.logitechGKeyboard
    let keychron = accessories?.keychronM3Mini
    let razer = accessories?.razerDock
    let satechi = accessories?.satechiHub
    return [
        page("mx-master", "MX Master", "computermouse", mx?.name, mx?.connected, mx?.connection, mx?.batteryPercent, mx?.isCharging, true),
        page("mx-keyboard", "MX Keyboard", "keyboard", keys?.name, keys?.connected, keys?.connection, keys?.batteryPercent, keys?.isCharging, true),
        page("logitech-g-mouse", "G Mouse", "computermouse", gMouse?.name, gMouse?.connected, gMouse?.connection, gMouse?.batteryPercent, gMouse?.isCharging, true),
        page("logitech-g-keyboard", "G Keyboard", "keyboard", gKeys?.name, gKeys?.connected, gKeys?.connection, gKeys?.batteryPercent, gKeys?.isCharging, true),
        page("keychron", "Keychron", "computermouse", keychron?.name, keychron?.connected, keychron?.connection, keychron?.batteryPercent, keychron?.isCharging, true),
        page("razer-dock", "Razer Dock", "cable.connector", razer?.name, razer?.connected, nil, nil, false, false),
        page("satechi", "Satechi", "cable.connector", satechi?.name, satechi?.connected, nil, nil, false, false),
    ]
}

private func page(
    _ id: String,
    _ title: String,
    _ symbol: String,
    _ name: String?,
    _ connected: Bool?,
    _ connection: CoreAccessoryConnection?,
    _ battery: UInt8?,
    _ charging: Bool?,
    _ hasBattery: Bool
) -> AccessoryPage {
    let isConnected = connected ?? false
    return AccessoryPage(
        id: id,
        title: title,
        systemImage: symbol,
        name: (name?.isEmpty == false ? name : nil) ?? title,
        connected: isConnected,
        status: isConnected ? (connection?.title ?? "Connected") : "Not connected",
        batteryPercent: battery.map(Int.init),
        isCharging: charging ?? false,
        hasBattery: hasBattery
    )
}

extension CoreAccessoryConnection {
    var title: String {
        switch self {
        case .bluetoothLe: return "Bluetooth"
        case .logiBolt: return "Logi Bolt"
        case .unifying: return "Unifying Receiver"
        case .lightspeed: return "LIGHTSPEED"
        case .usbWired: return "USB"
        case .thunderbolt: return "Thunderbolt"
        case .wireless4k: return "2.4 GHz"
        }
    }
}

extension CoreButtonAction {
    var swiftAction: AccessoryButtonAction {
        switch self {
        case .systemDefault: return .systemDefault
        case .missionControl: return .missionControl
        case .appExpose: return .appExpose
        case .showDesktop: return .showDesktop
        case .launchpad: return .launchpad
        case .spaceLeft: return .spaceLeft
        case .spaceRight: return .spaceRight
        case .navigateBack: return .navigateBack
        case .navigateForward: return .navigateForward
        case .playPause: return .playPause
        case .mutePointerDisplay: return .mutePointerDisplay
        case .toggleBuiltinScreen: return .toggleMacBookScreen
        case .toggleCaffeine: return .toggleCaffeine
        case .toggleWheelMode: return .toggleWheelMode
        case .copy: return .copy
        case .paste: return .paste
        }
    }

    init(swift action: AccessoryButtonAction) {
        switch action {
        case .systemDefault: self = .systemDefault
        case .missionControl: self = .missionControl
        case .appExpose: self = .appExpose
        case .showDesktop: self = .showDesktop
        case .launchpad: self = .launchpad
        case .spaceLeft: self = .spaceLeft
        case .spaceRight: self = .spaceRight
        case .navigateBack: self = .navigateBack
        case .navigateForward: self = .navigateForward
        case .playPause: self = .playPause
        case .mutePointerDisplay: self = .mutePointerDisplay
        case .toggleMacBookScreen: self = .toggleBuiltinScreen
        case .toggleCaffeine: self = .toggleCaffeine
        case .toggleWheelMode: self = .toggleWheelMode
        case .copy: self = .copy
        case .paste: self = .paste
        }
    }
}

extension CoreMxMasterState {
    func options() -> CoreMxMasterOptions {
        CoreMxMasterOptions(
            standardVerticalScroll: standardVerticalScroll,
            smoothScrolling: smoothScrolling,
            scrollSpeedMultiplier: scrollSpeedMultiplier,
            thumbwheelAction: thumbwheelAction,
            invertThumbwheel: invertThumbwheel,
            middleButtonAction: middleButtonAction,
            backButtonAction: backButtonAction,
            forwardButtonAction: forwardButtonAction,
            gestureButtonAction: gestureButtonAction,
            modeShiftButtonAction: modeShiftButtonAction,
            hapticPanelButtonAction: hapticPanelButtonAction,
            gesturesEnabled: gesturesEnabled,
            gestureUpAction: gestureUpAction,
            gestureDownAction: gestureDownAction,
            gestureLeftAction: gestureLeftAction,
            gestureRightAction: gestureRightAction,
            savesToMouse: savesToMouse
        )
    }
}

// MARK: - Cards

struct AccessoryCardsView: View {
    private var engine: SharedCoreEngine { .shared }

    var body: some View {
        ForEach(accessoryPages(from: engine.snapshot?.accessories).filter(\.connected)) { page in
            AccessoryCardHeader(
                systemImage: page.systemImage,
                name: page.name,
                status: page.status,
                isOnline: page.connected,
                batteryPercent: page.batteryPercent,
                isCharging: page.isCharging
            )
            .accessoryCardStyle()
        }
    }
}

// MARK: - Settings

struct AccessoriesSettingsTabView: View {
    @AppStorage("selectedAccessorySettingsID") private var selectedID = "mx-master"
    @Bindable private var batteryAlerts = AccessoryBatteryAlerts.shared
    private var engine: SharedCoreEngine { .shared }

    private var pages: [AccessoryPage] { accessoryPages(from: engine.snapshot?.accessories) }
    private var selected: AccessoryPage {
        pages.first { $0.id == selectedID } ?? pages[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            AccessorySelector(pages: pages, selectedID: selected.id) { selectedID = $0 }
                .padding(.bottom, 4)
            Form {
                deviceSection(selected)
                settings(for: selected)
                    .disabled(!selected.connected)
                    .id(selected.id)
                if selected.hasBattery {
                    SettingsSection(title: "Battery", footer: "Applies to every accessory. You're notified once per charge.") {
                        Toggle("Low battery notification", isOn: $batteryAlerts.isEnabled)
                        Stepper(value: $batteryAlerts.threshold, in: 5...50, step: 5) {
                            LabeledContent("Notify at or below", value: "\(batteryAlerts.threshold)%")
                        }
                        .disabled(!batteryAlerts.isEnabled)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func deviceSection(_ page: AccessoryPage) -> some View {
        SettingsSection(title: "Device", footer: page.connected ? nil : "Connect the \(page.title) to change its settings.") {
            HStack(spacing: 8) {
                StatusDot(isActive: page.connected)
                Text(page.name).font(.headline)
            }
            LabeledContent("Connection", value: page.status)
            if let percent = page.batteryPercent {
                LabeledContent("Battery", value: page.isCharging ? "\(percent)% · Charging" : "\(percent)%")
            }
            if !InputMonitoringPermission.isGranted {
                PermissionNotice(
                    message: "Input Monitoring is needed to talk to the device.",
                    buttonTitle: "Open Settings…",
                    action: { InputMonitoringPermission.request() }
                )
            }
        }
    }

    @ViewBuilder
    private func settings(for page: AccessoryPage) -> some View {
        switch page.id {
        case "mx-master": mxMasterSettings
        case "mx-keyboard": mxKeyboardSettings
        case "logitech-g-mouse": gMouseSettings
        case "logitech-g-keyboard": gKeyboardSettings
        case "keychron": keychronSettings
        case "razer-dock": razerSettings
        case "satechi": EmptyView()
        default: EmptyView()
        }
    }

    private var mx: CoreMxMasterState? { engine.snapshot?.accessories.mxMaster }

    private var mxMasterSettings: some View {
        Group {
            if let mx {
                SettingsSection(title: "Performance", footer: "SmartShift switches the wheel to free-spin when you flick it.") {
                    DPIControl(dpi: Int(mx.dpi), presets: [800, 1200, 1600, 2400, 4000, 8000], range: 200...8000) { dpi in
                        Task { await engine.setMxMasterDpi(UInt16(dpi)) }
                    }
                    Picker("Wheel Mode", selection: Binding(
                        get: { mx.wheelMode },
                        set: { mode in Task { await engine.setMxMasterSmartShift(wheelMode: mode, smartShiftEnabled: mx.smartShiftEnabled, threshold: mx.smartShiftThreshold) } }
                    )) {
                        Text("Ratchet").tag(CoreWheelMode.ratchet)
                        Text("Free-spin").tag(CoreWheelMode.freeSpin)
                    }
                    Toggle("SmartShift", isOn: Binding(
                        get: { mx.smartShiftEnabled },
                        set: { enabled in Task { await engine.setMxMasterSmartShift(wheelMode: mx.wheelMode, smartShiftEnabled: enabled, threshold: mx.smartShiftThreshold) } }
                    ))
                    if mx.smartShiftEnabled && mx.wheelMode == .ratchet {
                        LevelSlider(title: "SmartShift Sensitivity", value: Int(mx.smartShiftThreshold), range: 1...50) { value in
                            Task { await engine.setMxMasterSmartShift(wheelMode: mx.wheelMode, smartShiftEnabled: true, threshold: UInt8(value)) }
                        }
                    }
                }
                SettingsSection(title: "Scrolling", footer: "Only this mouse is affected.") {
                    Toggle("Standard scroll direction", isOn: mxBinding(\.standardVerticalScroll))
                    Toggle("Smooth scrolling", isOn: mxBinding(\.smoothScrolling))
                    ValueSlider(title: "Scroll Speed", value: mxSpeed, range: 0.5...3.0, step: 0.25, format: { String(format: "%.2f×", $0) })
                }
                SettingsSection(title: "Thumbwheel") {
                    Picker("Action", selection: Binding(
                        get: { mx.thumbwheelAction },
                        set: { action in updateMx { $0.thumbwheelAction = action } }
                    )) {
                        Text("Horizontal Scroll").tag(CoreThumbwheelAction.horizontalScroll)
                        Text("Display Brightness").tag(CoreThumbwheelAction.displayBrightness)
                        Text("Display Volume").tag(CoreThumbwheelAction.displayVolume)
                        Text("Switch Spaces").tag(CoreThumbwheelAction.switchWorkspaces)
                        Text("Switch Tabs").tag(CoreThumbwheelAction.switchTabs)
                        Text("Zoom").tag(CoreThumbwheelAction.zoom)
                    }
                    Toggle("Invert direction", isOn: mxBinding(\.invertThumbwheel))
                }
                SettingsSection(title: "Buttons", footer: "System Default keeps the button's normal behavior.") {
                    buttonPicker("Middle", mx.middleButtonAction) { action in updateMx { $0.middleButtonAction = CoreButtonAction(swift: action) } }
                    buttonPicker("Back", mx.backButtonAction) { action in updateMx { $0.backButtonAction = CoreButtonAction(swift: action) } }
                    buttonPicker("Forward", mx.forwardButtonAction) { action in updateMx { $0.forwardButtonAction = CoreButtonAction(swift: action) } }
                    buttonPicker("Gesture", mx.gestureButtonAction) { action in updateMx { $0.gestureButtonAction = CoreButtonAction(swift: action) } }
                    buttonPicker("Mode Shift", mx.modeShiftButtonAction) { action in updateMx { $0.modeShiftButtonAction = CoreButtonAction(swift: action) } }
                    buttonPicker("Haptic Panel", mx.hapticPanelButtonAction) { action in updateMx { $0.hapticPanelButtonAction = CoreButtonAction(swift: action) } }
                }
                SettingsSection(title: "Gestures") {
                    Toggle("Hold-and-drag gestures", isOn: mxBinding(\.gesturesEnabled))
                    if mx.gesturesEnabled {
                        buttonPicker("Up", mx.gestureUpAction) { action in updateMx { $0.gestureUpAction = CoreButtonAction(swift: action) } }
                        buttonPicker("Down", mx.gestureDownAction) { action in updateMx { $0.gestureDownAction = CoreButtonAction(swift: action) } }
                        buttonPicker("Left", mx.gestureLeftAction) { action in updateMx { $0.gestureLeftAction = CoreButtonAction(swift: action) } }
                        buttonPicker("Right", mx.gestureRightAction) { action in updateMx { $0.gestureRightAction = CoreButtonAction(swift: action) } }
                    }
                }
            }
        }
    }

    private var mxSpeed: Binding<Double> {
        Binding(
            get: { mx?.scrollSpeedMultiplier ?? 1 },
            set: { value in updateMx { $0.scrollSpeedMultiplier = value } }
        )
    }

    private func mxBinding(_ keyPath: WritableKeyPath<CoreMxMasterOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { mx?.options()[keyPath: keyPath] ?? false },
            set: { value in updateMx { $0[keyPath: keyPath] = value } }
        )
    }

    private func updateMx(_ change: @escaping (inout CoreMxMasterOptions) -> Void) {
        guard var options = mx?.options() else { return }
        change(&options)
        Task { await engine.setMxMasterOptions(options) }
    }

    private func buttonPicker(_ title: String, _ selection: CoreButtonAction, _ set: @escaping (AccessoryButtonAction) -> Void) -> some View {
        ActionPicker(title: title, selection: Binding(
            get: { selection.swiftAction },
            set: set
        ), actions: AccessoryButtonAction.allCases)
    }

    private var mxKeyboardSettings: some View {
        Group {
            if let keyboard = engine.snapshot?.accessories.mxKeyboard {
                SettingsSection(title: "Backlight") {
                    Toggle("Backlight", isOn: Binding(
                        get: { keyboard.backlightEnabled },
                        set: { enabled in setKeyboard(keyboard, enabled: enabled) }
                    ))
                    Toggle("Automatic brightness", isOn: Binding(
                        get: { keyboard.automaticBrightness },
                        set: { auto in setKeyboard(keyboard, automatic: auto) }
                    ))
                    LevelSlider(title: "Brightness", value: Int(keyboard.backlightLevel), range: 1...7, commitsWhileDragging: true) { level in
                        setKeyboard(keyboard, level: UInt8(level))
                    }
                    Toggle("Use F1–F12 as standard function keys", isOn: Binding(
                        get: { keyboard.fnInversion ?? false },
                        set: { standard in Task { await engine.setMxKeyboardFnInversion(standardFn: standard) } }
                    ))
                }
                SettingsSection(title: "Key Remapping", footer: "Only this keyboard's keys change.") {
                    ForEach(1...12, id: \.self) { position in
                        let current = keyboard.keyActions[UInt8(position)] ?? .systemDefault
                        ActionPicker(title: "F\(position)", selection: Binding(
                            get: { current.swiftAction },
                            set: { action in
                                Task { await engine.setMxKeyboardKeyAction(position: UInt8(position), action: CoreButtonAction(swift: action)) }
                            }
                        ))
                    }
                }
            }
        }
    }

    private func setKeyboard(_ keyboard: CoreMxKeyboardState, enabled: Bool? = nil, automatic: Bool? = nil, level: UInt8? = nil) {
        Task {
            await engine.setMxKeyboardBacklight(
                enabled: enabled ?? keyboard.backlightEnabled,
                autoBrightness: automatic ?? keyboard.automaticBrightness,
                batterySaving: keyboard.batterySaving,
                level: level ?? keyboard.backlightLevel,
                durationSeconds: keyboard.durationSeconds,
                effect: keyboard.backlightEffect
            )
        }
    }

    private var gMouseSettings: some View {
        Group {
            if let mouse = engine.snapshot?.accessories.logitechGMouse {
                SettingsSection(title: "Performance") {
                    DPIControl(dpi: Int(mouse.dpi), presets: [400, 800, 1600, 3200, 6400], range: Int(mouse.minDpi)...Int(mouse.maxDpi)) { dpi in
                        Task { await engine.setLogitechGDpi(UInt16(dpi)) }
                    }
                    if !mouse.supportedReportRates.isEmpty {
                        Picker("Report Rate", selection: Binding(
                            get: { mouse.reportRateHz },
                            set: { hz in Task { await engine.setLogitechGReportRate(hz) } }
                        )) {
                            ForEach(mouse.supportedReportRates, id: \.self) { hz in
                                Text("\(hz) Hz").tag(hz)
                            }
                        }
                    }
                    if let triggers = mouse.triggers {
                        LevelSlider(title: "Actuation", value: Int(triggers.actuation), range: 1...10) { value in
                            Task {
                                await engine.setLogitechGTriggers(CoreTriggerSettings(
                                    actuation: UInt8(value),
                                    rapidTrigger: triggers.rapidTrigger,
                                    haptics: triggers.haptics
                                ))
                            }
                        }
                    }
                }
                SettingsSection(title: "Side Buttons") {
                    ActionPicker(title: "Back", selection: Binding(
                        get: { mouse.backButtonAction.swiftAction },
                        set: { action in
                            Task { await engine.setLogitechGOptions(backButton: CoreButtonAction(swift: action), forwardButton: mouse.forwardButtonAction, savesToOnboardProfile: mouse.savesToOnboardProfile) }
                        }
                    ))
                    ActionPicker(title: "Forward", selection: Binding(
                        get: { mouse.forwardButtonAction.swiftAction },
                        set: { action in
                            Task { await engine.setLogitechGOptions(backButton: mouse.backButtonAction, forwardButton: CoreButtonAction(swift: action), savesToOnboardProfile: mouse.savesToOnboardProfile) }
                        }
                    ))
                }
            }
        }
    }

    private var gKeyboardSettings: some View {
        Group {
            if let keyboard = engine.snapshot?.accessories.logitechGKeyboard {
                SettingsSection(title: "Lighting") {
                    LevelSlider(title: "Brightness", value: Int(keyboard.brightness), range: 0...Int(max(1, keyboard.maxBrightness)), commitsWhileDragging: true) { value in
                        Task { await engine.setGKeyboardLighting(brightness: UInt16(value), lighting: keyboard.lighting) }
                    }
                }
            }
        }
    }

    private var keychronSettings: some View {
        Group {
            if let mouse = engine.snapshot?.accessories.keychronM3Mini {
                SettingsSection(title: "Performance") {
                    DPIControl(dpi: Int(mouse.stageDpis.first ?? 1600), presets: [800, 1600, 3200, 6400], range: 100...26000) { dpi in
                        Task {
                            await engine.setKeychronSettings(
                                activeStage: mouse.activeStage,
                                dpi: UInt16(dpi),
                                reportRateHz: mouse.reportRateHz,
                                liftOffMm: mouse.liftOffMm,
                                motionSync: mouse.motionSync,
                                angleSnapping: mouse.angleSnapping
                            )
                        }
                    }
                    Toggle("Motion Sync", isOn: Binding(
                        get: { mouse.motionSync },
                        set: { on in
                            Task {
                                await engine.setKeychronSettings(
                                    activeStage: mouse.activeStage,
                                    dpi: mouse.stageDpis.first ?? 1600,
                                    reportRateHz: mouse.reportRateHz,
                                    liftOffMm: mouse.liftOffMm,
                                    motionSync: on,
                                    angleSnapping: mouse.angleSnapping
                                )
                            }
                        }
                    ))
                }
                SettingsSection(title: "Side Buttons", footer: "The mouse sends the shortcut itself.") {
                    ActionPicker(title: "Back", selection: Binding(
                        get: { mouse.backButtonAction.swiftAction },
                        set: { action in
                            Task { await engine.setKeychronSideButtons(backButton: CoreButtonAction(swift: action), forwardButton: mouse.forwardButtonAction) }
                        }
                    ))
                    ActionPicker(title: "Forward", selection: Binding(
                        get: { mouse.forwardButtonAction.swiftAction },
                        set: { action in
                            Task { await engine.setKeychronSideButtons(backButton: mouse.backButtonAction, forwardButton: CoreButtonAction(swift: action)) }
                        }
                    ))
                }
            }
        }
    }

    private var razerSettings: some View {
        Group {
            if let dock = engine.snapshot?.accessories.razerDock {
                SettingsSection(title: "Lighting") {
                    LevelSlider(title: "Brightness", value: Int(dock.brightness ?? 0), range: 0...100, commitsWhileDragging: true) { value in
                        Task { await engine.setRazerDockLighting(brightness: UInt8(value), lighting: dock.lighting) }
                    }
                }
            }
        }
    }
}

// MARK: - Selector

private struct AccessorySelector: View {
    let pages: [AccessoryPage]
    let selectedID: String
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(pages) { page in
                    Button {
                        onSelect(page.id)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: page.systemImage)
                                .font(.system(size: 20))
                                .foregroundStyle(page.id == selectedID ? Color.accentColor : Color.primary)
                                .frame(width: 60, height: 42)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(page.id == selectedID ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
                                )
                            HStack(spacing: 4) {
                                StatusDot(isActive: page.connected)
                                Text(page.title)
                                    .font(.system(size: 11, weight: page.id == selectedID ? .semibold : .regular))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: 82)
                        }
                        .frame(width: 84)
                    }
                    .buttonStyle(.plain)
                    .opacity(page.connected ? 1 : 0.45)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
    }
}
