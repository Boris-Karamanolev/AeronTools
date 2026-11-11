import Foundation
import AppKit
import CoreGraphics
import Observation

// MARK: - Wireless Virtual Display & Streaming Coordinator

@Observable
@MainActor
public final class WirelessDisplayManager {
    public static let shared = WirelessDisplayManager()

    private static let configKey = "wirelessDisplay.config"
    private static let portKey = "wirelessDisplay.serverPort"
    private static let connectionModeKey = "wirelessDisplay.connectionMode"
    private static let captiveBypassKey = "wirelessDisplay.captiveBypass"

    // MARK: - Persistent Settings

    var connectionMode: ConnectionMode {
        didSet {
            UserDefaults.standard.set(connectionMode.rawValue, forKey: Self.connectionModeKey)
            if connectionMode == .hotspotScreenOnly {
                captivePortalBypassEnabled = true
            }
        }
    }

    var serverPort: UInt16 {
        didSet {
            UserDefaults.standard.set(Int(serverPort), forKey: Self.portKey)
        }
    }

    var captivePortalBypassEnabled: Bool {
        didSet {
            UserDefaults.standard.set(captivePortalBypassEnabled, forKey: Self.captiveBypassKey)
            syncLiveServerConfig()
        }
    }

    var config: WirelessDisplayConfig {
        didSet {
            saveConfig()
            syncLiveConfig(from: oldValue)
        }
    }

    // MARK: - Runtime State

    private(set) var isStreaming: Bool = false {
        didSet { DisplayStateModel.shared.updateCaffeine() }
    }
    private(set) var isStartingOrStopping: Bool = false

    private(set) var previewImage: CGImage?
    private(set) var measuredFPS: Double = 0
    private(set) var frameKB: Int = 0
    private(set) var activeDisplayID: CGDirectDisplayID?

    private(set) var networkInterfaces: [NetworkInterfaceAddress] = []
    private(set) var hasScreenRecordingPermission: Bool = false
    private(set) var isVirtualDisplaySupported: Bool = false

    private(set) var diagnostics: [DiagnosticEntry] = []
    private(set) var touchEventsCount: Int = 0

    // MARK: - Subsystems

    @ObservationIgnored private let virtualDisplayManager = VirtualDisplayManager()
    @ObservationIgnored private let webServer = StreamingWebServer()
    @ObservationIgnored private let touchManager = TouchInjectionManager()
    @ObservationIgnored private var pipeline: ScreenCapturePipeline?
    /// Bumped by every start, stop, and rebuild. Async work that resumes with an older value has been
    /// superseded and must discard what it created instead of installing it.
    @ObservationIgnored private var sessionGeneration: UInt64 = 0
    /// The most recently scheduled rebuild; rebuilds run one at a time.
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private let previewVisibilityLock = NSLock()
    @ObservationIgnored private nonisolated(unsafe) var _isPreviewVisible: Bool = false

    private init() {
        let defaults = UserDefaults.standard
        if let rawMode = defaults.string(forKey: Self.connectionModeKey),
           let mode = ConnectionMode(rawValue: rawMode) {
            self.connectionMode = mode
        } else {
            self.connectionMode = .sameNetwork
        }

        let savedPort = defaults.integer(forKey: Self.portKey)
        self.serverPort = (1024...65535).contains(savedPort) ? UInt16(savedPort) : 8080
        self.captivePortalBypassEnabled = defaults.object(forKey: Self.captiveBypassKey) as? Bool ?? true

        if let data = defaults.data(forKey: Self.configKey),
           let decoded = try? JSONDecoder().decode(WirelessDisplayConfig.self, from: data) {
            self.config = decoded
        } else {
            self.config = WirelessDisplayConfig()
        }

        self.isVirtualDisplaySupported = virtualDisplayManager.isRuntimeSupported

        guard !AppDelegate.isRunningTests else { return }

        refreshPermissions()
        refreshNetworkInterfaces()
        setupCallbacks()
    }

    // MARK: - Computed Properties

    var primaryStreamURL: String {
        if let preferred = networkInterfaces.first {
            return "http://\(preferred.ipAddress):\(serverPort)"
        }
        return "http://127.0.0.1:\(serverPort)"
    }

