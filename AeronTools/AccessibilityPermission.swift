import AppKit
import ApplicationServices

/// Single source of truth for the Accessibility permission, which event taps and synthesized input require.
/// Event-driven: rechecked on the system's accessibility-change distributed notification and whenever
/// the app becomes active, so nothing polls while the permission is missing.
@Observable
final class AccessibilityPermission {
    static let shared = AccessibilityPermission()

    private(set) var isGranted = AXIsProcessTrusted() {
        didSet {
            guard isGranted != oldValue else { return }
            changeHandlers.forEach { $0() }
        }
    }

    @ObservationIgnored private var changeHandlers: [() -> Void] = []
    @ObservationIgnored private var recheckTask: Task<Void, Never>?

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AccessibilityPermission.shared.refresh() }
        }
        // Posted by the system whenever any app's Accessibility trust changes in System Settings.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AccessibilityPermission.shared.scheduleRecheck() }
        }
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

    func refresh() {
        isGranted = AXIsProcessTrusted()
    }

    /// The notification arrives just before the trust database commits, so a single delayed check reads the new value.
    private func scheduleRecheck() {
        recheckTask?.cancel()
        recheckTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }
}
