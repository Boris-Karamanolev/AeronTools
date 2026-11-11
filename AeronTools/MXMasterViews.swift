import SwiftUI
import AppKit
import ApplicationServices

// MARK: - Popover Card: MXMasterCardView

/// Shown in the popover only while the mouse is connected.
public struct MXMasterCardView: View {
    @Bindable var manager = MXMasterManager.shared

    private let dpiPresets: [Int] = [800, 1200, 1600, 2400, 4000, 8000]

    public init() {}

    public var body: some View {
        let snapshot = manager.snapshot
        let tint = Color.accentColor
        let options = manager.cardOptions

        VStack(alignment: .leading, spacing: 10) {
            // Header Row
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.18))
                        .frame(width: 30, height: 30)
                    Image(systemName: "computermouse.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.deviceName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 5, height: 5)
                        Text(snapshot.transport.rawValue)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Right-hand Primary Readout: Battery % (if available) or DPI
                if let battery = snapshot.batteryPercent {
                    VStack(alignment: .trailing, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            if snapshot.isCharging {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.green)
                            }
                            Text("\(battery)")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(battery < 20 && !snapshot.isCharging ? Color.red : Color.primary)
                            Text("%")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        Text(snapshot.isCharging ? "Charging" : "Battery")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("\(manager.config.dpi)")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                            Text("DPI")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        Text(manager.config.wheelMode.title)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // Without Input Monitoring macOS blocks the HID++ channel: no battery, DPI, SmartShift or thumb gestures
            if !manager.hasInputMonitoringAccess {
                Button {
                    manager.openInputMonitoringSettings()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Allow Input Monitoring to read battery and enable gestures")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // Optional Battery Reserve Bar when battery level is reported
            if options.showBatteryBar, let battery = snapshot.batteryPercent {
                let ratio = min(1.0, max(0.0, Double(battery) / 100.0))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 6)

                        Capsule()
                            .fill(ratio < 0.2 && !snapshot.isCharging ? Color.red : Color.green)
                            .frame(width: max(6, geo.size.width * CGFloat(ratio)), height: 6)
                    }
                }
                .frame(height: 6)
            }

            if options.showWheelControls || options.showDPIControls || options.showThumbwheel {
                Divider()
                    .opacity(0.35)
            }

            // MagSpeed Wheel Mode & SmartShift Quick Toggles
            if options.showWheelControls {
                HStack(spacing: 6) {
                    ForEach(MXWheelMode.allCases) { mode in
                        let isSelected = manager.config.wheelMode == mode
                        Button {
                            manager.config.wheelMode = mode
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: mode == .ratchet ? "gearshape.2.fill" : "tornado")
                                    .font(.system(size: 10, weight: .semibold))
                                Text(mode.title)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    }

                    // SmartShift Pill Toggle
                    Button {
                        manager.config.smartShiftEnabled.toggle()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "bolt.Badge.automatic.fill")
                                .symbolFallback("sparkles")
                                .font(.system(size: 10, weight: .semibold))
                            Text("SmartShift")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(manager.config.smartShiftEnabled ? Color.green.opacity(0.18) : Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(manager.config.smartShiftEnabled ? Color.green.opacity(0.5) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(manager.config.smartShiftEnabled ? Color.green : .secondary)
                    .help("Automatically shift from Ratchet to Free-Spin when you flick the wheel")
                }
            }

            // DPI Sensitivity Slider + Quick Preset Menu
            if options.showDPIControls {
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "dial.high.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)

                        Text("Sensitivity")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Menu {
                            ForEach(dpiPresets, id: \.self) { preset in
                                Button {
                                    manager.config.dpi = preset
                                } label: {
                                    if manager.config.dpi == preset {
                                        Label("\(preset) DPI", systemImage: "checkmark")
                                    } else {
                                        Text("\(preset) DPI")
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text("\(manager.config.dpi) DPI")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }

                    Slider(
                        value: Binding(
                            get: { Double(manager.config.dpi) },
                            set: { manager.config.dpi = MXMasterConfig.clampedDPI(Int($0.rounded())) }
                        ),
                        in: 200...8000,
                        step: 50
                    )
                    .controlSize(.small)
                }
            }

            // Thumbwheel Mode & Scroll Row
            if options.showThumbwheel {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left.and.right.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)

                    Text("Thumbwheel")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Picker("", selection: $manager.config.thumbwheelAction) {
                        ForEach(MXThumbwheelAction.allCases) { action in
                            Text(action.shortTitle).tag(action)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 130)
                }
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

private extension Image {
    func symbolFallback(_ fallbackName: String) -> Image {
        if NSImage(systemSymbolName: "bolt.badge.automatic.fill", accessibilityDescription: nil) != nil {
            return Image(systemName: "bolt.badge.automatic.fill")
        }
        return Image(systemName: fallbackName)
    }
}

// MARK: - Settings Tab: MXMasterSettingsTabView

public struct MXMasterSettingsTabView: View {
    @Bindable var manager = MXMasterManager.shared
    @Bindable var model = DisplayStateModel.shared
    private var accessibilityPermission = AccessibilityPermission.shared

    private let dpiPresets: [Int] = [800, 1200, 1600, 2400, 4000, 8000]

    public init() {}

    public var body: some View {
        Form {
            deviceStatusSection
            sensorAndWheelSection
            scrollingAndThumbwheelSection
            buttonsAndGesturesSection
            menuBarCardSection
        }
        .formStyle(.grouped)
        .onAppear {
            manager.refreshDeviceState()
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var deviceStatusSection: some View {
        let snapshot = manager.snapshot
        Section("Logitech MX Master 4") {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill((manager.isConnected ? Color.accentColor : Color.secondary).opacity(0.16))
                        .frame(width: 36, height: 36)
                    Image(systemName: "computermouse.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(manager.isConnected ? Color.accentColor : Color.secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(snapshot.deviceName)
                            .font(.headline)
                        Circle()
                            .fill(manager.isConnected ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 7, height: 7)
                        Text(snapshot.transport.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let battery = snapshot.batteryPercent {
                        Text(snapshot.isCharging ? "Battery: \(battery)% (Charging)" : "Battery: \(battery)%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(manager.lastStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button("Refresh") {
                    manager.refreshDeviceState()
                }
                .controlSize(.small)

                Button("Apply to Mouse") {
                    manager.applyAllSettingsToHardware()
                }
                .controlSize(.small)
                .disabled(!manager.isConnected)
            }

            if !manager.hasInputMonitoringAccess {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Input Monitoring permission is required to read battery and DPI and to change settings on the mouse. If it's already on, quit and reopen Aeron Tools.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Settings…") {
                        manager.openInputMonitoringSettings()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var sensorAndWheelSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Sensor Sensitivity (DPI)")
                    Spacer()
                    Text("\(manager.config.dpi) DPI")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { Double(manager.config.dpi) },
                        set: { manager.config.dpi = MXMasterConfig.clampedDPI(Int($0.rounded())) }
                    ),
                    in: 200...8000,
                    step: 50
                )

                HStack(spacing: 6) {
                    Text("Presets:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(dpiPresets, id: \.self) { preset in
                        Button("\(preset)") {
                            manager.config.dpi = preset
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(manager.config.dpi == preset ? .accentColor : nil)
                    }
                }
            }

            Picker("MagSpeed Wheel Mode", selection: $manager.config.wheelMode) {
                ForEach(MXWheelMode.allCases) { mode in
                    Text("\(mode.title) – \(mode.subtitle)").tag(mode)
                }
            }

            Toggle("SmartShift (Auto-Switch to Free-Spin on Fast Flick)", isOn: $manager.config.smartShiftEnabled)

            if manager.config.smartShiftEnabled && manager.config.wheelMode == .ratchet {
                HStack {
                    Text("SmartShift Sensitivity")
                    Slider(
                        value: Binding(
                            get: { Double(manager.config.smartShiftThreshold) },
                            set: { manager.config.smartShiftThreshold = MXMasterConfig.clampedSmartShiftThreshold(Int($0.rounded())) }
                        ),
                        in: 1...50,
                        step: 1
                    )
                    Text("\(manager.config.smartShiftThreshold)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
            }
        } header: {
            Text("Sensor & MagSpeed Wheel (HID++ / BLE)")
        } footer: {
            Text("Communicates directly with your MX Master 4 over Bluetooth LE or Logi Bolt receiver using Logitech HID++ 2.0 — no background daemon or Logi Options+ required.")
        }
    }

    @ViewBuilder
    private var scrollingAndThumbwheelSection: some View {
        Section {
            Toggle("Standard vertical scroll direction (Mouse only)", isOn: $manager.config.standardVerticalScroll)
            Toggle("Smooth scrolling (120 Hz pixel interpolation)", isOn: $manager.config.smoothScrolling)

            HStack {
                Text("Vertical Scroll Speed")
                Slider(value: $manager.config.scrollSpeedMultiplier, in: 0.5...3.0, step: 0.25)
                Text(String(format: "%.2f×", manager.config.scrollSpeedMultiplier))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }

            Picker("Horizontal Thumbwheel Action", selection: $manager.config.thumbwheelAction) {
                ForEach(MXThumbwheelAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }

            Toggle("Invert thumbwheel direction", isOn: $manager.config.invertThumbwheel)
        } header: {
            Text("Scrolling & Thumbwheel")
        } footer: {
            Text("Mouse vertical scroll direction applies exclusively to discrete mouse wheel ticks so your MacBook Trackpad remains Natural.")
        }
    }

    @ViewBuilder
    private var buttonsAndGesturesSection: some View {
        Section {
            if !accessibilityPermission.isGranted {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Accessibility permission is required for button remapping, smooth scrolling, and thumbwheel actions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Grant Access…") {
                        accessibilityPermission.request()
                    }
                    .controlSize(.small)
                }
            }

            Picker("Middle Button (Wheel Click)", selection: $manager.config.middleButtonAction) {
                ForEach(MXButtonAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }

            Picker("Back Button", selection: $manager.config.backButtonAction) {
                ForEach(MXButtonAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }

            Picker("Forward Button", selection: $manager.config.forwardButtonAction) {
                ForEach(MXButtonAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }

            Picker("Thumb / Gesture Button (Click)", selection: $manager.config.gestureButtonClickAction) {
                ForEach(MXButtonAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }

            Picker("Button Behind Wheel", selection: $manager.config.modeShiftButtonAction) {
                ForEach(MXButtonAction.allCases) { action in
                    Text(action == .systemDefault ? "System Default (Ratchet / Free-Spin)" : action.title).tag(action)
                }
            }

            Picker("Haptic Thumb Panel", selection: $manager.config.hapticPanelButtonAction) {
                ForEach(MXButtonAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }

            Toggle("Hold & Drag Thumb Gestures", isOn: $manager.config.gesturesEnabled)

            if manager.config.gesturesEnabled {
                Picker("Hold + Drag Up", selection: $manager.config.gestureUpAction) {
                    ForEach(MXButtonAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                Picker("Hold + Drag Down", selection: $manager.config.gestureDownAction) {
                    ForEach(MXButtonAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                Picker("Hold + Drag Left", selection: $manager.config.gestureLeftAction) {
                    ForEach(MXButtonAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                Picker("Hold + Drag Right", selection: $manager.config.gestureRightAction) {
                    ForEach(MXButtonAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
            }
        } header: {
            Text("Buttons & Hold-Drag Gestures")
        }
    }

    @ViewBuilder
    private var menuBarCardSection: some View {
        Section {
            Toggle("Show Accessories card in menu bar popover", isOn: $model.showAccessoriesCard)

            Group {
                Toggle("Battery bar", isOn: $manager.cardOptions.showBatteryBar)
                Toggle("Wheel mode & SmartShift toggles", isOn: $manager.cardOptions.showWheelControls)
                Toggle("DPI slider", isOn: $manager.cardOptions.showDPIControls)
                Toggle("Thumbwheel action picker", isOn: $manager.cardOptions.showThumbwheel)
            }
            .disabled(!model.showAccessoriesCard)
            .padding(.leading, 16)

            Toggle("Low battery notification", isOn: $manager.cardOptions.lowBatteryAlertEnabled)

            if manager.cardOptions.lowBatteryAlertEnabled {
                Stepper(value: $manager.cardOptions.lowBatteryThreshold, in: 5...50, step: 5) {
                    HStack {
                        Text("Notify at or below")
                        Spacer()
                        Text("\(manager.cardOptions.lowBatteryThreshold)%")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Accessories Card & Alerts")
        } footer: {
            Text("The low battery notification works even when the Accessories card is hidden.")
        }
    }
}
