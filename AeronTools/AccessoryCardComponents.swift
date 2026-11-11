import SwiftUI

// MARK: - Shared Accessory Card Components

/// Building blocks every accessory card uses, so all accessories look the same in the popover:
/// the card container, a header row (icon, name, connection status, trailing readout) and the battery badge.

extension View {
    /// The popover's standard card container, matching the display, wireless and power cards.
    func accessoryCardStyle() -> some View {
        padding(11)
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

/// Icon, device name and connection line, with a trailing readout (the battery badge by default).
struct AccessoryCardHeader<Trailing: View>: View {
    let systemImage: String
    let name: String
    let status: String
    /// Green dot while the device is answering, grey while it sleeps.
    let isOnline: Bool
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.18), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Circle()
                        .fill(isOnline ? Color.green : Color.secondary)
                        .frame(width: 5, height: 5)
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            trailing()
        }
    }
}

extension AccessoryCardHeader where Trailing == AccessoryBatteryBadge? {
    /// Header with the standard battery badge, shown only when the device reports a level.
    init(systemImage: String, name: String, status: String, isOnline: Bool, batteryPercent: Int?, isCharging: Bool) {
        self.init(systemImage: systemImage, name: name, status: status, isOnline: isOnline) {
            batteryPercent.map { AccessoryBatteryBadge(percent: $0, isCharging: isCharging) }
        }
    }
}

/// Battery level as a system battery symbol plus percentage; orange when low and not charging.
struct AccessoryBatteryBadge: View {
    let percent: Int
    let isCharging: Bool

    var body: some View {
        Label {
            Text("\(percent)%")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
        } icon: {
            Image(systemName: isCharging ? "battery.100percent.bolt" : symbol)
        }
        .foregroundStyle(percent <= 15 && !isCharging ? Color.orange : Color.primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isCharging ? "Battery \(percent) percent, charging" : "Battery \(percent) percent")
    }

    private var symbol: String {
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
