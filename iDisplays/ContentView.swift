import SwiftUI
import CoreGraphics
import ServiceManagement

// MARK: - ContentView

public struct ContentView: View {
    @Bindable var model = DisplayStateModel.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Label("iDisplays", systemImage: "display.2")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Quit iDisplays")
            }

            // External Monitors
            if model.externalDisplays.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "display.trianglebadge.exclamationmark")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No external display connected")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(model.externalDisplays) { display in
                    ExternalDisplayView(display: display, model: model)
                }
            }

            // MacBook Built-in Screen Section
            if model.isBuiltinPresent {
                Divider()
                MacBookDisplayView(model: model)
            }

            Divider()
            FooterView()
        }
        .padding(20)
        .frame(width: 380)
        .background(.ultraThinMaterial)
    }
}

// MARK: - ExternalDisplayView (Plain, Native, Liquid Glass)

private struct ExternalDisplayView: View {
    let display: ExternalDisplayInfo
    @Bindable var model: DisplayStateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Monitor Name
            Text(display.name)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)

            // Brightness Control
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Image(systemName: "sun.min.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)

                    Slider(
                        value: Binding(
                            get: { display.brightness },
                            set: { model.updateBrightness(for: display.id, level: $0) }
                        ),
                        in: 0...1
                    )

                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)

                    Text("\(Int(display.brightness * 100))%")
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
            }

            // Monitor Volume Control
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Button {
                        model.toggleMonitorMuted(for: display.id)
                    } label: {
                        Image(systemName: display.isMuted ? "speaker.slash.fill" : "speaker.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(display.isMuted ? .red : .secondary)
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
                    .disabled(display.isMuted)

                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)

                    Text(display.isMuted ? "Muted" : "\(Int(display.volume * 100))%")
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - MacBookDisplayView (Plain, Native, Liquid Glass)

private struct MacBookDisplayView: View {
    @Bindable var model: DisplayStateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MacBook Screen")
                            .font(.system(size: 17, weight: .medium))
                        Text(model.isBuiltinTurnedOff ? "Turned Off" : "Active")
                            .font(.system(size: 15))
                            .foregroundStyle(model.isBuiltinTurnedOff ? Color.secondary : Color.green)
                    }
                } icon: {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 20))
                        .foregroundStyle(model.isBuiltinTurnedOff ? .secondary : .primary)
                }

                Spacer()

                Button(model.isBuiltinTurnedOff ? "Turn On" : "Turn Off") {
                    model.toggleBuiltinDisplay()
                }
                .buttonStyle(.bordered)
                .tint(model.isBuiltinTurnedOff ? Color.accentColor : Color.primary)
                .controlSize(.large)
                .font(.system(size: 15, weight: .medium))
                .disabled(!model.hasExternalDisplays && !model.isBuiltinTurnedOff)
            }

            Toggle("Turn off automatically with external screen", isOn: $model.autoTurnOffBuiltin)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .toggleStyle(.checkbox)
                .disabled(!model.hasExternalDisplays)
                .padding(.top, 2)
        }
    }
}

// MARK: - FooterView

private struct FooterView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .toggleStyle(.checkbox)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        dlog("Launch at login change failed: \(error.localizedDescription)")
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            Label("⌘⇧D turns the MacBook screen back on", systemImage: "keyboard")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
    }
}
