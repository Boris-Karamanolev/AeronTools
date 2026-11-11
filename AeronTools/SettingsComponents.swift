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

/// A whole-number slider that only reports its value when released, so dragging sends a single change
/// (one write to a device instead of dozens).
struct LevelSlider: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    /// Shown instead of the number at the lowest level, e.g. "Off".
    var lowestLabel: String?
    let onCommit: (Int) -> Void

    @State private var draft: Double?

    private var shown: Int { draft.map { Int($0.rounded()) } ?? value }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(
                    value: Binding(get: { draft ?? Double(value) }, set: { draft = $0 }),
                    in: Double(range.lowerBound)...Double(range.upperBound),
                    step: 1
                ) { isEditing in
                    guard !isEditing, let draft else { return }
                    self.draft = nil
                    let committed = Int(draft.rounded())
                    if committed != value { onCommit(committed) }
                }
                .frame(width: 180)
                Text(shown == range.lowerBound ? (lowestLabel ?? "\(shown)") : "\(shown)")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
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
