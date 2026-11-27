import AppKit
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
        .onAppear {
            Task { await engine.refreshAccessoriesAndDocks() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await engine.refreshAccessoriesAndDocks() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            Task { await engine.systemDidWake() }
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
            Button("Rescan") {
                Task { await engine.refreshAccessoriesAndDocks() }
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
        case "satechi": satechiSettings
        default: EmptyView()
        }
    }

    private var mx: CoreMxMasterState? { engine.snapshot?.accessories.mxMaster }

    private var mxMasterSettings: some View {
        Group {
            if let mx {
                SettingsSection(title: "Performance", footer: "SmartShift switches the wheel to free-spin when you flick it.") {
                    DPIControl(
                        dpi: Int(mx.dpi),
                        presets: [800, 1200, 1600, 2400, 4000, 8000],
                        range: Int(mx.minDpi)...max(Int(mx.minDpi), Int(mx.maxDpi))
                    ) { dpi in
                        let snapped = snapDpi(dpi, min: Int(mx.minDpi), max: Int(mx.maxDpi), step: Int(mx.dpiStep))
                        Task { await engine.setMxMasterDpi(UInt16(snapped)) }
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
                SettingsSection(
                    title: "Onboard Memory",
                    footer: "Saves buttons set to Back, Forward, or Ratchet / Free-Spin to the mouse so they keep working without Aeron Tools."
                ) {
                    Toggle("Save settings to the mouse", isOn: mxBinding(\.savesToMouse))
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
                SettingsSection(title: "Backlight", footer: "Battery saving turns the backlight off below 10% battery. The keyboard's own backlight keys still work.") {
                    Toggle("Backlight", isOn: Binding(
                        get: { keyboard.backlightEnabled },
                        set: { enabled in setKeyboard(keyboard, enabled: enabled) }
                    ))
                    if keyboard.supportedEffects.count > 1 {
                        Picker("Effect", selection: Binding(
                            get: { keyboard.backlightEffect },
                            set: { effect in setKeyboard(keyboard, effect: effect) }
                        )) {
                            ForEach(keyboard.supportedEffects, id: \.self) { effect in
                                Text(effect.title).tag(effect)
                            }
                        }
                        .disabled(!keyboard.backlightEnabled)
                    }
                    Toggle("Automatic brightness", isOn: Binding(
                        get: { keyboard.automaticBrightness },
                        set: { auto in setKeyboard(keyboard, automatic: auto) }
                    ))
                    .disabled(!keyboard.backlightEnabled)
                    if !keyboard.automaticBrightness {
                        LevelSlider(title: "Brightness", value: Int(keyboard.backlightLevel), range: 1...7, commitsWhileDragging: true) { level in
                            setKeyboard(keyboard, level: UInt8(level))
                        }
                        .disabled(!keyboard.backlightEnabled)
                    }
                    Picker("Turn off after", selection: Binding(
                        get: { keyboard.durationSeconds },
                        set: { seconds in setKeyboard(keyboard, durationSeconds: seconds) }
                    )) {
                        ForEach(backlightDurations(including: keyboard.durationSeconds), id: \.self) { seconds in
                            Text(formatDuration(seconds)).tag(seconds)
                        }
                    }
                    .disabled(!keyboard.backlightEnabled)
                    Toggle("Battery saving", isOn: Binding(
                        get: { keyboard.batterySaving },
                        set: { saving in setKeyboard(keyboard, batterySaving: saving) }
                    ))
                    .disabled(!keyboard.backlightEnabled)
                }
                SettingsSection(title: "Keys", footer: "When on, press Fn for the media functions printed on the keys.") {
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

    private func setKeyboard(
        _ keyboard: CoreMxKeyboardState,
        enabled: Bool? = nil,
        automatic: Bool? = nil,
        batterySaving: Bool? = nil,
        level: UInt8? = nil,
        durationSeconds: UInt16? = nil,
        effect: CoreBacklightEffect? = nil
    ) {
        Task {
            await engine.setMxKeyboardBacklight(
                enabled: enabled ?? keyboard.backlightEnabled,
                autoBrightness: automatic ?? keyboard.automaticBrightness,
                batterySaving: batterySaving ?? keyboard.batterySaving,
                level: level ?? keyboard.backlightLevel,
                durationSeconds: durationSeconds ?? keyboard.durationSeconds,
                effect: effect ?? keyboard.backlightEffect
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
                            setGTriggers(triggers, actuation: UInt8(value))
                        }
                        LevelSlider(title: "Rapid Trigger", value: Int(triggers.rapidTrigger), range: 0...5, lowestLabel: "Off") { value in
                            setGTriggers(triggers, rapidTrigger: UInt8(value))
                        }
                        LevelSlider(title: "Haptic Feedback", value: Int(triggers.haptics), range: 0...5, lowestLabel: "Off") { value in
                            setGTriggers(triggers, haptics: UInt8(value))
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
                SettingsSection(
                    title: "Onboard Memory",
                    footer: "Saves DPI, report rate, triggers, and side buttons to the mouse's onboard profile so they persist without Aeron Tools."
                ) {
                    Toggle("Save settings to the mouse", isOn: Binding(
                        get: { mouse.savesToOnboardProfile },
                        set: { save in
                            Task {
                                await engine.setLogitechGOptions(
                                    backButton: mouse.backButtonAction,
                                    forwardButton: mouse.forwardButtonAction,
                                    savesToOnboardProfile: save
                                )
                            }
                        }
                    ))
                }
            }
        }
    }

    private func setGTriggers(
        _ triggers: CoreTriggerSettings,
        actuation: UInt8? = nil,
        rapidTrigger: UInt8? = nil,
        haptics: UInt8? = nil
    ) {
        Task {
            await engine.setLogitechGTriggers(CoreTriggerSettings(
                actuation: actuation ?? triggers.actuation,
                rapidTrigger: rapidTrigger ?? triggers.rapidTrigger,
                haptics: haptics ?? triggers.haptics
            ))
        }
    }

    private var gKeyboardSettings: some View {
        Group {
            if let keyboard = engine.snapshot?.accessories.logitechGKeyboard {
                SettingsSection(title: "Lighting", footer: "Quit G HUB so it doesn't overwrite onboard effects.") {
                    if !keyboard.supportedEffects.isEmpty {
                        Picker("Effect", selection: Binding(
                            get: { keyboard.lighting.effect },
                            set: { effect in
                                var lighting = keyboard.lighting
                                lighting.effect = effect
                                Task { await engine.setGKeyboardLighting(brightness: keyboard.brightness, lighting: lighting) }
                            }
                        )) {
                            ForEach(keyboard.supportedEffects, id: \.self) { effect in
                                Text(effect.title).tag(effect)
                            }
                        }
                    }
                    if keyboard.lighting.effect.usesColor {
                        ColorPicker("Color", selection: Binding(
                            get: { Color(rgb: keyboard.lighting.color) },
                            set: { color in
                                var lighting = keyboard.lighting
                                lighting.color = color.rgbColor
                                Task { await engine.setGKeyboardLighting(brightness: keyboard.brightness, lighting: lighting) }
                            }
                        ), supportsOpacity: false)
                    }
                    if keyboard.lighting.effect.usesSpeed {
                        LevelSlider(title: "Speed", value: Int(keyboard.lighting.speed), range: 1...10) { speed in
                            var lighting = keyboard.lighting
                            lighting.speed = UInt8(speed)
                            Task { await engine.setGKeyboardLighting(brightness: keyboard.brightness, lighting: lighting) }
                        }
                    }
                    LevelSlider(
                        title: "Brightness",
                        value: Int(keyboard.brightness),
                        range: 0...Int(max(1, keyboard.maxBrightness)),
                        lowestLabel: "Off",
                        commitsWhileDragging: true
                    ) { value in
                        Task { await engine.setGKeyboardLighting(brightness: UInt16(value), lighting: keyboard.lighting) }
                    }
                }
                SettingsSection(title: "Game Mode", footer: "Switch game mode with the game mode key on the keyboard.") {
                    LabeledContent("Keyboard Game Mode") {
                        HStack(spacing: 6) {
                            StatusDot(isActive: keyboard.gameModeOn)
                            Text(keyboard.gameModeOn ? "On" : "Off")
                        }
                    }
                }
            }
        }
    }

    private var keychronSettings: some View {
        Group {
            if let mouse = engine.snapshot?.accessories.keychronM3Mini {
                let overBluetooth = mouse.connection == .bluetoothLe
                if overBluetooth {
                    SettingsSection(title: "Connection", footer: "The 2.4 GHz receiver is required to change settings. Battery still updates over Bluetooth.") {
                        LabeledContent("Controls", value: "Unavailable")
                    }
                }
                SettingsSection(title: "Performance", footer: "DPI applies to the active stage. Changes are saved to onboard memory.") {
                    if !mouse.stageDpis.isEmpty {
                        Picker("Active DPI Stage", selection: Binding(
                            get: { mouse.activeStage },
                            set: { stage in setKeychron(mouse, activeStage: stage, dpi: keychronStageDpi(mouse, stage: stage)) }
                        )) {
                            ForEach(Array(mouse.stageDpis.enumerated()), id: \.offset) { index, dpi in
                                Text("S\(index + 1) · \(dpi)").tag(UInt8(index))
                            }
                        }
                    }
                    DPIControl(dpi: Int(keychronStageDpi(mouse)), presets: [800, 1600, 3200, 6400], range: 100...26000) { dpi in
                        setKeychron(mouse, dpi: UInt16(dpi))
                    }
                    Picker("Report Rate", selection: Binding(
                        get: { mouse.reportRateHz },
                        set: { hz in setKeychron(mouse, reportRateHz: hz) }
                    )) {
                        ForEach(keychronRates(maxHz: mouse.maxReportRateHz, including: mouse.reportRateHz), id: \.self) { hz in
                            Text(formatRate(hz)).tag(hz)
                        }
                    }
                }
                .disabled(overBluetooth)
                SettingsSection(title: "Sensor") {
                    Picker("Lift-off distance", selection: Binding(
                        get: { mouse.liftOffMm },
                        set: { mm in setKeychron(mouse, liftOffMm: mm) }
                    )) {
                        Text("1 mm").tag(UInt8(1))
                        Text("2 mm").tag(UInt8(2))
                    }
                    Toggle("Motion Sync", isOn: Binding(
                        get: { mouse.motionSync },
                        set: { on in setKeychron(mouse, motionSync: on) }
                    ))
                    Toggle("Angle snapping", isOn: Binding(
                        get: { mouse.angleSnapping },
                        set: { on in setKeychron(mouse, angleSnapping: on) }
                    ))
                }
                .disabled(overBluetooth)
                SettingsSection(title: "Side Buttons", footer: "Saved to the mouse so the buttons keep working without Aeron Tools.") {
                    ActionPicker(title: "Back", selection: Binding(
                        get: { mouse.backButtonAction.swiftAction },
                        set: { action in
                            Task { await engine.setKeychronSideButtons(backButton: CoreButtonAction(swift: action), forwardButton: mouse.forwardButtonAction) }
                        }
                    ), actions: AccessoryButtonAction.keychron)
                    ActionPicker(title: "Forward", selection: Binding(
                        get: { mouse.forwardButtonAction.swiftAction },
                        set: { action in
                            Task { await engine.setKeychronSideButtons(backButton: mouse.backButtonAction, forwardButton: CoreButtonAction(swift: action)) }
                        }
                    ), actions: AccessoryButtonAction.keychron)
                }
                .disabled(overBluetooth)
            }
        }
    }

    private func keychronStageDpi(_ mouse: CoreKeychronM3MiniState, stage: UInt8? = nil) -> UInt16 {
        let index = Int(stage ?? mouse.activeStage)
        guard mouse.stageDpis.indices.contains(index) else { return 1600 }
        return mouse.stageDpis[index]
    }

    private func setKeychron(
        _ mouse: CoreKeychronM3MiniState,
        activeStage: UInt8? = nil,
        dpi: UInt16? = nil,
        reportRateHz: UInt16? = nil,
        liftOffMm: UInt8? = nil,
        motionSync: Bool? = nil,
        angleSnapping: Bool? = nil
    ) {
        let stage = activeStage ?? mouse.activeStage
        Task {
            await engine.setKeychronSettings(
                activeStage: stage,
                dpi: dpi ?? keychronStageDpi(mouse, stage: stage),
                reportRateHz: reportRateHz ?? mouse.reportRateHz,
                liftOffMm: liftOffMm ?? mouse.liftOffMm,
                motionSync: motionSync ?? mouse.motionSync,
                angleSnapping: angleSnapping ?? mouse.angleSnapping
            )
        }
    }

    private var razerSettings: some View {
        Group {
            if let dock = engine.snapshot?.accessories.razerDock {
                SettingsSection(title: "Ports", footer: "Thunderbolt devices take the first free Thunderbolt port, since macOS doesn't tell which one they're in.") {
                    CoreDockPortsDiagram(layout: dock.ports, showsEthernetSlot: true)
                }
                SettingsSection(title: "Lighting", footer: "Saved on the dock, so it keeps its Chroma underglow without the app.") {
                    if let lighting = dock.lighting {
                        Picker("Effect", selection: Binding(
                            get: { lighting.mode ?? .off },
                            set: { mode in
                                var next = lighting
                                next.mode = mode
                                setRazer(lighting: next)
                            }
                        )) {
                            Text("Off").tag(CoreRazerMode.off)
                            Text("Static").tag(CoreRazerMode.staticColor)
                            Text("Breathing").tag(CoreRazerMode.breathing)
                            Text("Spectrum Cycling").tag(CoreRazerMode.spectrum)
                            Text("Wave").tag(CoreRazerMode.wave)
                        }
                        if lighting.mode == .staticColor {
                            razerColorPicker("Color", lighting: lighting, primary: true)
                        }
                        if lighting.mode == .breathing {
                            Picker("Colors", selection: Binding(
                                get: { lighting.breathing },
                                set: { style in
                                    var next = lighting
                                    next.breathing = style
                                    setRazer(lighting: next)
                                }
                            )) {
                                Text("Single").tag(CoreBreathingStyle.single)
                                Text("Dual").tag(CoreBreathingStyle.dual)
                                Text("Random").tag(CoreBreathingStyle.random)
                            }
                            if lighting.breathing != .random {
                                razerColorPicker(lighting.breathing == .dual ? "First Color" : "Color", lighting: lighting, primary: true)
                            }
                            if lighting.breathing == .dual {
                                razerColorPicker("Second Color", lighting: lighting, primary: false)
                            }
                        }
                        if lighting.mode == .wave {
                            Picker("Direction", selection: Binding(
                                get: { lighting.waveDirection },
                                set: { direction in
                                    var next = lighting
                                    next.waveDirection = direction
                                    setRazer(lighting: next)
                                }
                            )) {
                                Text("Left → Right").tag(CoreWaveDirection.leftToRight)
                                Text("Right → Left").tag(CoreWaveDirection.rightToLeft)
                            }
                        }
                        if let mode = lighting.mode, mode != .off, let raw = dock.brightness {
                            LevelSlider(
                                title: "Brightness",
                                value: razerPercent(raw),
                                range: 0...100,
                                lowestLabel: "Off",
                                commitsWhileDragging: true
                            ) { percent in
                                setRazer(brightness: razerRaw(percent), lighting: nil)
                            }
                        }
                    } else {
                        LabeledContent("Effect", value: "Not read")
                    }
                }
                if dock.serialNumber != nil || dock.firmware != nil {
                    SettingsSection(title: "About") {
                        if let serial = dock.serialNumber {
                            LabeledContent("Serial Number", value: serial)
                        }
                        if let firmware = dock.firmware {
                            LabeledContent("Lighting Firmware", value: firmware)
                        }
                    }
                }
            }
        }
    }

    private func razerColorPicker(_ title: String, lighting: CoreRazerLighting, primary: Bool) -> some View {
        ColorPicker(title, selection: Binding(
            get: { Color(razer: primary ? lighting.primary : lighting.secondary) },
            set: { color in
                var next = lighting
                if primary {
                    next.primary = color.razerRgb
                } else {
                    next.secondary = color.razerRgb
                }
                setRazer(lighting: next)
            }
        ), supportsOpacity: false)
    }

    private func setRazer(brightness: UInt8? = nil, lighting: CoreRazerLighting? = nil) {
        Task { await engine.setRazerDockLighting(brightness: brightness, lighting: lighting) }
    }

    private var satechiSettings: some View {
        Group {
            if let hub = engine.snapshot?.accessories.satechiHub {
                SettingsSection(title: "Ports", footer: "Thunderbolt devices take the first free Thunderbolt port, since macOS doesn't tell which one they're in.") {
                    CoreDockPortsDiagram(layout: hub.ports, showsEthernetSlot: false)
                }
                if let serial = hub.ports.serialNumber {
                    SettingsSection(title: "About") {
                        LabeledContent("Serial Number", value: serial)
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

private func snapDpi(_ dpi: Int, min lower: Int, max upper: Int, step: Int) -> Int {
    let step = Swift.max(step, 1)
    let bounded = Swift.max(upper, lower)
    let snapped = ((dpi + step / 2) / step) * step
    return Swift.min(bounded, Swift.max(lower, snapped))
}

private let mxBacklightDurationChoices: [UInt16] = [5, 10, 15, 30, 45, 60, 90, 120, 180, 300]

private func backlightDurations(including current: UInt16) -> [UInt16] {
    var values = mxBacklightDurationChoices
    if !values.contains(current) {
        values.append(current)
        values.sort()
    }
    return values
}

private func formatDuration(_ seconds: UInt16) -> String {
    seconds < 60 ? "\(seconds) sec" : "\(seconds / 60) min"
}

private func formatRate(_ hz: UInt16) -> String {
    hz >= 1000 ? "\(hz / 1000) kHz" : "\(hz) Hz"
}

private func keychronRates(maxHz: UInt16, including current: UInt16) -> [UInt16] {
    var rates = [125, 250, 500, 1000, 2000, 4000].map(UInt16.init).filter { $0 <= maxHz }
    if !rates.contains(current) {
        rates.append(current)
        rates.sort()
    }
    return rates
}

private func razerPercent(_ raw: UInt8) -> Int {
    Int((Double(raw) / 2.55).rounded())
}

private func razerRaw(_ percent: Int) -> UInt8 {
    let raw = (Double(percent) * 2.55).rounded()
    return UInt8(Swift.min(255, Swift.max(0, raw)))
}

private extension CoreBacklightEffect {
    var title: String {
        switch self {
        case .staticLight: "Static"
        case .contrast: "Contrast"
        case .breathing: "Breathing"
        case .waves: "Waves"
        case .reaction: "Reaction"
        case .random: "Random"
        }
    }
}

private extension CoreRgbEffect {
    var title: String {
        switch self {
        case .off: "Off"
        case .fixed: "Fixed"
        case .breathing: "Breathing"
        case .colorCycle: "Color Cycle"
        case .colorWave: "Color Wave"
        }
    }

    var usesColor: Bool { self == .fixed || self == .breathing }
    var usesSpeed: Bool { self == .breathing || self == .colorCycle || self == .colorWave }
}

private extension Color {
    init(rgb: CoreRgbColor) {
        self.init(red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
    }

    init(razer: CoreRazerRgb) {
        self.init(red: Double(razer.red) / 255, green: Double(razer.green) / 255, blue: Double(razer.blue) / 255)
    }

    var rgbColor: CoreRgbColor {
        let bytes = rgbBytes
        return CoreRgbColor(red: bytes.0, green: bytes.1, blue: bytes.2)
    }

    var razerRgb: CoreRazerRgb {
        let bytes = rgbBytes
        return CoreRazerRgb(red: bytes.0, green: bytes.1, blue: bytes.2)
    }

    private var rgbBytes: (UInt8, UInt8, UInt8) {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return (
            UInt8((ns.redComponent * 255).rounded()),
            UInt8((ns.greenComponent * 255).rounded()),
            UInt8((ns.blueComponent * 255).rounded())
        )
    }
}

private struct CoreDockPortsDiagram: View {
    let layout: CoreDockLayout
    /// Razer always shows the Ethernet jack. Satechi shows it only when an interface is present.
    var showsEthernetSlot: Bool

    @State private var selectedID: String?

    private var showEthernet: Bool { showsEthernetSlot || layout.ethernetInterface != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 18) {
                if !layout.thunderbolt.isEmpty {
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            portMark(occupied: layout.isPresent, selected: false, kind: .thunderbolt, caption: "Host")
                            ForEach(layout.thunderbolt, id: \.id) { port in
                                portButton(port)
                            }
                        }
                        Text("Thunderbolt 4").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !layout.usbA.isEmpty {
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            ForEach(layout.usbA, id: \.id) { port in
                                portButton(port)
                            }
                        }
                        Text("USB-A").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if showEthernet {
                    VStack(spacing: 4) {
                        ethernetButton
                        Text("Ethernet").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            deviceList
        }
    }

    private func portButton(_ port: CoreDockPort) -> some View {
        let occupied = !port.devices.isEmpty
        let selected = selectedID == port.id
        return Button {
            selectedID = selected ? nil : port.id
        } label: {
            portMark(occupied: occupied, selected: selected, kind: port.kind, caption: "\(port.number)")
        }
        .buttonStyle(.plain)
        .help(occupied ? "\(port.title): \(port.devices.map(\.name).joined(separator: ", "))" : "\(port.title): empty")
    }

    private var ethernetButton: some View {
        let occupied = layout.ethernetInterface != nil
        let selected = selectedID == "ethernet"
        return Button {
            selectedID = selected ? nil : "ethernet"
        } label: {
            portMark(occupied: occupied, selected: selected, kind: .usbA, caption: layout.ethernetInterface ?? "—", ethernet: true)
        }
        .buttonStyle(.plain)
    }

    private func portMark(occupied: Bool, selected: Bool, kind: CoreDockPortKind, caption: String, ethernet: Bool = false) -> some View {
        VStack(spacing: 2) {
            Group {
                if ethernet {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(occupied ? Color.green : Color.secondary.opacity(0.5), lineWidth: selected ? 2 : 1)
                        .background(RoundedRectangle(cornerRadius: 2).fill(occupied ? Color.green.opacity(selected ? 0.45 : 0.25) : Color.primary.opacity(0.04)))
                        .frame(width: 22, height: 16)
                } else if kind == .thunderbolt {
                    Capsule()
                        .strokeBorder(occupied || selected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: selected ? 2 : 1)
                        .background(Capsule().fill(occupied ? Color.accentColor.opacity(selected ? 0.45 : 0.28) : Color.primary.opacity(0.04)))
                        .frame(width: 26, height: 14)
                } else {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(occupied || selected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: selected ? 2 : 1)
                        .background(RoundedRectangle(cornerRadius: 2).fill(occupied ? Color.accentColor.opacity(selected ? 0.45 : 0.28) : Color.primary.opacity(0.04)))
                        .frame(width: 28, height: 14)
                }
            }
            Text(caption).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(2)
        .background(selected ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder
    private var deviceList: some View {
        let ports = (layout.thunderbolt + layout.usbA).filter { port in
            if let selectedID, selectedID != "ethernet" { return port.id == selectedID }
            return selectedID == nil && !port.devices.isEmpty
        }
        let showEthernetRow = layout.ethernetInterface != nil && (selectedID == nil || selectedID == "ethernet")
        if ports.allSatisfy(\.devices.isEmpty) && !showEthernetRow {
            Text(emptyCaption).font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ports, id: \.id) { port in
                    ForEach(port.devices, id: \.id) { device in
                        HStack(spacing: 8) {
                            Image(systemName: dockSymbol(device.icon))
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name).font(.caption)
                                Text(device.detail.isEmpty ? port.title : "\(port.title) · \(device.detail)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if showEthernetRow, let interface = layout.ethernetInterface {
                    HStack(spacing: 8) {
                        Image(systemName: "network").foregroundStyle(.green).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Ethernet").font(.caption)
                            Text("Interface \(interface)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var emptyCaption: String {
        if selectedID == "ethernet" { return "No Ethernet interface detected." }
        if let selectedID, let port = (layout.thunderbolt + layout.usbA).first(where: { $0.id == selectedID }) {
            return "Nothing is plugged into \(port.title)."
        }
        return "Nothing is plugged in."
    }
}

private func dockSymbol(_ icon: String) -> String {
    switch icon {
    case "display": "display"
    case "wireless": "dot.radiowaves.left.and.right"
    case "keyboard": "keyboard"
    case "mouse": "computermouse"
    case "light": "lightbulb"
    case "storage": "externaldrive"
    case "audio": "speaker.wave.2"
    case "camera": "camera"
    case "gamepad": "gamecontroller"
    case "headphones": "headphones"
    case "mic": "mic"
    case "hub": "cable.connector"
    case "thunderbolt": "bolt.fill"
    case "ethernet": "network"
    default: "cable.connector"
    }
}
