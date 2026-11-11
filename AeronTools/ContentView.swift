import SwiftUI
import CoreGraphics
import AppKit

// MARK: - ContentView

public struct ContentView: View {
    @Bindable var model = DisplayStateModel.shared
    @Bindable var wireless = WirelessDisplayManager.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header Bar
            HStack(spacing: 8) {
                Label {
                    Text("Aeron Tools")
                        .font(.system(size: 13, weight: .bold))
                } icon: {
                    Image(nsImage: AeronToolsIcon.menuBarImage(
                        isCaffeineActive: false,
                        isStreaming: wireless.isStreaming,
                        hasExternalDisplays: true
                    ))
                    .foregroundStyle(Color.accentColor)
                }

                Spacer()

                // Caffeine: click toggles, the menu offers timed sessions.
                Menu {
                    Section("Keep Mac Awake") {
                        ForEach(CaffeineDuration.allCases) { duration in
                            Button(duration.title) {
                                model.startCaffeine(for: duration.seconds)
                            }
                        }
                    }
                    if model.isCaffeinated {
                        Divider()
                        Button("Turn Off Caffeine") {
                            model.isCaffeinated = false
                        }
                    }
                } label: {
                    Image(systemName: model.isCaffeineActive ? "cup.and.heat.waves.fill" : "cup.and.saucer")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.isCaffeineActive ? Color.orange : Color.secondary)
                } primaryAction: {
                    model.toggleCaffeine()
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(model.isCaffeineActive ? Color.orange.opacity(0.18) : Color.clear)
                )
                .help(caffeineHelp)

                // Settings Button
                Button {
                    StatusBarController.shared.closePopover()
                    SettingsWindowController.shared.show()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(5)
                }
                .buttonStyle(.plain)
                .help("Settings… (⌘,)")

                // Quit Button
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(5)
                }
                .buttonStyle(.plain)
                .help("Quit Aeron Tools")
            }
            .padding(.horizontal, 2)

            // External Monitors Section
            ForEach(model.externalDisplays) { display in
                ExternalDisplayCard(display: display, model: model)
            }

            // MacBook Built-in Screen Card: only useful when another screen can take over (or to turn it back on)
            if model.isBuiltinPresent && (model.canTurnOffBuiltin || model.isBuiltinTurnedOff) {
                MacBookDisplayCard(model: model)
            }

            // Wireless Virtual Display & Web Stream Card
            if model.showWirelessDisplayCard {
                WirelessDisplayCardView()
            }

            // Logitech MX Master 4 Card
            if model.showAccessoriesCard {
                MXMasterCardView()
            }

            // Wattage Meter Card
            if model.showWattageMeter {
                WattageCardView()
            }

            // Thermals Card
            if model.showThermals {
                ThermalsCardView()
            }

            // Quick Options Footer
            FooterSection(model: model)
        }
        .padding(14)
        .frame(width: 320)
    }

    private var caffeineHelp: String {
        if model.isCaffeinated, let end = model.caffeineEndDate {
            return "Caffeine on until \(end.formatted(date: .omitted, time: .shortened)) – click to turn off"
        }
        if model.isCaffeinated {
            return "Caffeine on – click to turn off"
        }
        if model.isCaffeineAutomatic {
            return "Kept awake automatically (see Settings)"
        }
        return "Keep Mac awake – click, or use the arrow for a timer"
    }
}

// MARK: - ExternalDisplayCard

