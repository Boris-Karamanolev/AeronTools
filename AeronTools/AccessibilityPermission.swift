import AppKit
import ApplicationServices

/// Single source of truth for the Accessibility permission, which event taps and synthesized input require.
/// macOS posts no change notification, so the permission is polled while it is missing and rechecked
/// whenever the app becomes active (to catch a revocation made in System Settings).
@Observable
final class AccessibilityPermission {
    static let shared = AccessibilityPermission()

    private(set) var isGranted = AXIsProcessTrusted() {
        didSet {
            guard isGranted != oldValue else { return }
            changeHandlers.forEach { $0() }
            if !isGranted { startPolling() }
        }
    }

    @ObservationIgnored private var changeHandlers: [() -> Void] = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AccessibilityPermission.shared.refresh() }
        }
        if !isGranted { startPolling() }
    }

    /// Calls `handler` every time the permission is granted or revoked.
    func onChange(_ handler: @escaping () -> Void) {
        changeHandlers.append(handler)
    }

    /// Shows the system prompt, which offers to open System Settings, if the permission is missing.
    func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        isGranted = AXIsProcessTrustedWithOptions(options)
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refresh() {
        isGranted = AXIsProcessTrusted()
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task {
            while !isGranted {
                try? await Task.sleep(for: .seconds(2))
                refresh()
            }
            pollTask = nil
        }
    }
}
