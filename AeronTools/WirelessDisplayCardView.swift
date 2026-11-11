import SwiftUI

// MARK: - WirelessDisplayCardView

struct WirelessDisplayCardView: View {
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