private struct ExternalDisplayCard: View {
    let display: ExternalDisplayInfo
    @Bindable var model: DisplayStateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Monitor Title Row
            HStack(spacing: 7) {
                Image(systemName: "display")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(display.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if (model.showInputSwitching && display.hasHardwareControl) || model.showResolutionMenu {
                    DisplayOptionsMenu(display: display, model: model)
                }
            }

            if !display.hasHardwareControl {
                Text("This monitor doesn't support DDC/CI, so brightness is dimmed in software.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Brightness Control
            HStack(spacing: 8) {
                Image(systemName: "sun.min.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)

                Slider(
                    value: Binding(
                        get: { display.brightness },
                        set: { model.updateBrightness(for: display.id, level: $0) }
                    ),
                    in: 0...1
                )
                .controlSize(.regular)

                Image(systemName: "sun.max.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)

                Text("\(Int(display.brightness * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }

            // Extra Dimming (software, below the hardware minimum)
            if model.extraDimmingEnabled {
                HStack(spacing: 8) {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)

                    // Reversed so dragging right dims further, like the brightness slider dragging left.
                    Slider(
                        value: Binding(
                            get: { 1 - display.extraDimming },
                            set: { model.updateExtraDimming(for: display.id, level: 1 - $0) }
                        ),
                        in: 0...(1 - DisplayStateModel.minimumExtraDimming)
                    )
                    .controlSize(.regular)

                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)

                    Text(display.extraDimming >= 0.999 ? "Off" : "\(Int(((1 - display.extraDimming) * 100).rounded()))%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                .help("Extra dimming below the monitor's minimum brightness")
            }

            // Volume Control
            HStack(spacing: 8) {
                Button {
                    model.toggleMonitorMuted(for: display.id)
                } label: {
                    Image(systemName: display.isMuted ? "speaker.slash.fill" : "speaker.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(display.isMuted ? .red : .secondary)
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .help(display.isMuted ? "Unmute Monitor" : "Mute Monitor")

                Slider(
                    value: Binding(
                        get: { display.volume },
                        set: { model.updateVolume(for: display.id, level: $0) }
                    ),
                    in: 0...1
                )
                .controlSize(.regular)
                .disabled(display.isMuted)

                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)

                Text(display.isMuted ? "Mute" : "\(Int(display.volume * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - DisplayOptionsMenu

/// Input source and resolution choices for one external monitor.
private struct DisplayOptionsMenu: View {
    let display: ExternalDisplayInfo
    let model: DisplayStateModel
    @State private var modes: [DisplayModeOption] = []
    @State private var currentModeID: Int32?

    var body: some View {
        Menu {
            if model.showInputSwitching && display.hasHardwareControl {
                Section("Input") {
                    ForEach(model.inputChoices(for: display), id: \.self) { code in
                        Toggle(InputSource.name(for: code), isOn: Binding(
                            get: { display.currentInput == code },
                            set: { isOn in
                                if isOn {
                                    model.selectInput(code, for: display.id)
                                }
                            }
                        ))
                    }
                }
            }
            if model.showResolutionMenu && !modes.isEmpty {
                Menu("Resolution") {
                    ForEach(modes) { mode in
                        Toggle(mode.title, isOn: Binding(
                            get: { mode.id == currentModeID },
                            set: { isOn in
                                if isOn {
                                    model.setDisplayMode(mode.id, for: display.id)
                                    reloadModes()
                                }
                            }
                        ))
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Input & Resolution")
        .onAppear(perform: reloadModes)
        .onChange(of: display.id) { reloadModes() }
    }

    private func reloadModes() {
        let result = model.displayModes(for: display.id)
        modes = result.options
        currentModeID = result.currentID
    }
}

// MARK: - MacBookDisplayCard

private struct MacBookDisplayCard: View {
    @Bindable var model: DisplayStateModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 17))
                .foregroundStyle(model.isBuiltinTurnedOff ? .secondary : .primary)

            VStack(alignment: .leading, spacing: 2) {
                Text("MacBook Screen")
                    .font(.system(size: 13, weight: .semibold))

                HStack(spacing: 5) {
                    Circle()
                        .fill(model.isBuiltinTurnedOff ? Color.secondary : Color.green)
                        .frame(width: 6, height: 6)
                    Text(model.isBuiltinTurnedOff ? "Turned Off" : "Active")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button(model.isBuiltinTurnedOff ? "Turn On" : "Turn Off") {
                model.toggleBuiltinDisplay()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .font(.system(size: 12, weight: .medium))
            .disabled(!model.canTurnOffBuiltin && !model.isBuiltinTurnedOff)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - WirelessDisplayCardView

private struct WirelessDisplayCardView: View {
    @Bindable var wireless = WirelessDisplayManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(wireless.isStreaming ? Color.green.opacity(0.18) : Color.accentColor.opacity(0.15))
                        .frame(width: 30, height: 30)
                    Image(systemName: "tv.and.mediabox")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(wireless.isStreaming ? Color.green : Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Wireless Display")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    HStack(spacing: 5) {
                        Circle()
                            .fill(wireless.isStreaming ? Color.green : Color.secondary)
                            .frame(width: 5, height: 5)
                        Text(statusSubtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button(wireless.isStreaming ? "Stop" : "Start") {
                    wireless.toggleSession()
                }
                .buttonStyle(.bordered)
                .tint(wireless.isStreaming ? .red : .accentColor)
                .controlSize(.regular)
                .font(.system(size: 12, weight: .medium))
                .disabled(wireless.isStartingOrStopping)
            }

            if wireless.isStreaming {
                Divider()
                    .opacity(0.35)

                // Stream URL + Quick Copy / Open Actions
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text(wireless.primaryStreamURL)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button {
                        wireless.copyURLToClipboard()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy Stream URL")

                    Button {
                        wireless.openInLocalBrowser()
                    } label: {
                        Image(systemName: "safari")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open Viewer in Browser")
                }
            } else if !wireless.hasScreenRecordingPermission {
                Button("Grant Screen Recording Access…") {
                    wireless.requestScreenRecordingPermission()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    private var statusSubtitle: String {
        let preset = wireless.config.preset
        if wireless.isStreaming {
            let fps = Int(wireless.measuredFPS.rounded())
            if fps > 0 {
                return "\(preset.shortName) · \(fps) FPS"
            }
            return "Streaming · \(preset.width)×\(preset.height)"
        }
        return "\(preset.shortName) · \(preset.width)×\(preset.height)"
    }
}

// MARK: - FooterSection

private struct FooterSection: View {
    @Bindable var model: DisplayStateModel
    @State private var now = Date()

    private var caffeineStatus: String? {
        if model.isCaffeinated, let end = model.caffeineEndDate {
            let remaining = max(0, end.timeIntervalSince(now))
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = remaining >= 3600 ? [.hour, .minute] : [.minute, .second]
            formatter.unitsStyle = .abbreviated
            return "Awake for \(formatter.string(from: remaining) ?? "")"
        }
        if model.isCaffeinated {
            return "Awake until turned off"
        }
        if model.isCaffeineAutomatic {
            return "Kept awake automatically"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let status = caffeineStatus {
                Label(status, systemImage: "cup.and.heat.waves")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            HStack {
                if let shortcut = HotKeyManager.shared.shortcut(for: .restoreBuiltinScreen) {
                    Label("\(shortcut.displayString) restores MacBook screen", systemImage: "keyboard")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Button("More Settings…") {
                    StatusBarController.shared.closePopover()
                    SettingsWindowController.shared.show()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 2)
        .task {
            // The caffeine countdown needs a tick.
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

// MARK: - WattageCardView (macOS Native Popover Style)

private struct WattageCardView: View {
    @Bindable var manager = WattageManager.shared
    var model = DisplayStateModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if manager.isSupported {
                if let snapshot = manager.currentSnapshot {
                    // Header Row: Apple Control Center Module Style
                    HStack(alignment: .center, spacing: 10) {
                        // Tinted Icon Plate
                        ZStack {
                            Circle()
                                .fill(snapshot.isPluggedIn ? Color.green.opacity(0.18) : Color.orange.opacity(0.18))
                                .frame(width: 30, height: 30)
                            Image(systemName: snapshot.isPluggedIn ? "bolt.fill" : "battery.75")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(snapshot.isPluggedIn ? Color.green : Color.orange)
                        }

                        // Title & Power Source Status
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Power & Battery")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)

                            HStack(spacing: 4) {
                                Circle()
                                    .fill(snapshot.isPluggedIn ? Color.green : Color.orange)
                                    .frame(width: 5, height: 5)
                                Text(snapshot.isPluggedIn ? "Power Adapter" : "Battery Power")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        // Primary Wattage Display
                        VStack(alignment: .trailing, spacing: 1) {
                            HStack(alignment: .firstTextBaseline, spacing: 1.5) {
                                Text(String(format: "%.1f", snapshot.systemLoadWatts ?? 0))
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                Text("W")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            Text("System Draw")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    // Native Power / Battery Gauge Track
                    powerGaugeView(for: snapshot)

                    Divider()
                        .opacity(0.35)

                    // Control Center Detail Rows
                    VStack(spacing: 6) {
                        // External Power Supply Row
                        if snapshot.isPluggedIn {
                            HStack(spacing: 8) {
                                Image(systemName: "powerplug.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)

                                Text(snapshot.adapterWatts.map { "\($0)W USB-C Charger" } ?? "Power Adapter")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)

                                Spacer()

                                if let inW = snapshot.inputWatts {
                                    Text(String(format: "%.1f W In", inW))
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(.primary)
                                } else if let adW = snapshot.adapterWatts {
                                    Text("\(adW) W Rating")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        // Battery Status Row
                        HStack(spacing: 8) {
                            Image(systemName: snapshot.isCharging ? "bolt.badge.automatic.fill" : "battery.100")
                                .font(.system(size: 11))
                                .foregroundStyle(snapshot.isCharging ? Color.green : Color.secondary)
                                .frame(width: 14)

                            Text(snapshot.isCharging ? "Battery Charging (\(snapshot.batteryLevel)%)" : "Battery Level (\(snapshot.batteryLevel)%)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)

                            Spacer()

                            if let bw = snapshot.batteryWatts {
                                if snapshot.isCharging {
                                    Text("+\(String(format: "%.1f", abs(bw))) W")
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.green)
                                } else {
                                    Text("-\(String(format: "%.1f", abs(bw))) W")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text("\(snapshot.batteryLevel)%")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // Hardware Electrical Potential Row
                        if let v = snapshot.voltage {
                            HStack(spacing: 8) {
                                Image(systemName: "gauge.with.needle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)

                                Text("Telemetry")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Text(telemetryString(for: snapshot, voltage: v))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        // Battery Health Row
                        if model.showBatteryHealth, let health = healthString(for: snapshot) {
                            HStack(spacing: 8) {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)

                                Text("Battery Health")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Text(health)
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle((snapshot.maximumCapacityPercent ?? 100) < 80 ? Color.orange : Color.primary)
                            }
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reading power telemetry…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.slash")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                    Text("Wattage metering is unavailable on this hardware.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private func powerGaugeView(for snapshot: WattageSnapshot) -> some View {
        if snapshot.isPluggedIn, let adapter = snapshot.adapterWatts, adapter > 0 {
            let load = snapshot.systemLoadWatts ?? 0
            let ratio = min(1.0, max(0.0, load / Double(adapter)))
            VStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 7)

                        Capsule()
                            .fill(ratio > 0.85 ? Color.orange : Color.green)
                            .frame(width: max(7, geo.size.width * CGFloat(ratio)), height: 7)
                    }
                }
                .frame(height: 7)

                HStack {
                    Text("\(String(format: "%.1f", load))W of \(adapter)W capacity")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(ratio * 100))%")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            let levelRatio = min(1.0, max(0.0, Double(snapshot.batteryLevel) / 100.0))
            VStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 7)

                        Capsule()
                            .fill(levelRatio < 0.2 ? Color.red : Color.green)
                            .frame(width: max(7, geo.size.width * CGFloat(levelRatio)), height: 7)
                    }
                }
                .frame(height: 7)

                HStack {
                    Text("Battery Reserve")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(snapshot.batteryLevel)%")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func healthString(for snapshot: WattageSnapshot) -> String? {
        var parts: [String] = []
        if let percent = snapshot.maximumCapacityPercent {
            parts.append("\(percent)%")
        }
        if let cycles = snapshot.cycleCount {
            if let rated = snapshot.designCycleCount, rated > 0 {
                parts.append("\(cycles)/\(rated) cycles")
            } else {
                parts.append("\(cycles) cycles")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func telemetryString(for snapshot: WattageSnapshot, voltage: Double) -> String {
        if let amp = snapshot.amperage {
            return String(format: "%.1fV • %.2fA", voltage, abs(amp))
        }
        return String(format: "%.1fV", voltage)
    }
}

// MARK: - ThermalsCardView

private struct ThermalsCardView: View {
    @Bindable var manager = ThermalManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if manager.isSupported {
                if let snapshot = manager.currentSnapshot {
                    let tint = pressureColor(snapshot.thermalState)

                    // Header Row
                    HStack(alignment: .center, spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(tint.opacity(0.18))
                                .frame(width: 30, height: 30)
                            Image(systemName: "thermometer.medium")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(tint)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Thermals")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)

                            HStack(spacing: 4) {
                                Circle()
                                    .fill(tint)
                                    .frame(width: 5, height: 5)
                                Text(pressureLabel(snapshot.thermalState))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        // Primary CPU Temperature Display
                        if let cpu = snapshot.cpuCelsius {
                            VStack(alignment: .trailing, spacing: 1) {
                                HStack(alignment: .firstTextBaseline, spacing: 1.5) {
                                    Text(String(format: "%.0f", cpu))
                                        .font(.system(size: 18, weight: .bold, design: .rounded))
                                    Text("°C")
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                                Text("CPU")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    Divider()
                        .opacity(0.35)

                    // Temperature Rows
                    VStack(spacing: 6) {
                        if let cpu = snapshot.cpuCelsius {
                            temperatureRow(icon: "cpu", title: "CPU", celsius: cpu)
                        }
                        if let gpu = snapshot.gpuCelsius {
                            temperatureRow(icon: "square.stack.3d.up.fill", title: "GPU", celsius: gpu)
                        }
                        if let battery = snapshot.batteryCelsius {
                            temperatureRow(icon: "battery.75", title: "Battery", celsius: battery)
                        }
                    }

                    Divider()
                        .opacity(0.35)

                    // Fan Rows
                    if snapshot.fans.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "fan.slash")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(width: 14)
                            Text("No fans – passively cooled")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(spacing: 8) {
                            ForEach(snapshot.fans) { fan in
                                fanRow(fan, showsIndex: snapshot.fans.count > 1)
                            }
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reading thermal sensors…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "thermometer.slash")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                    Text("Thermal sensors are unavailable on this hardware.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    private func temperatureRow(icon: String, title: String, celsius: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            Text(String(format: "%.1f °C", celsius))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(temperatureColor(celsius))
        }
    }

    private func fanRow(_ fan: FanReading, showsIndex: Bool) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "fan.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)

                Text(showsIndex ? "Fan \(fan.id + 1)" : "Fan")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if fan.isManual {
                    Text("Manual")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                }

                Spacer()

                Text("\(Int(fan.rpm.rounded())) RPM")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)

                Text("\(Int((fan.fraction * 100).rounded()))%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 5)

                    Capsule()
                        .fill(fan.fraction > 0.75 ? Color.orange : Color.accentColor)
                        .frame(width: max(5, geo.size.width * CGFloat(fan.fraction)), height: 5)
                }
            }
            .frame(height: 5)
            .padding(.leading, 22)
        }
    }

    private func temperatureColor(_ celsius: Double) -> Color {
        switch celsius {
        case ..<70: return .primary
        case ..<90: return .orange
        default: return .red
        }
    }

    private func pressureColor(_ state: ProcessInfo.ThermalState) -> Color {
        switch state {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .secondary
        }
    }

    private func pressureLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Normal Pressure"
        case .fair: return "Fair Pressure"
        case .serious: return "Serious Pressure"
        case .critical: return "Critical Pressure"
        @unknown default: return "Unknown Pressure"
        }
    }
}
