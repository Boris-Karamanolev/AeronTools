import AppKit
import ApplicationServices

/// Automatically terminates regular macOS applications when their last standard window closes.
/// Event-driven via `NSWorkspace` application notifications and per-app `AXObserver` callbacks.
@MainActor
final class LastWindowQuitController {
    static let shared = LastWindowQuitController()

    /// Bundle identifiers that should never be auto-terminated when their last window closes.
    nonisolated static let excludedBundleIdentifiers: Set<String> = [
        "com.apple.finder"
    ]

    /// Window subroles that count as open user windows keeping an application alive.
    nonisolated static let qualifyingWindowSubroles: Set<String> = [
        kAXStandardWindowSubrole as String,
        kAXDialogSubrole as String
    ]

    nonisolated static func shouldTrackApplication(
        bundleIdentifier: String?,
        activationPolicy: NSApplication.ActivationPolicy,
        isTerminated: Bool,
        isCurrentProcess: Bool
    ) -> Bool {
        guard !isCurrentProcess, !isTerminated, activationPolicy == .regular else {
            return false
        }
        if let bundleIdentifier, excludedBundleIdentifiers.contains(bundleIdentifier) {
            return false
        }
        return true
    }

    nonisolated static func isQualifyingWindow(role: String?, subrole: String?) -> Bool {
        guard role == (kAXWindowRole as String), let subrole else {
            return false
        }
        return qualifyingWindowSubroles.contains(subrole)
    }

    private struct ObservedApp {
        let pid: pid_t
        let appElement: AXUIElement
        let observer: AXObserver
        var hasHadStandardWindow: Bool = false
        var checkTask: Task<Void, Never>?
        var launchSyncTask: Task<Void, Never>?
    }

    private var isEnabled = false
    private var isRunning = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var observedApps: [pid_t: ObservedApp] = [:]