    var hasActiveVirtualDisplay: Bool {
        isStreaming && virtualDisplayManager.activeDisplayID != nil
    }

    func setPreviewVisible(_ visible: Bool) {
        previewVisibilityLock.lock()
        _isPreviewVisible = visible
        previewVisibilityLock.unlock()
    }

    nonisolated private func isPreviewCurrentlyVisible() -> Bool {
        previewVisibilityLock.lock()
        defer { previewVisibilityLock.unlock() }
        return _isPreviewVisible
    }

    // MARK: - Persistence & Live Config Sync

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.configKey)
        }
    }

    private func syncLiveServerConfig() {
        touchManager.updateTarget(displayID: activeDisplayID, isEnabled: config.allowTouch)
        guard isStreaming else { return }
        webServer.updateConfiguration(
            config: config,
            touchEnabled: config.allowTouch,
            captivePortalBypass: captivePortalBypassEnabled
        )
    }

    private func syncLiveConfig(from oldConfig: WirelessDisplayConfig) {
        touchManager.updateTarget(displayID: activeDisplayID, isEnabled: config.allowTouch)
        guard isStreaming else { return }
        pipeline?.jpegQuality = config.jpegQuality
        syncLiveServerConfig()

        let needsRebuild =
            oldConfig.preset != config.preset ||
            oldConfig.scale != config.scale ||
            oldConfig.sourceType != config.sourceType ||
            oldConfig.fps != config.fps

        if needsRebuild {
            scheduleRebuild()
        }
    }

    /// Queues a rebuild behind any in-flight one. Rapid config changes coalesce: superseded
    /// rebuilds are skipped, and one already in flight discards its result when it finishes.
    private func scheduleRebuild() {
        sessionGeneration &+= 1
        let generation = sessionGeneration
        let previous = rebuildTask
        rebuildTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, generation == self.sessionGeneration else { return }
            await self.rebuildPipelineWhileStreaming(generation: generation)
        }
    }

    // MARK: - Callbacks

    private func setupCallbacks() {
        webServer.onLog = { [weak self] level, msg in
            Task { @MainActor [weak self] in
                self?.log(level, msg)
            }
        }

        let touchMgr = self.touchManager
        webServer.onTouchEvent = { payload in
            // Direct low-latency injection on `touchManager.eventQueue` without waiting for `@MainActor`
            touchMgr.injectTouch(payload)
        }

        // macOS posts no notification for Screen Recording changes; they're made in System Settings,
        // so re-check whenever the user comes back to the app.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { WirelessDisplayManager.shared.refreshPermissions() }
        }
    }

    // MARK: - Permissions & Network Discovery

    func refreshPermissions() {
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
        isVirtualDisplaySupported = virtualDisplayManager.isRuntimeSupported
    }

    func requestScreenRecordingPermission() {
        _ = CGRequestScreenCaptureAccess()
        refreshPermissions()
        log(.info, "Requested Screen Recording permission. Enable Aeron Tools in System Settings > Privacy & Security.")
    }

    func refreshNetworkInterfaces() {
        networkInterfaces = NetworkEnvironmentService.activeIPv4Interfaces()
    }

    // MARK: - Session Control

    func toggleSession() {
        Task { @MainActor in
            if isStreaming {
                await stopSession()
            } else {
                await startSession()
            }
        }
    }

    func startSession() async {
        guard !isStreaming, !isStartingOrStopping else { return }
        isStartingOrStopping = true
        defer {
            isStartingOrStopping = false
            StatusBarController.shared.updateIcon()
        }

        refreshPermissions()
        refreshNetworkInterfaces()

        if !hasScreenRecordingPermission {
            _ = CGRequestScreenCaptureAccess()
            refreshPermissions()
        }

        log(.info, "Starting Wireless Display (\(config.preset.shortName)) in [\(connectionMode.rawValue)] mode…")

        sessionGeneration &+= 1
        let generation = sessionGeneration
        let (displayID, createdPipeline, createdVirtualDisplay) = await createAndStartPipeline(for: config)
        guard generation == sessionGeneration else {
            await discardSupersededPipeline(createdPipeline, virtualDisplay: createdVirtualDisplay)
            return
        }
        self.activeDisplayID = displayID
        self.pipeline = createdPipeline
        self.touchManager.updateTarget(displayID: displayID, isEnabled: config.allowTouch)

        do {
            try webServer.start(
                port: serverPort,
                pipeline: createdPipeline,
                config: config,
                touchEnabled: config.allowTouch,
                captivePortalBypass: captivePortalBypassEnabled
            )
            isStreaming = true
            DisplayStateModel.shared.refreshDisplays()
            log(.success, "Wireless Display ready at \(primaryStreamURL)")
        } catch {
            log(.error, "Failed to start web server on port \(serverPort): \(error.localizedDescription)")
            await stopSession()
        }
    }

    func stopSession() async {
        guard isStreaming || pipeline != nil || virtualDisplayManager.activeDisplayID != nil else { return }
        isStartingOrStopping = true
        defer {
            isStartingOrStopping = false
            StatusBarController.shared.updateIcon()
        }

        // Invalidate any in-flight rebuild so it tears down its pipeline instead of installing it.
        sessionGeneration &+= 1

        // Safety check: if the built-in MacBook screen was turned off and no physical external displays
        // are connected, restore the built-in screen before detaching the virtual display.
        let displayModel = DisplayStateModel.shared
        if displayModel.isBuiltinTurnedOff && !displayModel.hasExternalDisplays {
            displayModel.turnOnBuiltin()
            log(.info, "Restored built-in MacBook display before detaching wireless screen.")
        }

        webServer.stop()

        if let existingPipeline = pipeline {
            await existingPipeline.stop()
        }
        pipeline = nil
        virtualDisplayManager.destroyVirtualDisplay()

        previewImage = nil
        measuredFPS = 0
        frameKB = 0
        activeDisplayID = nil
        isStreaming = false

        displayModel.refreshDisplays()
        log(.info, "Stopped Wireless Display session and detached virtual display.")
    }

    /// Synchronous teardown used during `applicationWillTerminate`.
    func stopSessionForTermination() {
        webServer.stop()
        virtualDisplayManager.destroyVirtualDisplay()
        pipeline = nil
        activeDisplayID = nil
        isStreaming = false
    }

    private func rebuildPipelineWhileStreaming(generation: UInt64) async {
        guard isStreaming else { return }

        if let existing = pipeline {
            await existing.stop()
        }
        // A stop or newer rebuild during the await above owns the session state now.
        guard generation == sessionGeneration else { return }
        pipeline = nil
        virtualDisplayManager.destroyVirtualDisplay()
        previewImage = nil
        measuredFPS = 0
        frameKB = 0
        activeDisplayID = nil

        let (displayID, newPipeline, newVirtualDisplay) = await createAndStartPipeline(for: config)
        guard generation == sessionGeneration else {
            await discardSupersededPipeline(newPipeline, virtualDisplay: newVirtualDisplay)
            return
        }
        activeDisplayID = displayID
        pipeline = newPipeline
        touchManager.updateTarget(displayID: displayID, isEnabled: config.allowTouch)

        webServer.updatePipeline(newPipeline)
        syncLiveServerConfig()
    }

    /// Stops a pipeline whose session was stopped or superseded while it was starting, so its
    /// capture doesn't keep encoding frames in the background. The virtual display is only
    /// destroyed if it is still the one this pipeline created; virtual display IDs can be reused,
    /// so identity is compared rather than the display ID.
    private func discardSupersededPipeline(_ stalePipeline: ScreenCapturePipeline, virtualDisplay: NSObject?) async {
        await stalePipeline.stop()
        if let virtualDisplay, virtualDisplayManager.activeDisplay?.backingObject === virtualDisplay {
            virtualDisplayManager.destroyVirtualDisplay()
        }
    }

    private func createAndStartPipeline(
        for config: WirelessDisplayConfig
    ) async -> (CGDirectDisplayID, ScreenCapturePipeline, virtualDisplay: NSObject?) {
        var createdVirtualDisplay: NSObject?
        let targetDisplayID: CGDirectDisplayID
        if config.sourceType == .virtualExtended {
            if let vID = virtualDisplayManager.createVirtualDisplay(
                name: "Aeron Tools Wireless",
                width: config.preset.width,
                height: config.preset.height,
                scale: config.scale,
                refreshRate: Double(config.fps)
            ) {
                targetDisplayID = vID
                createdVirtualDisplay = virtualDisplayManager.activeDisplay?.backingObject
                log(.success, "Created Virtual Display (ID \(vID)) · \(config.logicalWidth)×\(config.logicalHeight)")
            } else {
                targetDisplayID = CGMainDisplayID()
                log(.warning, "Virtual Display unavailable; mirroring MacBook Screen (\(targetDisplayID)) instead.")
            }
        } else {
            targetDisplayID = CGMainDisplayID()
            log(.info, "Mirroring MacBook Screen (\(targetDisplayID)).")
        }

        try? await Task.sleep(nanoseconds: 150_000_000)

        let newPipeline = ScreenCapturePipeline(
            targetDisplayID: targetDisplayID,
            width: config.preset.width,
            height: config.preset.height,
            fps: config.fps,
            jpegQuality: config.jpegQuality
        )

        let server = self.webServer
        newPipeline.onEncodedFrame = { data, index in
            server.notifyNewFrame(data: data, index: index)
        }

        newPipeline.hasActiveViewers = {
            server.hasActiveViewers()
        }

        newPipeline.shouldGeneratePreview = { [weak self] in
            self?.isPreviewCurrentlyVisible() ?? false
        }

        newPipeline.onPreviewFrame = { [weak self] cgImg, fps, bytes in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let cgImg {
                    self.previewImage = cgImg
                }
                self.measuredFPS = fps
                self.frameKB = max(1, bytes / 1024)
            }
        }

        newPipeline.onError = { [weak self] errMsg in
            Task { @MainActor [weak self] in
                self?.log(.error, "Stream error: \(errMsg)")
            }
        }

        do {
            try await newPipeline.start()
            log(.success, "ScreenCaptureKit pipeline active at \(config.fps) FPS.")
        } catch {
            log(.warning, "Live capture awaiting Screen Recording permission (\(error.localizedDescription)). Serving test pattern.")
        }

        return (targetDisplayID, newPipeline, createdVirtualDisplay)
    }

    // MARK: - Tesla Hotspot Bridge Helper (`198.18.0.1` Alias)

    func applyTeslaHotspotAliasWithAdminPrompt() {
        let port = max(1024, serverPort)
        let cmd = "ifconfig bridge100 alias 198.18.0.1 netmask 255.255.255.0 up && (echo 'rdr pass on bridge100 inet proto tcp from any to 198.18.0.1 port 80 -> 127.0.0.1 port \(port)' | pfctl -ef - || true)"
        let appleScriptSource = "do shell script \"\(cmd)\" with administrator privileges"

        log(.info, "Configuring bridge100 alias 198.18.0.1 for Tesla browser…")
        Task.detached {
            var errorDict: NSDictionary?
            let script = NSAppleScript(source: appleScriptSource)
            _ = script?.executeAndReturnError(&errorDict)
            let errMessage = errorDict?[NSAppleScript.errorMessage] as? String
            await MainActor.run {
                if let errMessage {
                    self.log(.error, "Hotspot alias failed: \(errMessage)")
                } else {
                    self.log(.success, "Configured 198.18.0.1 on bridge100! Open http://198.18.0.1:\(port) in Tesla browser.")
                    self.refreshNetworkInterfaces()
                }
            }
        }
    }

    // MARK: - Utilities

    func copyURLToClipboard(_ urlString: String? = nil) {
        let target = urlString ?? primaryStreamURL
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(target, forType: .string)
        log(.info, "Copied \(target) to clipboard.")
    }

    func openInLocalBrowser() {
        if let url = URL(string: primaryStreamURL) {
            NSWorkspace.shared.open(url)
        }
    }

    func log(_ level: DiagnosticEntry.Level, _ message: String) {
        let entry = DiagnosticEntry(timestamp: Date(), level: level, message: message)
        diagnostics.insert(entry, at: 0)
        if diagnostics.count > 80 {
            diagnostics.removeLast(diagnostics.count - 80)
        }
    }
}
