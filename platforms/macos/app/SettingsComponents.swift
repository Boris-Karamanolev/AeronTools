import SwiftUI

// MARK: - Shared Settings Components
//
// The one settings style used across the app: grouped sections with a header, plain rows (toggles, pickers,
// sliders, labeled values) and at most one footer explaining the section. Every tab and accessory page is
// built from these, so they look and behave the same.

/// A grouped section with a header and an optional one-paragraph footer.
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        Section {
            content
        } header: {
            Text(title)
        } footer: {
            if let footer {
                Text(footer)
            }
        }
    }
}

/// Green while a device or feature is active, grey otherwise.
struct StatusDot: View {
    let isActive: Bool

    var body: some View {
        Circle()
            .fill(isActive ? Color.green : Color.secondary.opacity(0.5))
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

/// A missing permission: what it's needed for, and a button that fixes it.
struct PermissionNotice: View {
    let message: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(buttonTitle, action: action)
                .controlSize(.small)
        }
    }
}

/// A whole-number slider. By default it reports its value once, when released, so dragging sends a single
/// write to a device (needed for memory writes like an onboard profile). With `commitsWhileDragging`, every step
/// is reported as it's reached, for cheap live settings like keyboard brightness. Either way the slider keeps
/// showing the chosen value until the model catches up, so it never jumps back while a device replies.
struct LevelSlider: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    /// Shown instead of the number at the lowest level, e.g. "Off".
    var lowestLabel: String?
    var commitsWhileDragging = false
    let onCommit: (Int) -> Void

    @State private var draft: Int?
    @State private var isEditing = false

    private var shown: Int { draft ?? value }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(
                    value: Binding(
                        get: { Double(shown) },
                        set: { newValue in
                            let level = Int(newValue.rounded())
                            guard level != draft else { return }
                            draft = level
                            if commitsWhileDragging && level != value { onCommit(level) }
                        }
                    ),
                    in: Double(range.lowerBound)...Double(range.upperBound),
                    step: 1
                ) { editing in
                    isEditing = editing
                    guard !editing, let draft, !commitsWhileDragging, draft != value else { return }
                    onCommit(draft)
                }
                .frame(width: 180)
                Text(shown == range.lowerBound ? (lowestLabel ?? "\(shown)") : "\(shown)")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
        // The device confirmed the value, or reported another one after the drag ended (e.g. it refused the
        // change): show the model again.
        .onChange(of: value) { _, newValue in
            if draft == newValue || !isEditing { draft = nil }
        }
    }
}

/// A continuous slider with a formatted value, for settings that apply instantly (brightness, scroll speed).
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let format: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Group {
                    if let step {
                        Slider(value: $value, in: range, step: step)
                    } else {
                        Slider(value: $value, in: range)
                    }
                }
                .frame(width: 180)
                Text(format(value))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}

extension ValueSlider {
    /// A 0–100% slider over a 0…1 value.
    static func percent(_ title: String, value: Binding<Float>) -> ValueSlider {
        ValueSlider(
            title: title,
            value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Float($0) }),
            range: 0...1,
            format: { "\(Int(($0 * 100).rounded()))%" }
        )
    }
}

/// Picks the action a button (or gesture) performs.
struct ActionPicker: View {
    let title: String
    @Binding var selection: AccessoryButtonAction
    var actions: [AccessoryButtonAction] = AccessoryButtonAction.general
    /// Overrides the "System Default" label when the default does something specific on this control.
    var defaultTitle: String?

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(actions) { action in
                Text(action == .systemDefault ? (defaultTitle ?? action.title) : action.title).tag(action)
            }
        }
    }
}

/// DPI presets plus a field for any exact value. Changes apply on tap or Return.
struct DPIControl: View {
    let dpi: Int
    let presets: [Int]
    let range: ClosedRange<Int>
    let onCommit: (Int) -> Void

    @State private var text = ""

    var body: some View {
        LabeledContent("DPI") {
            HStack(spacing: 6) {
                ForEach(presets.filter(range.contains), id: \.self) { preset in
                    Button(String(preset)) { onCommit(preset) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(dpi == preset ? .accentColor : nil)
                }
                TextField("DPI", text: $text)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    .onSubmit {
                        if let value = Int(text.trimmingCharacters(in: .whitespaces)) {
                            onCommit(min(max(value, range.lowerBound), range.upperBound))
                        }
                    }
            }
        }
        .onChange(of: dpi, initial: true) { _, dpi in
            text = String(dpi)
        }
    }
}

/// One permission in a permissions list: granted, or a button that asks for it.
struct PermissionStatusRow: View {
    let title: String
    let isGranted: Bool
    let grant: () -> Void

    var body: some View {
        LabeledContent(title) {
            if isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Grant Access…", action: grant)
                    .controlSize(.small)
            }
        }
    }
}

/// One key in a `KeyRowPicker`: its label (e.g. "F4"), the symbol printed on it, and whether it can be remapped.
struct KeyCapInfo: Identifiable {
    let id: Int
    let label: String
    let systemImage: String?
    var isEnabled = true
}

/// A row of keycaps drawn as outlines with their printed symbols. Clicking a key opens a menu to pick its
/// action; remapped keys are outlined in the accent colour.
struct KeyRowPicker: View {
    let keys: [KeyCapInfo]
    let action: (Int) -> AccessoryButtonAction
    let onSelect: (Int, AccessoryButtonAction) -> Void
    var actions: [AccessoryButtonAction] = AccessoryButtonAction.general
    /// Names the key's own function in place of "System Default".
    var defaultTitle = "Key's Own Function"

    var body: some View {
        HStack(spacing: 5) {
            ForEach(keys) { key in
                Menu {
                    Picker(key.label, selection: Binding(
                        get: { action(key.id) },
                        set: { onSelect(key.id, $0) }
                    )) {
                        ForEach(actions) { option in
                            Text(option == .systemDefault ? defaultTitle : option.title).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    KeyCap(key: key, isRemapped: action(key.id) != .systemDefault)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .disabled(!key.isEnabled)
                .opacity(key.isEnabled ? 1 : 0.4)
                .help(action(key.id) == .systemDefault ? key.label : "\(key.label): \(action(key.id).title)")
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct KeyCap: View {
    let key: KeyCapInfo
    let isRemapped: Bool

    var body: some View {
        VStack(spacing: 3) {
            if let systemImage = key.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
            }
            Text(key.label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 36, height: 34)
        .background(RoundedRectangle(cornerRadius: 6).fill(isRemapped ? Color.accentColor.opacity(0.15) : Color.clear))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isRemapped ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}