    private init() {
        AccessibilityPermission.shared.onChange { [weak self] in
            guard let self, self.isEnabled else { return }
            AccessibilityPermission.shared.isGranted ? self.start() : self.stop()
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        enabled ? start() : stop()
    }

    private func start() {
        guard !isRunning else { return }

        let permission = AccessibilityPermission.shared
        permission.request()
        // Started again from the permission change handler once the user grants access.
        guard permission.isGranted else { return }

        isRunning = true

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    guard let self, let app else { return }
                    self.handleAppLaunched(app)
                }
            },
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    guard let self, let app else { return }
                    self.observeIfEligible(app)
                    _ = self.syncWindows(for: app.processIdentifier)
                }
            },
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    guard let self, let app else { return }
                    self.stopObserving(pid: app.processIdentifier)
                }
            }
        ]

        for app in NSWorkspace.shared.runningApplications {
            observeIfEligible(app)
        }
    }

    private func stop() {
        guard isRunning else { return }
        isRunning = false

        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            center.removeObserver(token)
        }
        workspaceObservers.removeAll()

        let pids = Array(observedApps.keys)
        for pid in pids {
            stopObserving(pid: pid)
        }
    }

    private func shouldManage(_ app: NSRunningApplication) -> Bool {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        return Self.shouldTrackApplication(
            bundleIdentifier: app.bundleIdentifier,
            activationPolicy: app.activationPolicy,
            isTerminated: app.isTerminated,
            isCurrentProcess: app.processIdentifier == currentPID
        )
    }

    private func handleAppLaunched(_ app: NSRunningApplication) {
        observeIfEligible(app)
        let pid = app.processIdentifier
        guard observedApps[pid] != nil else { return }

        // Apps often create their initial window shortly after launching or switching activation policy.
        observedApps[pid]?.launchSyncTask?.cancel()
        observedApps[pid]?.launchSyncTask = Task { @MainActor [weak self] in
            for delayMs in [400, 1200] {
                try? await Task.sleep(for: .milliseconds(delayMs))
                guard !Task.isCancelled, let self, self.isRunning else { return }
                if let runningApp = NSRunningApplication(processIdentifier: pid) {
                    self.observeIfEligible(runningApp)
                }
                _ = self.syncWindows(for: pid)
            }
        }
    }

    private func observeIfEligible(_ app: NSRunningApplication) {
        guard shouldManage(app) else { return }
        let pid = app.processIdentifier
        guard observedApps[pid] == nil else { return }

        var observer: AXObserver?
        guard AXObserverCreate(pid, lastWindowAXObserverCallback, &observer) == .success,
              let observer else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = UnsafeMutableRawPointer(bitPattern: Int(pid))

        AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, refcon)
        AXObserverAddNotification(observer, appElement, kAXMainWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)

        observedApps[pid] = ObservedApp(
            pid: pid,
            appElement: appElement,
            observer: observer
        )

        _ = syncWindows(for: pid)
    }

    private func stopObserving(pid: pid_t) {
        guard let entry = observedApps.removeValue(forKey: pid) else { return }
        entry.checkTask?.cancel()
        entry.launchSyncTask?.cancel()
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(entry.observer), .commonModes)
    }

    fileprivate func handleAXNotification(pid: pid_t, element: AXUIElement, notification: String) {
        guard isRunning, observedApps[pid] != nil else { return }

        if notification == (kAXWindowCreatedNotification as String) {
            registerDestroyNotificationIfQualifying(window: element, pid: pid)
            if let count = syncWindows(for: pid), count > 0 {
                observedApps[pid]?.checkTask?.cancel()
                observedApps[pid]?.checkTask = nil
            }
            return
        }

        if notification == (kAXUIElementDestroyedNotification as String) {
            if observedApps[pid]?.hasHadStandardWindow == true {
                scheduleTerminationCheck(for: pid)
            }
            return
        }

        if notification == (kAXMainWindowChangedNotification as String)
            || notification == (kAXFocusedWindowChangedNotification as String) {
            if let count = syncWindows(for: pid) {
                if count > 0 {
                    observedApps[pid]?.checkTask?.cancel()
                    observedApps[pid]?.checkTask = nil
                } else if observedApps[pid]?.hasHadStandardWindow == true {
                    scheduleTerminationCheck(for: pid)
                }
            }
        }
    }

    private func scheduleTerminationCheck(for pid: pid_t) {
        guard observedApps[pid] != nil else { return }
        observedApps[pid]?.checkTask?.cancel()
        observedApps[pid]?.checkTask = Task { @MainActor [weak self] in
            // Allow brief window-to-window transitions (e.g. welcome screen to document window) to settle.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, self.isRunning else { return }
            guard let entry = self.observedApps[pid], entry.hasHadStandardWindow else { return }
            guard let app = NSRunningApplication(processIdentifier: pid),
                  self.shouldManage(app),
                  !app.isHidden else {
                return
            }

            guard let remaining = self.syncWindows(for: pid), remaining == 0 else {
                return
            }

            self.observedApps[pid]?.hasHadStandardWindow = false
            app.terminate()
        }
    }

    /// Queries the app's current accessible windows, registers destroy notifications on each qualifying window,
    /// and returns the number of qualifying open windows (or `nil` if the AX query could not complete).
    private func syncWindows(for pid: pid_t) -> Int? {
        guard let entry = observedApps[pid] else { return nil }

        var rawWindows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(entry.appElement, kAXWindowsAttribute as CFString, &rawWindows)
        let windows: [AXUIElement]
        switch result {
        case .success:
            windows = (rawWindows as? [AXUIElement]) ?? []
        case .noValue, .attributeUnsupported:
            windows = []
        default:
            return nil
        }

        var qualifyingCount = 0
        var sawStandardWindow = false
        let refcon = UnsafeMutableRawPointer(bitPattern: Int(pid))

        for window in windows {
            let role = Self.stringAttribute(kAXRoleAttribute as CFString, of: window)
            let subrole = Self.stringAttribute(kAXSubroleAttribute as CFString, of: window)
            guard Self.isQualifyingWindow(role: role, subrole: subrole) else { continue }

            qualifyingCount += 1
            if subrole == (kAXStandardWindowSubrole as String) {
                sawStandardWindow = true
            }
            AXObserverAddNotification(entry.observer, window, kAXUIElementDestroyedNotification as CFString, refcon)
        }

        if sawStandardWindow {
            observedApps[pid]?.hasHadStandardWindow = true
        }

        return qualifyingCount
    }

    private func registerDestroyNotificationIfQualifying(window: AXUIElement, pid: pid_t) {
        guard let entry = observedApps[pid] else { return }
        let role = Self.stringAttribute(kAXRoleAttribute as CFString, of: window)
        let subrole = Self.stringAttribute(kAXSubroleAttribute as CFString, of: window)
        guard Self.isQualifyingWindow(role: role, subrole: subrole) else { return }

        if subrole == (kAXStandardWindowSubrole as String) {
            observedApps[pid]?.hasHadStandardWindow = true
        }
        let refcon = UnsafeMutableRawPointer(bitPattern: Int(pid))
        AXObserverAddNotification(entry.observer, window, kAXUIElementDestroyedNotification as CFString, refcon)
    }

    private static func stringAttribute(_ attribute: CFString, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }
}

private nonisolated func lastWindowAXObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let pid = pid_t(Int(bitPattern: refcon))
    let name = notification as String
    MainActor.assumeIsolated {
        LastWindowQuitController.shared.handleAXNotification(pid: pid, element: element, notification: name)
    }
}
