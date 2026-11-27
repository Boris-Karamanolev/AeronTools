import SwiftUI

// MARK: - MX Master Settings Sections

/// The MX Master page: device-specific sections only, built from the shared settings components. The
/// Accessories tab adds the device section and battery alerts, and disables everything while the mouse isn't
/// connected.
struct MXMasterSettingsTabView: View {
    @Bindable var manager = MXMasterManager.shared
    private var accessibilityPermission: AccessibilityPermission { .shared }

    private static let dpiPresets = [800, 1200, 1600, 2400, 4000, 8000]
    /// The MX supports the wheel-mode toggle on top of the shared actions.
    private static let actions = AccessoryButtonAction.allCases

    var body: some View {
        // Like the other accessories, the mouse's own sections only show while it's connected.
        if manager.isAvailable {
            performanceSection
            scrollingSection
            thumbwheelSection
            buttonsSection
            gesturesSection
            onboardMemorySection
        }
    }

    private var performanceSection: some View {
        SettingsSection(title: "Performance", footer: "SmartShift switches the wheel to free-spin when you flick it.") {
            DPIControl(dpi: manager.config.dpi, presets: Self.dpiPresets, range: 200...8000) {
                manager.config.dpi = MXMasterConfig.clampedDPI($0)
            }
            Picker("Wheel Mode", selection: $manager.config.wheelMode) {
                ForEach(MXWheelMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Toggle("SmartShift", isOn: $manager.config.smartShiftEnabled)
            if manager.config.smartShiftEnabled && manager.config.wheelMode == .ratchet {
                LevelSlider(title: "SmartShift Sensitivity", value: manager.config.smartShiftThreshold, range: 1...50) {
                    manager.config.smartShiftThreshold = MXMasterConfig.clampedSmartShiftThreshold($0)
                }
            }
        }
    }

    private var scrollingSection: some View {
        SettingsSection(title: "Scrolling", footer: "Only this mouse is affected; trackpads and other mice keep the system setting.") {
            Toggle("Standard scroll direction", isOn: $manager.config.standardVerticalScroll)
            Toggle("Smooth scrolling", isOn: $manager.config.smoothScrolling)
            ValueSlider(
                title: "Scroll Speed",
                value: $manager.config.scrollSpeedMultiplier,
                range: 0.5...3.0,
                step: 0.25,
                format: { String(format: "%.2f×", $0) }
            )
        }
    }

    private var thumbwheelSection: some View {
        SettingsSection(title: "Thumbwheel") {
            Picker("Action", selection: $manager.config.thumbwheelAction) {
                ForEach(MXThumbwheelAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }
            Toggle("Invert direction", isOn: $manager.config.invertThumbwheel)
        }
    }

    private var buttonsSection: some View {
        SettingsSection(title: "Buttons", footer: "Only this mouse's buttons change. System Default keeps each button's normal behavior.") {
            if !accessibilityPermission.isGranted {
                PermissionNotice(
                    message: "Accessibility is needed to perform button actions and scrolling.",
                    buttonTitle: "Grant Access…",
                    action: accessibilityPermission.request
                )
            }
            ActionPicker(title: "Middle Button", selection: $manager.config.middleButtonAction, actions: Self.actions)
            ActionPicker(title: "Back Button", selection: $manager.config.backButtonAction, actions: Self.actions)
            ActionPicker(title: "Forward Button", selection: $manager.config.forwardButtonAction, actions: Self.actions)
            ActionPicker(title: "Thumb Button", selection: $manager.config.gestureButtonClickAction, actions: Self.actions)
            ActionPicker(
                title: "Button Behind Wheel",
                selection: $manager.config.modeShiftButtonAction,
                actions: Self.actions,
                defaultTitle: "System Default (Ratchet / Free-Spin)"
            )
            ActionPicker(title: "Haptic Panel", selection: $manager.config.hapticPanelButtonAction, actions: Self.actions)
        }
    }

    private var gesturesSection: some View {
        SettingsSection(title: "Gestures", footer: "Hold the thumb button or the haptic panel and move the mouse in a direction.") {
            Toggle("Hold & drag gestures", isOn: $manager.config.gesturesEnabled)
            if manager.config.gesturesEnabled {
                ActionPicker(title: "Up", selection: $manager.config.gestureUpAction, actions: Self.actions)
                ActionPicker(title: "Down", selection: $manager.config.gestureDownAction, actions: Self.actions)
                ActionPicker(title: "Left", selection: $manager.config.gestureLeftAction, actions: Self.actions)
                ActionPicker(title: "Right", selection: $manager.config.gestureRightAction, actions: Self.actions)
            }
        }
    }

    private var onboardMemorySection: some View {
        SettingsSection(title: "Onboard Memory", footer: "Saves buttons set to Back, Forward or Ratchet / Free-Spin to the mouse a few seconds after a change, so they keep working without Aeron Tools. Gestures and other actions need the app.") {
            Toggle("Save settings to the mouse", isOn: $manager.savesToMouse)
            switch manager.mouseSaveState {
            case .idle:
                EmptyView()
            case .saving:
                LabeledContent("Status", value: "Saving…")
            case .saved(let buttons):
                LabeledContent("Status", value: buttons.isEmpty ? "Saved; no buttons have a native action" : "Saved: \(buttons.formatted(.list(type: .and)))")
            case .failed(let message):
                LabeledContent("Status") {
                    Text(message)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}
