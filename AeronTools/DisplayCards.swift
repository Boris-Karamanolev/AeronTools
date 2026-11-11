import SwiftUI

// MARK: - ExternalDisplayCard

struct ExternalDisplayCard: View {
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

struct MacBookDisplayCard: View {
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
