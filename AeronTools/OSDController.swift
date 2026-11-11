import SwiftUI
import AppKit
import Observation

/// A brightness/volume HUD drawn to match the system one. macOS 27's private OSD framework no longer
/// shows brightness for third-party callers and its volume path never reaches the HUD, so we draw our own.
@MainActor
final class OSDController {
    static let shared = OSDController()

    enum Kind {
        case brightness, volume, muted
    }

    @Observable
    @MainActor
    final class State {
        var kind: Kind = .brightness
        var level: Float = 0
        var title = ""
    }

    private let state = State()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    private let size = NSSize(width: 280, height: 64)
    private let margin: CGFloat = 10

    func show(_ kind: Kind, level: Float, title: String, on displayID: CGDirectDisplayID) {
        state.kind = kind
        state.level = max(0, min(1, level))
        state.title = title

        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Top-right of the screen, below the menu bar, where the system HUD appears.
        let screen = NSScreen.screens.first { $0.displayID == displayID } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin))
        }

        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: OSDView(state: state))
        return panel
    }
}

private struct OSDView: View {
    let state: OSDController.State

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 18, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 6) {
                Text(state.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.15))
                        Capsule()
                            .fill(.primary)
                            .frame(width: proxy.size.width * CGFloat(state.kind == .muted ? 0 : state.level))
                    }
                }
                .frame(height: 6)
                .animation(.easeOut(duration: 0.12), value: state.level)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(HUDBackground())
    }

    private var symbolName: String {
        switch state.kind {
        case .brightness:
            return "sun.max.fill"
        case .muted:
            return "speaker.slash.fill"
        case .volume:
            switch state.level {
            case 0: return "speaker.fill"
            case ..<0.34: return "speaker.wave.1.fill"
            case ..<0.67: return "speaker.wave.2.fill"
            default: return "speaker.wave.3.fill"
            }
        }
    }
}

/// Liquid Glass on macOS 26+, the classic HUD material before that.
private struct HUDBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 22))
        } else {
            content.background(.regularMaterial, in: .rect(cornerRadius: 22))
        }
    }
}
