import SwiftUI
import AppKit
import ServiceManagement

public struct SettingsView: View {
    @Bindable var model = DisplayStateModel.shared
    @Bindable var wireless = WirelessDisplayManager.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    private var accessibilityPermission = AccessibilityPermission.shared
    @State private var showTeslaSetupSheet = false
    @State private var showDiagnostics = false

    public init() {}

    public var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            displaysTab
                .tabItem {
                    Label("Displays", systemImage: "display.2")
                }

            wirelessTab
                .tabItem {
                    Label("Wireless", systemImage: "tv.and.mediabox")
                }

            AccessoriesSettingsTabView()
                .tabItem {
                    Label("Accessories", systemImage: "magicmouse")
                }

            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 580, height: 620)
        .padding(20)
        .sheet(isPresented: $showTeslaSetupSheet) {
            TeslaSetupGuideSheet(wireless: wireless)
        }
        .task {
            // Later changes (e.g. returning from System Settings) are picked up when the app reactivates.
            wireless.refreshPermissions()
            wireless.refreshNetworkInterfaces()
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Menu Bar & Dock") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show icon in menu bar", isOn: Binding(
                        get: { model.showMenuBarIcon },
                        set: { newValue in
                            if !newValue && !model.showDockIcon {
                                // Don't allow turning off both, keep Dock icon active
                                model.showDockIcon = true
                            }
                            model.showMenuBarIcon = newValue
                        }
                    ))
                    Text("Access display brightness, volume, and MacBook screen controls from the macOS menu bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Keep icon in Dock", isOn: Binding(
                        get: { model.showDockIcon },
                        set: { newValue in
                            if !newValue && !model.showMenuBarIcon {
                                // Don't allow turning off both, keep Menu Bar active
                                model.showMenuBarIcon = true
                            }
                            model.showDockIcon = newValue
                        }
                    ))
                    Text("Shows Aeron Tools in the Dock like a regular application so you can open it at any time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.showMenuBarIcon {
                    Picker("Show next to menu bar icon", selection: $model.menuBarStat) {
                        ForEach(MenuBarStat.allCases) { stat in
                            Text(stat.title).tag(stat)
                        }
                    }
                }

                if !model.showMenuBarIcon {
                    Text("Note: Because the menu bar icon is hidden, Aeron Tools will remain accessible from your Dock.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, enabled in
                            let isEnabled = SMAppService.mainApp.status == .enabled
                            // Reverting the toggle after a failure re-enters here; don't retry then.
                            guard enabled != isEnabled else { return }
                            do {
                                if enabled {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                dlog("Launch at login change failed: \(error.localizedDescription)")
                            }
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            loginItemNeedsApproval = SMAppService.mainApp.status == .requiresApproval
                        }
                    Text("Automatically launch Aeron Tools when you log in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if loginItemNeedsApproval {
                        HStack {
                            Text("Allow Aeron Tools in Login Items to finish setting this up.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Open Login Items…") {
                                SMAppService.openSystemSettingsLoginItems()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section("System Sleep & Caffeine") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Keep Mac awake (Caffeine)", isOn: $model.isCaffeinated)
                    Text("Prevents display sleep and idle system sleep while enabled. Use the cup's menu in the menu bar popover for a timer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Keep awake while an external display is connected", isOn: $model.caffeinateWhileExternalConnected)
                Toggle("Keep awake while Wireless Display is streaming", isOn: $model.caffeinateWhileStreaming)
                Toggle("Keep awake while on power adapter", isOn: $model.caffeinateWhileOnPower)
            }

            Section("Popover Cards") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show Wireless Display card in menu bar popover", isOn: $model.showWirelessDisplayCard)
                    Text("Quickly start or stop the wireless display and copy the stream URL from the menu bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show wattage meter in menu bar popover", isOn: $model.showWattageMeter)
                    Text("Displays real-time system power consumption and charger wattage while the popover is open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Show battery health and cycle count", isOn: $model.showBatteryHealth)
                    .disabled(!model.showWattageMeter)

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show thermals in menu bar popover", isOn: $model.showThermals)
                    Text("Displays CPU, GPU and battery temperatures plus fan speeds while the popover is open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show Accessories card in menu bar popover", isOn: $model.showAccessoriesCard)
                    Text("Shows battery and quick controls for connected accessories. Choose which parts appear in the Accessories tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Keyboard Shortcuts") {
                ForEach(HotKeyAction.allCases) { action in
                    ShortcutRecorder(action: action)
                }
                Text("Shortcuts work everywhere, even with the MacBook screen off. Use ⌘, ⌃ or ⌥ in each shortcut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Displays Tab

    private var displaysTab: some View {
        Form {
            if model.isBuiltinPresent {
                Section("MacBook Screen") {
                    // Turn-off controls only matter when another screen can take over (or to turn it back on)
                    if model.canTurnOffBuiltin || model.isBuiltinTurnedOff {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Current State")
                                    .font(.body.weight(.medium))
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(model.isBuiltinTurnedOff ? Color.secondary : Color.green)
                                        .frame(width: 7, height: 7)
                                    Text(model.isBuiltinTurnedOff ? "Turned Off" : "Active")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            Button(model.isBuiltinTurnedOff ? "Turn Screen On" : "Turn Screen Off") {
                                model.toggleBuiltinDisplay()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!model.canTurnOffBuiltin && !model.isBuiltinTurnedOff)
                        }

                        Toggle("Turn off automatically when external screen is connected", isOn: $model.autoTurnOffBuiltin)
                            .disabled(!model.hasExternalDisplays)

                        Toggle("Also turn off keyboard backlight when screen is off", isOn: $model.turnOffKeyboardWithScreen)
                    }

                    if let builtinID = model.activeBuiltinDisplayID {
                        DisplayModePicker(displayID: builtinID, model: model)
                    }
                }
            }

            Section("Brightness Automation") {
                Picker("External displays", selection: $model.brightnessAutomation) {
                    ForEach(BrightnessAutomation.allCases) { automation in
                        Text(automation.title).tag(automation)
                    }
                }

                switch model.brightnessAutomation {
                case .off:
                    EmptyView()
                case .matchMacBook:
                    Text("External displays follow the MacBook screen's brightness, including auto-brightness. Paused while the MacBook screen is off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .schedule:
                    DatePicker("Night starts", selection: timeBinding(\.scheduleNightStart), displayedComponents: .hourAndMinute)
                    levelSlider("Night brightness", value: $model.scheduleNightBrightness)
                    DatePicker("Day starts", selection: timeBinding(\.scheduleDayStart), displayedComponents: .hourAndMinute)
                    levelSlider("Day brightness", value: $model.scheduleDayBrightness)
                    Text("Applied when night or day begins and when a monitor connects. You can still adjust brightness in between.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Monitor Controls") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Restore brightness and volume when a monitor reconnects", isOn: $model.restoreMonitorSettings)
                    Text("When off, Aeron Tools reads the monitor's current values instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Show input switching in the menu bar popover", isOn: $model.showInputSwitching)
                Toggle("Show resolution menu in the menu bar popover", isOn: $model.showResolutionMenu)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Allow extra dimming below minimum brightness", isOn: $model.extraDimmingEnabled)
                    Text("Darkens the picture in software for dark rooms. Brightness-down continues into it once the monitor is at 0%.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Media Keys") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Control external monitors with brightness & volume keys", isOn: $model.mediaKeysControlPointerDisplay)
                    Text("Brightness keys adjust the monitor under the pointer. Volume keys adjust the monitor that sound is playing through.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.mediaKeysControlPointerDisplay && !accessibilityPermission.isGranted {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("Accessibility permission is required for media key interception.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Settings…") {
                            accessibilityPermission.openSystemSettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            Section("Sound") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Play sound through monitor when connected", isOn: $model.switchAudioToMonitor)
                    Text("Only switches when sound is playing through the MacBook speakers, never from headphones or external speakers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !model.externalDisplays.isEmpty {
                Section("Connected External Displays") {
                    ForEach(model.externalDisplays) { display in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(display.name)
                                .font(.body.weight(.medium))

                            // Brightness
                            HStack(spacing: 8) {
                                Image(systemName: "sun.min.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Slider(
                                    value: Binding(
                                        get: { display.brightness },
                                        set: { model.updateBrightness(for: display.id, level: $0) }
                                    ),
                                    in: 0...1
                                )
                                .controlSize(.small)
                                Image(systemName: "sun.max.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(Int(display.brightness * 100))%")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 38, alignment: .trailing)
                            }

                            // Volume
                            HStack(spacing: 8) {
                                Button {
                                    model.toggleMonitorMuted(for: display.id)
                                } label: {
                                    Image(systemName: display.isMuted ? "speaker.slash.fill" : "speaker.fill")
                                        .font(.caption)
                                        .foregroundStyle(display.isMuted ? .red : .secondary)
                                }
                                .buttonStyle(.plain)

                                Slider(
                                    value: Binding(
                                        get: { display.volume },
                                        set: { model.updateVolume(for: display.id, level: $0) }
                                    ),
                                    in: 0...1
                                )
                                .controlSize(.small)
                                .disabled(display.isMuted)

                                Image(systemName: "speaker.wave.3.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text(display.isMuted ? "Muted" : "\(Int(display.volume * 100))%")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 38, alignment: .trailing)
                            }

                            if model.extraDimmingEnabled {
                                HStack(spacing: 8) {
                                    Image(systemName: "moon.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Slider(
                                        value: Binding(
                                            get: { 1 - display.extraDimming },
                                            set: { model.updateExtraDimming(for: display.id, level: 1 - $0) }
                                        ),
                                        in: 0...(1 - DisplayStateModel.minimumExtraDimming)
                                    )
                                    .controlSize(.small)
                                    Text(display.extraDimming >= 0.999 ? "Off" : "\(Int(((1 - display.extraDimming) * 100).rounded()))%")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 38, alignment: .trailing)
                                }
                            }

                            if display.hasHardwareControl {
                                Picker("Input", selection: Binding(
                                    get: { display.currentInput ?? 0 },
                                    set: { model.selectInput($0, for: display.id) }
                                )) {
                                    if display.currentInput == nil {
                                        Text("Unknown").tag(UInt8(0))
                                    }
                                    ForEach(model.inputChoices(for: display), id: \.self) { code in
                                        Text(InputSource.name(for: code)).tag(code)
                                    }
                                }
                            } else {
                                Text("No DDC/CI: brightness is dimmed in software and input switching is unavailable.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            DisplayModePicker(displayID: display.id, model: model)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Wireless Tab

    private var wirelessTab: some View {
        WirelessSettingsTabView(wireless: wireless, showTeslaSetupSheet: $showTeslaSetupSheet, showDiagnostics: $showDiagnostics)
    }

    private func timeBinding(_ keyPath: ReferenceWritableKeyPath<DisplayStateModel, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = model[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { model[keyPath: keyPath] = BrightnessSchedule.minuteOfDay($0) }
        )
    }

    private func levelSlider(_ title: String, value: Binding<Float>) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Slider(value: value, in: 0...1)
                .controlSize(.small)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 84, height: 84)

            Text("Aeron Tools")
                .font(.title2.bold())

            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Control external monitor brightness and sound, turn off the built-in MacBook display, stream a Wireless Extended Display to Tesla or iPad, and monitor live power & thermals.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            Text("© 2026 Aeron Labs")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - WirelessSettingsTabView

private struct WirelessSettingsTabView: View {
    @Bindable var wireless: WirelessDisplayManager
    private var accessibilityPermission = AccessibilityPermission.shared
    @Binding var showTeslaSetupSheet: Bool
    @Binding var showDiagnostics: Bool

    var body: some View {
        Form {
            Section("Wireless Display") {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(wireless.isStreaming ? Color.green : Color.secondary)
                                .frame(width: 8, height: 8)
                            Text(wireless.isStreaming ? "Streaming Active" : "Ready to Stream")
                                .font(.body.weight(.semibold))
                        }
                        Text(wireless.primaryStreamURL)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(wireless.isStreaming ? Color.accentColor : .secondary)
                            .textSelection(.enabled)
                    }

                    Spacer()

                    Button {
                        wireless.copyURLToClipboard()
                    } label: {
                        Label("Copy URL", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if wireless.isStreaming {
                        Button {
                            wireless.openInLocalBrowser()
                        } label: {
                            Label("Open Viewer", systemImage: "safari")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button {
                        wireless.toggleSession()
                    } label: {
                        Label(
                            wireless.isStreaming ? "Stop" : "Start",
                            systemImage: wireless.isStreaming ? "stop.fill" : "play.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(wireless.isStreaming ? .red : .accentColor)
                    .disabled(wireless.isStartingOrStopping)
                }

                if wireless.isStreaming {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.black.opacity(0.82))
                            if let preview = wireless.previewImage {
                                Image(decorative: preview, scale: 1.0)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            } else {
                                Image(systemName: "tv.and.mediabox")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 112, height: 70)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(wireless.config.sourceType.rawValue)
                                .font(.caption.weight(.semibold))
                            Text("Output: \(wireless.config.preset.width)×\(wireless.config.preset.height) (\(wireless.config.preset.aspectRatioLabel)) · Desktop: \(wireless.config.logicalWidth)×\(wireless.config.logicalHeight)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                let fps = Int(wireless.measuredFPS.rounded())
                                Text(fps > 0 ? "\(fps) FPS" : "Active")
                                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                                    .foregroundStyle(.green)
                                if wireless.frameKB > 0 {
                                    Text("\(wireless.frameKB) KB/frame")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                    }
                    .padding(.top, 2)
                }
            }

            Section("Display Configuration") {
                Picker("Mode", selection: $wireless.config.sourceType) {
                    ForEach(DisplaySourceType.allCases) { source in
                        Text(source.rawValue).tag(source)
                    }
                }

                Picker("Target Resolution", selection: $wireless.config.preset) {
                    ForEach(DisplayPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }

                Picker("UI Scaling", selection: $wireless.config.scale) {
                    ForEach(DisplayScale.allCases) { scale in
                        Text(scale.rawValue).tag(scale)
                    }
                }

                Picker("Frame Rate", selection: $wireless.config.fps) {
                    Text("20 FPS (Power Saver)").tag(20)
                    Text("30 FPS (Recommended)").tag(30)
                    Text("45 FPS").tag(45)
                    Text("60 FPS (Smooth)").tag(60)
                }

                HStack {
                    Text("Stream Quality")
                    Spacer()
                    Slider(value: $wireless.config.jpegQuality, in: 0.35...0.92)
                        .frame(width: 180)
                    Text("\(Int((wireless.config.jpegQuality * 100).rounded()))%")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }

                Toggle("Allow touch & pointer control from browser", isOn: $wireless.config.allowTouch)
            }

            Section("Network & Tesla Hotspot") {
                Picker("Connection Mode", selection: $wireless.connectionMode) {
                    ForEach(ConnectionMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }

                Text(wireless.connectionMode.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if wireless.connectionMode != .sameNetwork {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tesla Browser Bridge (198.18.0.1)")
                                .font(.caption.weight(.semibold))
                            Text("Binds 198.18.0.1 on bridge100 so Tesla Chromium allows local hotspot traffic.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Configure 198.18.0.1") {
                            wireless.applyTeslaHotspotAliasWithAdminPrompt()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Setup Guide…") {
                            showTeslaSetupSheet = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                HStack {
                    Text("HTTP Port")
                    Spacer()
                    TextField(
                        "Port",
                        value: Binding(
                            get: { Int(wireless.serverPort) },
                            set: { newVal in
                                if (1024...65535).contains(newVal) {
                                    wireless.serverPort = UInt16(newVal)
                                }
                            }
                        ),
                        format: .number.grouping(.never)
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 84)
                    .multilineTextAlignment(.trailing)
                    .disabled(wireless.isStreaming)
                }
            }

            Section("Permissions & Diagnostics") {
                HStack {
                    Image(systemName: wireless.hasScreenRecordingPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(wireless.hasScreenRecordingPermission ? .green : .orange)
                    Text("Screen Recording")
                    Spacer()
                    if wireless.hasScreenRecordingPermission {
                        Text("Granted")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Grant Access…") {
                            wireless.requestScreenRecordingPermission()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                HStack {
                    Image(systemName: accessibilityPermission.isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(accessibilityPermission.isGranted ? .green : .orange)
                    Text("Accessibility (Touch & Pointer Input)")
                    Spacer()
                    if accessibilityPermission.isGranted {
                        Text("Granted")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Grant Access…") {
                            accessibilityPermission.request()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                DisclosureGroup("Session Log (\(wireless.diagnostics.count))", isExpanded: $showDiagnostics) {
                    if wireless.diagnostics.isEmpty {
                        Text("No events logged yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(wireless.diagnostics.prefix(15))) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(entry.level.rawValue)
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(levelColor(entry.level))
                                        .frame(width: 34, alignment: .leading)
                                    Text(entry.message)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { wireless.setPreviewVisible(true) }
        .onDisappear { wireless.setPreviewVisible(false) }
    }

    private func levelColor(_ level: DiagnosticEntry.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

// MARK: - DisplayModePicker

/// Resolution and refresh-rate picker used in the Displays settings tab.
private struct DisplayModePicker: View {
    let displayID: CGDirectDisplayID
    let model: DisplayStateModel
    @State private var modes: [DisplayModeOption] = []
    @State private var currentModeID: Int32?

    var body: some View {
        Group {
            if !modes.isEmpty {
                Picker("Resolution", selection: Binding(
                    get: { currentModeID ?? 0 },
                    set: { id in
                        model.setDisplayMode(id, for: displayID)
                        reloadModes()
                    }
                )) {
                    ForEach(modes) { mode in
                        Text(mode.title).tag(mode.id)
                    }
                }
            }
        }
        .onAppear(perform: reloadModes)
        .onChange(of: displayID) { reloadModes() }
    }

    private func reloadModes() {
        let result = model.displayModes(for: displayID)
        modes = result.options
        currentModeID = result.currentID
    }
}

// MARK: - Tesla Hotspot Setup Guide Sheet

private struct TeslaSetupGuideSheet: View {
    let wireless: WirelessDisplayManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Tesla Wi-Fi & Hotspot Setup Guide", systemImage: "car.fill")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Option A · Phone Hotspot (Easiest)")
                    .font(.subheadline.weight(.semibold))
                Text("1. Turn on Personal Hotspot on your iPhone or Android phone.\n2. Connect both your Mac and your Tesla to the phone hotspot.\n3. Open **\(wireless.primaryStreamURL)** in the Tesla Web Browser.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Text("Option B · Direct Mac Wi-Fi Hotspot (198.18.0.1 Bridge)")
                    .font(.subheadline.weight(.semibold))
                Text("Tesla's browser blocks standard local RFC1918 IPs (`192.168.x.x`), but allows benchmark subnet **`198.18.0.1`**:\n1. Enable Internet Sharing in **System Settings → General → Sharing → Internet Sharing** (share to Wi-Fi).\n2. Connect your Tesla Wi-Fi to your Mac's hotspot and check **Remain connected in Drive**.\n3. Click **Configure 198.18.0.1** below and open **`http://198.18.0.1:\(wireless.serverPort)`** in the Tesla browser.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Configure 198.18.0.1 Alias…") {
                    wireless.applyTeslaHotspotAliasWithAdminPrompt()
                }
                .buttonStyle(.borderedProminent)

                Button("Copy http://198.18.0.1:\(wireless.serverPort)") {
                    wireless.copyURLToClipboard("http://198.18.0.1:\(wireless.serverPort)")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
