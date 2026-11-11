import SwiftUI

// MARK: - WattageCardView (macOS Native Popover Style)

struct WattageCardView: View {
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
