import SwiftUI
import CoreGraphics
import AppKit
import Observation

// MARK: - ExternalDisplayInfo

public struct ExternalDisplayInfo: Identifiable, Sendable {
    public let id: CGDirectDisplayID
    public var name: String
    public var brightness: Float
    public var volume: Float
    public var isMuted: Bool
}

// MARK: - DisplayStateModel

@Observable
@MainActor
public final class DisplayStateModel {
    public static let shared = DisplayStateModel()

    public var externalDisplays: [ExternalDisplayInfo] = []
    public var isBuiltinPresent: Bool = false
    public var isBuiltinTurnedOff: Bool = false
    public var autoTurnOffBuiltin: Bool {
        didSet {
            UserDefaults.standard.set(autoTurnOffBuiltin, forKey: "autoTurnOffBuiltin")
            if autoTurnOffBuiltin && hasExternalDisplays && !isBuiltinTurnedOff {
                checkAutoTurnOff()
            }
        }
    }

    private var builtinDisplayID: CGDirectDisplayID?
    private var isTransitioning: Bool = false
    private var previousExternalCount: Int = 0
    private var watchdogTimer: Timer?
    private var reconfigTask: Task<Void, Never>?
    private var pendingAddedExternals = Set<CGDirectDisplayID>()
    // Externals seen while the panel was on; macOS's placeholder display only exists while it's off, so it never lands here.
    private var realExternalIDs = Set<CGDirectDisplayID>()

    public var hasExternalDisplays: Bool {
        !externalDisplays.isEmpty
    }

    private init() {
        self.autoTurnOffBuiltin = UserDefaults.standard.bool(forKey: "autoTurnOffBuiltin")

        let cachedID = UInt32(UserDefaults.standard.integer(forKey: "cachedBuiltinDisplayID"))
        if cachedID != 0 {
            self.builtinDisplayID = cachedID
            self.isBuiltinPresent = true
        }

        setupReconfigurationCallback()
        setupNotificationObservers()
        setupWatchdog()
        refreshDisplays()
    }

    // MARK: - Watchdog & Notification Observers

