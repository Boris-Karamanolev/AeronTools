import SwiftUI

// MARK: - DockPortsSection

/// The Ports section every dock and hub page uses: the dock drawn as its port panel, then the list of what's
/// plugged in. Ports with something in them are filled in the accent colour; clicking one lists only its devices.
/// `underglow` is drawn under the panel, e.g. a dock's lighting.
struct DockPortsSection<Underglow: View>: View {
    let monitor: DockPortMonitor
    @ViewBuilder let underglow: Underglow

    @State private var selectedPortID: String?

    private static var ethernetID: String { "ethernet" }

    var body: some View {
        SettingsSection(title: "Ports", footer: "Click a port to see what's plugged into it. Thunderbolt devices take the first free Thunderbolt port, since macOS doesn't tell which one they're in.") {
            VStack(spacing: 7) {
                panel
                underglow
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            portList
        }
    }

    // MARK: Panel

    private var panel: some View {
        let layout = monitor.layout
        return HStack(alignment: .top, spacing: 18) {
            portGroup("Thunderbolt 4") {
                PortGlyph(kind: .usbC, isOccupied: true)
                    .portLabel("Mac")
                    .help("Connected to this Mac")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Thunderbolt port to this Mac, connected")
                ForEach(layout.thunderbolt) { port in
                    portButton(port, kind: .usbC)
                }
            }
            if !layout.usbA.isEmpty {
                portGroup("USB-A") {
                    ForEach(layout.usbA) { port in
                        portButton(port, kind: .usbA)
                    }
                }
            }
            if monitor.model.hasEthernet {
                portGroup("Ethernet") {
                    let active = monitor.isEthernetLinkActive == true
                    PortButton(kind: .ethernet, label: active ? "Link" : "—", isOccupied: active,
                               isSelected: selectedPortID == Self.ethernetID,
                               help: active ? "Ethernet: connected" : "Ethernet: no cable connected") {
                        toggle(Self.ethernetID)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
        )
    }

    private func portGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 4) {
                content()
            }
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func portButton(_ port: DockTopology.Port, kind: PortGlyph.Kind) -> some View {
        let names = port.devices.map(\.name)
        return PortButton(kind: kind, label: "\(port.number)", isOccupied: !port.devices.isEmpty,
                          isSelected: selectedPortID == port.id,
                          help: names.isEmpty ? "\(port.title): empty" : "\(port.title): \(names.joined(separator: ", "))") {
            toggle(port.id)
        }
    }

    private func toggle(_ id: String) {
        selectedPortID = selectedPortID == id ? nil : id
    }

    // MARK: List

    @ViewBuilder
    private var portList: some View {
        let layout = monitor.layout
        let ports = layout.thunderbolt + layout.usbA
        let shown = ports.filter { selectedPortID == nil ? !$0.devices.isEmpty : $0.id == selectedPortID }
        let showsEthernet = layout.ethernetInterface != nil && (selectedPortID == nil || selectedPortID == Self.ethernetID)

        ForEach(shown) { port in
            if port.devices.isEmpty {
                Text("Nothing is plugged into \(port.title).")
                    .foregroundStyle(.secondary)
            }
            ForEach(port.devices) { device in
                deviceRow(name: device.name, detail: "\(port.title) · \(device.detail)", systemImage: device.systemImage)
            }
        }
        if showsEthernet {
            let active = monitor.isEthernetLinkActive == true
            deviceRow(name: "Ethernet", detail: active ? "Connected" : "No cable connected",
                      systemImage: "network", isDimmed: !active)
        }
        if selectedPortID == nil && shown.isEmpty && !showsEthernet {
            Text("Nothing is plugged in.")
                .foregroundStyle(.secondary)
        }
    }

    private func deviceRow(name: String, detail: String, systemImage: String, isDimmed: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(isDimmed ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}

extension DockPortsSection where Underglow == EmptyView {
    init(monitor: DockPortMonitor) {
        self.init(monitor: monitor) { EmptyView() }
    }
}

// MARK: - Port Drawing

private struct PortButton: View {
    let kind: PortGlyph.Kind
    let label: String
    let isOccupied: Bool
    let isSelected: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PortGlyph(kind: kind, isOccupied: isOccupied)
                .portLabel(label)
                .padding(.horizontal, 3)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear))
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One port drawn as its connector outline: a USB-C pill, a USB-A slot with its tongue, or an Ethernet jack.
private struct PortGlyph: View {
    enum Kind { case usbC, usbA, ethernet }

    let kind: Kind
    let isOccupied: Bool

    private var stroke: Color { isOccupied ? .accentColor : .secondary.opacity(0.6) }
    private var fill: Color { isOccupied ? Color.accentColor.opacity(0.3) : .clear }

    var body: some View {
        Group {
            switch kind {
            case .usbC:
                Capsule()
                    .fill(fill)
                    .strokeBorder(stroke, lineWidth: 1.2)
                    .frame(width: 22, height: 9)
                    .padding(.vertical, 3)
            case .usbA:
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(fill)
                    .strokeBorder(stroke, lineWidth: 1.2)
                    .frame(width: 26, height: 11)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(stroke)
                            .frame(width: 17, height: 3)
                            .padding(.top, 2.5)
                    }
                    .padding(.vertical, 2)
            case .ethernet:
                EthernetJackShape()
                    .fill(fill)
                    .overlay(EthernetJackShape().stroke(stroke, lineWidth: 1.2))
                    .frame(width: 20, height: 15)
            }
        }
        .frame(height: 15)
    }
}

private extension View {
    /// The small caption under a port.
    func portLabel(_ label: String) -> some View {
        VStack(spacing: 3) {
            self
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// An RJ45 jack: a square opening with the latch notch along the bottom.
private struct EthernetJackShape: Shape {
    func path(in rect: CGRect) -> Path {
        let notchWidth = rect.width * 0.42
        let notchTop = rect.maxY - rect.height * 0.24
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: notchTop))
        path.addLine(to: CGPoint(x: rect.midX + notchWidth / 2, y: notchTop))
        path.addLine(to: CGPoint(x: rect.midX + notchWidth / 2, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX - notchWidth / 2, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX - notchWidth / 2, y: notchTop))
        path.addLine(to: CGPoint(x: rect.minX, y: notchTop))
        path.closeSubpath()
        return path
    }
}

