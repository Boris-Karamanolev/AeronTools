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
            SettingsSection(title: "Menu Bar & Dock", footer: "Aeron Tools always stays reachable: hiding the menu bar icon keeps it in the Dock, and the other way around.") {
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
                if model.showMenuBarIcon {
                    Picker("Show next to menu bar icon", selection: $model.menuBarStat) {
                        ForEach(MenuBarStat.allCases) { stat in
                            Text(stat.title).tag(stat)
                        }
                    }
                }
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
                if loginItemNeedsApproval {
                    PermissionNotice(
                        message: "Allow Aeron Tools in Login Items to finish setting this up.",
                        buttonTitle: "Open Login Items…",
                        action: { SMAppService.openSystemSettingsLoginItems() }
                    )
                }
            }

            SettingsSection(title: "Caffeine", footer: "Prevents display sleep and idle system sleep. Use the cup in the menu bar popover for a timer.") {
                Toggle("Keep Mac awake", isOn: $model.isCaffeinated)
                Toggle("Keep awake while an external display is connected", isOn: $model.caffeinateWhileExternalConnected)
                Toggle("Keep awake while Wireless Display is streaming", isOn: $model.caffeinateWhileStreaming)
                Toggle("Keep awake while on power adapter", isOn: $model.caffeinateWhileOnPower)
            }

            SettingsSection(title: "Menu Bar Popover", footer: "Choose which cards the popover shows. Power and thermal readings only refresh while they're visible.") {
                Toggle("Wireless Display", isOn: $model.showWirelessDisplayCard)
                Toggle("Power & battery", isOn: $model.showWattageMeter)
                Toggle("Battery health and cycle count", isOn: $model.showBatteryHealth)
                    .disabled(!model.showWattageMeter)
                Toggle("Thermals", isOn: $model.showThermals)
                Toggle("Accessories", isOn: $model.showAccessoriesCard)
            }

            SettingsSection(title: "Keyboard Shortcuts", footer: "Shortcuts work everywhere, even with the MacBook screen off. Use ⌘, ⌃ or ⌥ in each shortcut.") {
                ForEach(HotKeyAction.allCases) { action in
                    ShortcutRecorder(action: action)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Displays Tab

    private var displaysTab: some View {
        Form {
            if model.isBuiltinPresent {
                SettingsSection(title: "MacBook Screen") {
                    // Turn-off controls only matter when another screen can take over (or to turn it back on)
                    if model.canTurnOffBuiltin || model.isBuiltinTurnedOff {
                        LabeledContent {
                            Button(model.isBuiltinTurnedOff ? "Turn Screen On" : "Turn Screen Off") {
                                model.toggleBuiltinDisplay()
                            }
                            .disabled(!model.canTurnOffBuiltin && !model.isBuiltinTurnedOff)
                        } label: {
                            HStack(spacing: 8) {
                                StatusDot(isActive: !model.isBuiltinTurnedOff)
                                Text(model.isBuiltinTurnedOff ? "Turned Off" : "Active")
                            }
                        }
                        Toggle("Turn off automatically when an external screen is connected", isOn: $model.autoTurnOffBuiltin)
                            .disabled(!model.hasExternalDisplays)
                        Toggle("Also turn off keyboard backlight", isOn: $model.turnOffKeyboardWithScreen)
                    }

                    if let builtinID = model.activeBuiltinDisplayID {
                        DisplayModePicker(displayID: builtinID, model: model)
                    }
                }
            }

            SettingsSection(title: "Brightness Automation", footer: brightnessAutomationFooter) {
                Picker("External displays", selection: $model.brightnessAutomation) {
                    ForEach(BrightnessAutomation.allCases) { automation in
                        Text(automation.title).tag(automation)
                    }
                }
                if model.brightnessAutomation == .schedule {
                    DatePicker("Night starts", selection: timeBinding(\.scheduleNightStart), displayedComponents: .hourAndMinute)
                    ValueSlider.percent("Night brightness", value: $model.scheduleNightBrightness)
                    DatePicker("Day starts", selection: timeBinding(\.scheduleDayStart), displayedComponents: .hourAndMinute)
                    ValueSlider.percent("Day brightness", value: $model.scheduleDayBrightness)
                }
            }

            SettingsSection(title: "Monitor Controls", footer: "Without restoring, Aeron Tools reads each monitor's current values instead. Extra dimming darkens the picture in software once the monitor is at 0%.") {
                Toggle("Restore brightness and volume when a monitor reconnects", isOn: $model.restoreMonitorSettings)
                Toggle("Show input switching in the menu bar popover", isOn: $model.showInputSwitching)
                Toggle("Show resolution menu in the menu bar popover", isOn: $model.showResolutionMenu)
                Toggle("Allow extra dimming below minimum brightness", isOn: $model.extraDimmingEnabled)
            }

            SettingsSection(title: "Media Keys", footer: "Brightness keys adjust the monitor under the pointer. Volume keys adjust the monitor sound is playing through.") {
                Toggle("Control external monitors with brightness & volume keys", isOn: $model.mediaKeysControlPointerDisplay)
                if model.mediaKeysControlPointerDisplay && !accessibilityPermission.isGranted {
                    PermissionNotice(
                        message: "Accessibility is needed to intercept media keys.",
                        buttonTitle: "Open Settings…",
                        action: accessibilityPermission.openSystemSettings
                    )
                }
            }

            SettingsSection(title: "Sound", footer: "Only switches when sound is playing through the MacBook speakers, never from headphones or external speakers.") {
                Toggle("Play sound through monitor when connected", isOn: $model.switchAudioToMonitor)
            }

            if !model.externalDisplays.isEmpty {
                SettingsSection(title: "Connected External Displays") {
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

    private var brightnessAutomationFooter: String? {
        switch model.brightnessAutomation {
        case .off:
            return nil
        case .matchMacBook:
            return "External displays follow the MacBook screen's brightness, including auto-brightness. Paused while the MacBook screen is off."
        case .schedule:
            return "Applied when night or day begins and when a monitor connects. You can still adjust brightness in between."
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
            SettingsSection(title: "Wireless Display") {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            StatusDot(isActive: wireless.isStreaming)
                            Text(wireless.isStreaming ? "Streaming" : "Ready to Stream")
                                .font(.headline)
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

            SettingsSection(title: "Display Configuration", footer: "Touch and pointer control lets the browser move and click the pointer on this Mac.") {
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

                ValueSlider(
                    title: "Stream Quality",
                    value: $wireless.config.jpegQuality,
                    range: 0.35...0.92,
                    format: { "\(Int(($0 * 100).rounded()))%" }
                )

                Toggle("Allow touch & pointer control from browser", isOn: $wireless.config.allowTouch)
            }

            SettingsSection(title: "Network & Tesla Hotspot", footer: networkFooter) {
                Picker("Connection Mode", selection: $wireless.connectionMode) {
                    ForEach(ConnectionMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }

                if wireless.connectionMode != .sameNetwork {
                    LabeledContent("Tesla Browser Bridge") {
                        HStack(spacing: 6) {
                            Button("Configure 198.18.0.1") {
                                wireless.applyTeslaHotspotAliasWithAdminPrompt()
                            }
                            Button("Setup Guide…") {
                                showTeslaSetupSheet = true
                            }
                        }
                        .controlSize(.small)
                    }
                }

                LabeledContent("HTTP Port") {
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
                    .frame(width: 84)
                    .multilineTextAlignment(.trailing)
                    .disabled(wireless.isStreaming)
                }
            }

            SettingsSection(title: "Permissions", footer: "Screen Recording captures the display for streaming. Accessibility lets the browser control the pointer.") {
                PermissionStatusRow(title: "Screen Recording", isGranted: wireless.hasScreenRecordingPermission) {
                    wireless.requestScreenRecordingPermission()
                }
                PermissionStatusRow(title: "Accessibility", isGranted: accessibilityPermission.isGranted) {
                    accessibilityPermission.request()
                }
            }

            SettingsSection(title: "Diagnostics") {
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

    private var networkFooter: String {
        var footer = wireless.connectionMode.subtitle
        if wireless.connectionMode != .sameNetwork {
            footer += " The browser bridge binds 198.18.0.1 so Tesla's browser allows local hotspot traffic."
        }
        return footer
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
