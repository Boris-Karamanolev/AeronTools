import SwiftUI

// MARK: - ThermalsCardView

struct ThermalsCardView: View {
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