    // Safety net in case macOS doesn't deliver a reconfiguration callback for an unplug.
    private func setupWatchdog() {
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restoreIfRealExternalsGone()
                self?.refreshDisplays()
            }
        }
    }

    private func setupReconfigurationCallback() {
        CGDisplayRegisterReconfigurationCallback({ (display, flags, userInfo) in
            guard let userInfo = userInfo else { return }
            let model = Unmanaged<DisplayStateModel>.fromOpaque(userInfo).takeUnretainedValue()
            Task { @MainActor in
                model.handleReconfiguration(display: display, flags: flags)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                DisplayStateModel.shared.refreshDisplays()
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                DisplayStateModel.shared.refreshDisplays()
            }
        }
    }

    private func handleReconfiguration(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        guard !flags.contains(.beginConfigurationFlag) else { return }

        if flags.contains(.addFlag) && display != builtinDisplayID && CGDisplayIsBuiltin(display) == 0 {
            pendingAddedExternals.insert(display)
        }

        // macOS delivers one callback per display; wait for the whole batch before acting.
        reconfigTask?.cancel()
        reconfigTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self.processReconfigurationBatch()
        }
    }

    private func processReconfigurationBatch() {
        let added = pendingAddedExternals
        pendingAddedExternals.removeAll()

        if let bID = builtinDisplayID, !isDisplayActive(bID) {
            restoreIfRealExternalsGone()
        } else if !added.isEmpty && autoTurnOffBuiltin {
            refreshDisplays()
            checkAutoTurnOff()
            return
        }
        refreshDisplays()
    }

    // Unplugging the last external makes macOS add a placeholder display, so counting externals
    // or watching removal events is unreliable. Instead: panel off + every known real external gone → turn on.
    private func restoreIfRealExternalsGone() {
        guard let panelID = savedPanelID ?? builtinDisplayID,
              !isDisplayActive(panelID),
              !realExternalIDs.isEmpty,
              !realExternalIDs.contains(where: { isDisplayActive($0) }) else { return }

        dlog("All external displays disconnected; turning built-in display back on")
        turnOnBuiltin()
    }

    // MARK: - Refresh Display Hierarchy

    public func refreshDisplays() {
        guard !isTransitioning else { return }

        let screenMap = getScreenNames()
        var detectedExternals: [ExternalDisplayInfo] = []

        if let builtin = DisplayHardwareManager.shared.findBuiltinDisplayID() {
            self.builtinDisplayID = builtin
            self.isBuiltinPresent = true
            UserDefaults.standard.set(Int(builtin), forKey: "cachedBuiltinDisplayID")
        }

        for id in DisplayHardwareManager.shared.getExternalDisplayIDs(builtinID: builtinDisplayID) {
            let name = screenMap[id] ?? "External Display"
            let brightness = DisplayHardwareManager.shared.getBrightness(for: id)

            let savedVol = UserDefaults.standard.float(forKey: "monitorVolume_\(name)")
            let volume = savedVol > 0 ? savedVol : 0.5
            let isMuted = UserDefaults.standard.bool(forKey: "monitorMuted_\(name)")

            detectedExternals.append(ExternalDisplayInfo(id: id, name: name, brightness: brightness, volume: volume, isMuted: isMuted))
        }

        self.externalDisplays = detectedExternals

        if let bID = self.builtinDisplayID {
            self.isBuiltinTurnedOff = !isDisplayActive(bID)
        }
        // Also seed when empty: the panel may already be off at launch (e.g. left off by a killed previous run).
        if !self.isBuiltinTurnedOff || realExternalIDs.isEmpty {
            realExternalIDs = Set(detectedExternals.map(\.id))
        }

        // Covers launch with a monitor already attached, where no "display added" event arrives.
        let newExternalCount = detectedExternals.count
        if autoTurnOffBuiltin && previousExternalCount == 0 && newExternalCount > 0 && !self.isBuiltinTurnedOff {
            checkAutoTurnOff()
        }
        self.previousExternalCount = newExternalCount
    }

    private func getScreenNames() -> [CGDirectDisplayID: String] {
        var dict: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                dict[num] = screen.localizedName
            }
        }
        return dict
    }

    // MARK: - Built-in Screen Control

    private var savedPanelID: CGDirectDisplayID? {
        let id = CGDirectDisplayID(UserDefaults.standard.integer(forKey: DisplayHardwareManager.disabledPanelIDKey))
        return id != 0 ? id : nil
    }

    public func checkAutoTurnOff() {
        guard autoTurnOffBuiltin, hasExternalDisplays, !isBuiltinTurnedOff, !isTransitioning, let bID = builtinDisplayID else {
            return
        }
        turnOffBuiltinDisplay(displayID: bID)
    }

    public func toggleBuiltinDisplay() {
        if isBuiltinTurnedOff {
            turnOnBuiltin()
        } else if hasExternalDisplays, let bID = builtinDisplayID {
            turnOffBuiltinDisplay(displayID: bID)
        }
    }

    private func turnOffBuiltinDisplay(displayID: CGDirectDisplayID) {
        guard hasExternalDisplays, !isTransitioning else { return }
        isTransitioning = true

        if DisplayHardwareManager.shared.turnOffBuiltinDisplay(displayID: displayID) {
            self.isBuiltinTurnedOff = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            self.isTransitioning = false
        }
    }

    /// Re-enables the panel by the ID saved at turn-off. Built-in detection is unreliable while the
    /// panel is off, so the current guess is only tried alongside it.
    public func turnOnBuiltin() {
        let ids = Set([savedPanelID, builtinDisplayID].compactMap { $0 })
        for id in ids {
            DisplayHardwareManager.shared.turnOnBuiltinDisplay(displayID: id)
        }
        isTransitioning = false
        refreshDisplays()
    }

    // MARK: - External Controls

    public func updateBrightness(for displayID: CGDirectDisplayID, level: Float) {
        if let idx = externalDisplays.firstIndex(where: { $0.id == displayID }) {
            externalDisplays[idx].brightness = level
            DisplayHardwareManager.shared.setBrightness(for: displayID, level: level)
        }
    }

    public func updateVolume(for displayID: CGDirectDisplayID, level: Float) {
        if let idx = externalDisplays.firstIndex(where: { $0.id == displayID }) {
            externalDisplays[idx].volume = level
            DisplayHardwareManager.shared.setMonitorVolume(level: level, displayName: externalDisplays[idx].name)
        }
    }

    public func toggleMonitorMuted(for displayID: CGDirectDisplayID) {
        if let idx = externalDisplays.firstIndex(where: { $0.id == displayID }) {
            externalDisplays[idx].isMuted.toggle()
            let isMuted = externalDisplays[idx].isMuted
            DisplayHardwareManager.shared.setMonitorMuted(isMuted, displayName: externalDisplays[idx].name)
        }
    }
}
