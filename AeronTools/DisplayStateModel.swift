import SwiftUI
import CoreGraphics
import AppKit
import Observation
import IOKit.pwr_mgt

// MARK: - ExternalDisplayInfo

public struct ExternalDisplayInfo: Identifiable, Equatable, Sendable {
    public let id: CGDirectDisplayID
    /// Stable per-monitor key for saved settings (see MonitorIdentity).
    let settingsKey: String
    public var name: String
    public var brightness: Float
    public var volume: Float
    public var isMuted: Bool
    /// 1 means no extra dimming; lower values darken the picture below the hardware minimum.
    public var extraDimming: Float
    public var inputSources: [UInt8]
    public var currentInput: UInt8?
    /// False when DDC/CI is unavailable and brightness falls back to software dimming.
    public var hasHardwareControl: Bool
}

// MARK: - DisplayStateModel

@Observable
@MainActor
public final class DisplayStateModel {
    public static let shared = DisplayStateModel()

    public private(set) var externalDisplays: [ExternalDisplayInfo] = []
    public private(set) var isBuiltinPresent: Bool = false
    public private(set) var isBuiltinTurnedOff: Bool = false {
        didSet {
            guard isBuiltinTurnedOff != oldValue else { return }
            updateScreenOffFallback()
            updateBrightnessObservers()
        }
    }

    // MARK: Settings

    public var autoTurnOffBuiltin: Bool {
        didSet {
            UserDefaults.standard.set(autoTurnOffBuiltin, forKey: "autoTurnOffBuiltin")
            if autoTurnOffBuiltin && hasExternalDisplays && !isBuiltinTurnedOff {
                checkAutoTurnOff()
            }
        }
    }

    public var turnOffKeyboardWithScreen: Bool {
        didSet { UserDefaults.standard.set(turnOffKeyboardWithScreen, forKey: "turnOffKeyboardWithScreen") }
    }

    public var mediaKeysControlPointerDisplay: Bool {
        didSet {
            UserDefaults.standard.set(mediaKeysControlPointerDisplay, forKey: "mediaKeysControlPointerDisplay")
            MediaKeyController.shared.setEnabled(mediaKeysControlPointerDisplay)
        }
    }

    public var switchAudioToMonitor: Bool {
        didSet { UserDefaults.standard.set(switchAudioToMonitor, forKey: "switchAudioToMonitor") }
    }

    public var showMenuBarIcon: Bool {
        didSet {
            UserDefaults.standard.set(showMenuBarIcon, forKey: "showMenuBarIcon")
            StatusBarController.shared.setMenuBarVisible(showMenuBarIcon)
        }
    }

    public var showDockIcon: Bool {
        didSet {
            UserDefaults.standard.set(showDockIcon, forKey: "showDockIcon")
            updateDockVisibility()
        }
    }

    public var showWattageMeter: Bool {
        didSet { UserDefaults.standard.set(showWattageMeter, forKey: "showWattageMeter") }
    }

    public var showBatteryHealth: Bool {
        didSet { UserDefaults.standard.set(showBatteryHealth, forKey: "showBatteryHealth") }
    }

    public var showThermals: Bool {
        didSet { UserDefaults.standard.set(showThermals, forKey: "showThermals") }
    }

    public var showWirelessDisplayCard: Bool {
        didSet { UserDefaults.standard.set(showWirelessDisplayCard, forKey: "showWirelessDisplayCard") }
    }

    public var showAccessoriesCard: Bool {
        didSet { UserDefaults.standard.set(showAccessoriesCard, forKey: "showMXMasterCard") }
    }

    public var menuBarStat: MenuBarStat {
        didSet { UserDefaults.standard.set(menuBarStat.rawValue, forKey: "menuBarStat") }
    }

    /// Re-apply each monitor's last brightness, volume and mute state when it reconnects.
    public var restoreMonitorSettings: Bool {
        didSet { UserDefaults.standard.set(restoreMonitorSettings, forKey: "restoreMonitorSettings") }
    }

    public var showInputSwitching: Bool {
        didSet { UserDefaults.standard.set(showInputSwitching, forKey: "showInputSwitching") }
    }

    public var showResolutionMenu: Bool {
        didSet { UserDefaults.standard.set(showResolutionMenu, forKey: "showResolutionMenu") }
    }

    public var extraDimmingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(extraDimmingEnabled, forKey: "extraDimmingEnabled")
            for display in externalDisplays {
                applyGamma(for: display)
            }
        }
    }

    public var brightnessAutomation: BrightnessAutomation {
        didSet {
            UserDefaults.standard.set(brightnessAutomation.rawValue, forKey: "brightnessAutomation")
            resetBrightnessAutomation()
        }
    }

    /// Minutes after midnight.
    public var scheduleNightStart: Int {
        didSet {
            UserDefaults.standard.set(scheduleNightStart, forKey: "scheduleNightStart")
            resetBrightnessAutomation()
        }
    }

    public var scheduleDayStart: Int {
        didSet {
            UserDefaults.standard.set(scheduleDayStart, forKey: "scheduleDayStart")
            resetBrightnessAutomation()
        }
    }

    public var scheduleDayBrightness: Float {
        didSet {
            UserDefaults.standard.set(scheduleDayBrightness, forKey: "scheduleDayBrightness")
            resetBrightnessAutomation()
        }
    }

    public var scheduleNightBrightness: Float {
        didSet {
            UserDefaults.standard.set(scheduleNightBrightness, forKey: "scheduleNightBrightness")
            resetBrightnessAutomation()
        }
    }

    public var caffeinateWhileExternalConnected: Bool {
        didSet {
            UserDefaults.standard.set(caffeinateWhileExternalConnected, forKey: "caffeinateWhileExternalConnected")
            updateCaffeine()
        }
    }

    public var caffeinateWhileOnPower: Bool {
        didSet {
            UserDefaults.standard.set(caffeinateWhileOnPower, forKey: "caffeinateWhileOnPower")
            updateCaffeine()
        }
    }

    public var caffeinateWhileStreaming: Bool {
        didSet {
            UserDefaults.standard.set(caffeinateWhileStreaming, forKey: "caffeinateWhileStreaming")
            updateCaffeine()
        }
    }

    public func updateDockVisibility() {
        if showDockIcon || SettingsWindowController.shared.isWindowVisible {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: Caffeine State

    /// Manual caffeine, optionally ending at `caffeineEndDate`.
    public var isCaffeinated: Bool = false {
        didSet {
            if !isCaffeinated {
                caffeineEndDate = nil
            }
            scheduleCaffeineExpiry()
            updateCaffeine()
        }
    }
    public private(set) var caffeineEndDate: Date?
    /// Manual caffeine or an automatic rule; this is what actually holds the assertion.
    public private(set) var isCaffeineActive: Bool = false
    public private(set) var isCaffeineAutomatic: Bool = false
    private var caffeineAssertionID: IOPMAssertionID = 0
    private var caffeineExpiryTask: Task<Void, Never>?

    // MARK: Private State

    private var builtinDisplayID: CGDirectDisplayID?
    private var isTransitioning: Bool = false
    private var previousExternalCount: Int = 0
    private var settleTask: Task<Void, Never>?
    private var screenOffFallbackTask: Task<Void, Never>?
    private var reconfigTask: Task<Void, Never>?
    private var pendingAddedExternals = Set<CGDirectDisplayID>()
    // Externals seen while the panel was on; macOS's placeholder display only exists while it's off, so it never lands here.
    private var realExternalIDs = Set<CGDirectDisplayID>()
    private var audioSwitchTask: Task<Void, Never>?
    private var keyboardRestoreTask: Task<Void, Never>?
    private var connectTasks: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var lastMatchedBuiltinBrightness: Float?
    private var lastScheduleIsNight: Bool?
    private var scheduleTask: Task<Void, Never>?
    // Native displays reporting brightness changes, and those polled where macOS offers no notification.
    private var observedBrightnessIDs = Set<CGDirectDisplayID>()
    private var polledBrightnessIDs = Set<CGDirectDisplayID>()
    private var brightnessPollTask: Task<Void, Never>?

    public var hasExternalDisplays: Bool {
        !externalDisplays.isEmpty
    }

    /// True when either a physical external monitor or an active Wireless Extended Display can serve as the active screen.
    public var canTurnOffBuiltin: Bool {
        hasExternalDisplays || WirelessDisplayManager.shared.hasActiveVirtualDisplay
    }

    private init() {
        let defaults = UserDefaults.standard
        self.autoTurnOffBuiltin = defaults.bool(forKey: "autoTurnOffBuiltin")
        self.turnOffKeyboardWithScreen = defaults.bool(forKey: "turnOffKeyboardWithScreen")
        self.mediaKeysControlPointerDisplay = defaults.object(forKey: "mediaKeysControlPointerDisplay") as? Bool ?? true
        self.switchAudioToMonitor = defaults.object(forKey: "switchAudioToMonitor") as? Bool ?? true
        self.showMenuBarIcon = defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true
        self.showDockIcon = defaults.object(forKey: "showDockIcon") as? Bool ?? false
        self.showWattageMeter = defaults.object(forKey: "showWattageMeter") as? Bool ?? true
        self.showBatteryHealth = defaults.object(forKey: "showBatteryHealth") as? Bool ?? true
        self.showThermals = defaults.object(forKey: "showThermals") as? Bool ?? true
        self.showWirelessDisplayCard = defaults.object(forKey: "showWirelessDisplayCard") as? Bool ?? true
        self.showAccessoriesCard = defaults.object(forKey: "showMXMasterCard") as? Bool ?? true
        self.menuBarStat = defaults.string(forKey: "menuBarStat").flatMap(MenuBarStat.init) ?? .none
        self.restoreMonitorSettings = defaults.object(forKey: "restoreMonitorSettings") as? Bool ?? true
        self.showInputSwitching = defaults.object(forKey: "showInputSwitching") as? Bool ?? true
        self.showResolutionMenu = defaults.object(forKey: "showResolutionMenu") as? Bool ?? true
        self.extraDimmingEnabled = defaults.bool(forKey: "extraDimmingEnabled")
        self.brightnessAutomation = defaults.string(forKey: "brightnessAutomation").flatMap(BrightnessAutomation.init) ?? .off
        self.scheduleNightStart = defaults.object(forKey: "scheduleNightStart") as? Int ?? 21 * 60
        self.scheduleDayStart = defaults.object(forKey: "scheduleDayStart") as? Int ?? 7 * 60
        self.scheduleDayBrightness = defaults.object(forKey: "scheduleDayBrightness") as? Float ?? 0.8
        self.scheduleNightBrightness = defaults.object(forKey: "scheduleNightBrightness") as? Float ?? 0.3
        self.caffeinateWhileExternalConnected = defaults.bool(forKey: "caffeinateWhileExternalConnected")
        self.caffeinateWhileOnPower = defaults.bool(forKey: "caffeinateWhileOnPower")
        self.caffeinateWhileStreaming = defaults.object(forKey: "caffeinateWhileStreaming") as? Bool ?? true

        let cachedID = UInt32(defaults.integer(forKey: "cachedBuiltinDisplayID"))
        if cachedID != 0 {
            self.builtinDisplayID = cachedID
            self.isBuiltinPresent = true
        }

        DisplayHardwareManager.shared.onNativeBrightnessChange = { [weak self] displayID, level in
            self?.nativeBrightnessChanged(displayID, to: level)
        }
        setupReconfigurationCallback()
        setupNotificationObservers()
        // Plugging in or unplugging the charger re-evaluates the "keep awake while on power adapter" rule.
        PowerSource.onChange { DisplayStateModel.shared.updateCaffeine() }
        refreshDisplays()
        resetBrightnessAutomation()

        // A previous run may have quit or crashed before its delayed backlight restore ran.
        if !isBuiltinTurnedOff {
            DisplayHardwareManager.shared.restoreKeyboardBacklight()
        }
        updateCaffeine()
    }

    // MARK: - System Event Observers

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
                let model = DisplayStateModel.shared
                model.refreshDisplays()
                model.scheduleSettleChecks()
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let model = DisplayStateModel.shared
                model.refreshDisplays()
                model.scheduleSettleChecks()
                DisplayHardwareManager.shared.reapplyGamma()
                model.resetBrightnessAutomation()
                MXMasterManager.shared.refreshDeviceState()
                MXMasterManager.shared.applyAllSettingsToHardware()
            }
        }

        // The schedule sleeps until the next transition, which moves when the clock or time zone does.
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    let model = DisplayStateModel.shared
                    model.runBrightnessAutomation()
                    model.scheduleNextBrightnessTransition()
                }
            }
        }
    }


    /// macOS can report an unplug late, or not at all, so re-check for a few seconds after any display event.
    private func scheduleSettleChecks() {
        settleTask?.cancel()
        settleTask = Task {
            for delay in [1, 2, 4] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                restoreIfRealExternalsGone()
                refreshDisplays()
            }
        }
    }

    /// A missed unplug while the MacBook screen is off would leave the user with no screen at all,
    /// so that one case keeps a slow check running.
    private func updateScreenOffFallback() {
        guard isBuiltinTurnedOff else {
            screenOffFallbackTask?.cancel()
            screenOffFallbackTask = nil
            return
        }
        guard screenOffFallbackTask == nil else { return }
        screenOffFallbackTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                restoreIfRealExternalsGone()
                refreshDisplays()
            }
        }
    }

    private func handleReconfiguration(display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        guard !flags.contains(.beginConfigurationFlag) else { return }

        if flags.contains(.addFlag)
            && display != builtinDisplayID
            && CGDisplayIsBuiltin(display) == 0
            && !VirtualDisplayManager.isVirtualDisplay(display) {
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
        DDCController.shared.invalidate()
        defer {
            DisplayHardwareManager.shared.reapplyGamma()
            switchAudioToNewMonitors(added)
            scheduleSettleChecks()
        }

        if let bID = builtinDisplayID, !isDisplayActive(bID) {
            restoreIfRealExternalsGone()
        } else if !added.isEmpty && autoTurnOffBuiltin {
            refreshDisplays()
            checkAutoTurnOff()
            return
        }
        refreshDisplays()
    }

    /// Routes sound to a newly connected monitor when it's currently playing through the MacBook speakers.
    /// The monitor's audio device can show up a few seconds after the display, so keep retrying briefly.
    private func switchAudioToNewMonitors(_ added: Set<CGDirectDisplayID>) {
        guard switchAudioToMonitor, !added.isEmpty else { return }
        audioSwitchTask?.cancel()
        audioSwitchTask = Task { @MainActor in
            for _ in 0..<20 {
                let names = externalDisplays.filter { added.contains($0.id) }.map(\.name)
                for name in names {
                    switch DisplayHardwareManager.shared.switchOutputToMonitorIfOnSpeakers(displayName: name) {
                    case .switched, .notOnSpeakers: return
                    case .monitorAudioNotFound: continue
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
            }
        }
    }

    // Unplugging the last external makes macOS add a placeholder display, so counting externals
    // or watching removal events is unreliable. Instead: panel off + every known real external gone → turn on.
    private func restoreIfRealExternalsGone() {
        guard !WirelessDisplayManager.shared.hasActiveVirtualDisplay,
              let panelID = savedPanelID ?? builtinDisplayID,
              !isDisplayActive(panelID),
              !realExternalIDs.isEmpty,
              !realExternalIDs.contains(where: { isDisplayActive($0) }) else { return }

        dlog("All external displays disconnected; turning built-in display back on")
        turnOnBuiltin()
    }

    // MARK: - Refresh Display Hierarchy

    /// Runs after every display event, so it only publishes when something actually changed.
    public func refreshDisplays() {
        guard !isTransitioning else { return }

        let screenMap = getScreenNames()

        if let builtin = DisplayHardwareManager.shared.findBuiltinDisplayID() {
            if builtinDisplayID != builtin {
                builtinDisplayID = builtin
                UserDefaults.standard.set(Int(builtin), forKey: "cachedBuiltinDisplayID")
            }
            if !isBuiltinPresent {
                isBuiltinPresent = true
            }
        }

        // Exclude Aeron Tools' Wireless Virtual Display so it is managed solely by the Wireless Display card.
        let ids = DisplayHardwareManager.shared.getExternalDisplayIDs(builtinID: builtinDisplayID)
            .filter { !VirtualDisplayManager.isVirtualDisplay($0) }
        var detected: [ExternalDisplayInfo] = []
        var connected: [CGDirectDisplayID] = []
        for id in ids {
            let name = screenMap[id] ?? "External Display"
            if var existing = externalDisplays.first(where: { $0.id == id }) {
                existing.name = name
                detected.append(existing)
            } else {
                detected.append(makeDisplayInfo(id: id, name: name, siblings: ids))
                connected.append(id)
            }
        }

        let removed = externalDisplays.map(\.id).filter { !ids.contains($0) }
        for id in removed {
            connectTasks.removeValue(forKey: id)?.cancel()
            DisplayHardwareManager.shared.forgetGamma(for: id)
        }
        if !removed.isEmpty || !connected.isEmpty {
            DDCController.shared.invalidate()
        }

        if detected != externalDisplays {
            externalDisplays = detected
        }
        for id in connected {
            monitorConnected(id)
        }

        if let bID = builtinDisplayID {
            let turnedOff = !isDisplayActive(bID)
            if turnedOff != isBuiltinTurnedOff {
                isBuiltinTurnedOff = turnedOff
            }
        }
        // Also seed when empty: the panel may already be off at launch (e.g. left off by a killed previous run).
        if !isBuiltinTurnedOff || realExternalIDs.isEmpty {
            realExternalIDs = Set(detected.map(\.id))
        }

        // Covers launch with a monitor already attached, where no "display added" event arrives.
        let newPhysicalExternalCount = detected.count
        if autoTurnOffBuiltin && previousExternalCount == 0 && newPhysicalExternalCount > 0 && !isBuiltinTurnedOff {
            checkAutoTurnOff()
        }
        previousExternalCount = newPhysicalExternalCount

        updateBrightnessObservers()
        updateCaffeine()
    }

    private func getScreenNames() -> [CGDirectDisplayID: String] {
        var dict: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let num = screen.displayID {
                dict[num] = screen.localizedName
            }
        }
        return dict
    }

    /// Identical monitors without serial numbers share an identity, so later twins get a numbered key.
    private func settingsKey(for id: CGDirectDisplayID, siblings: [CGDirectDisplayID]) -> String {
        let identity = MonitorIdentity(displayID: id)
        let twins = siblings.filter { MonitorIdentity(displayID: $0) == identity }.sorted()
        let index = twins.firstIndex(of: id) ?? 0
        return index == 0 ? identity.key : "\(identity.key)#\(index + 1)"
    }

    private func makeDisplayInfo(id: CGDirectDisplayID, name: String, siblings: [CGDirectDisplayID]) -> ExternalDisplayInfo {
        let key = settingsKey(for: id, siblings: siblings)
        let saved = MonitorSettingsStore.shared.settings(for: key)
        let defaults = UserDefaults.standard
        // Older builds stored volume and mute by display name.
        let legacyVolume = defaults.object(forKey: "monitorVolume_\(name)") as? Float
        let legacyMuted = defaults.object(forKey: "monitorMuted_\(name)") as? Bool

        return ExternalDisplayInfo(
            id: id,
            settingsKey: key,
            name: name,
            brightness: DisplayHardwareManager.shared.nativeBrightness(for: id) ?? saved?.brightness ?? 0.75,
            volume: saved?.volume ?? legacyVolume ?? 0.5,
            isMuted: saved?.isMuted ?? legacyMuted ?? false,
            extraDimming: saved?.extraDimming ?? 1,
            inputSources: saved?.inputSources ?? [],
            currentInput: nil,
            hasHardwareControl: true
        )
    }

    /// Brings a newly seen monitor in sync: either re-applies its saved settings or reads its real values over DDC.
    private func monitorConnected(_ id: CGDirectDisplayID) {
        connectTasks[id]?.cancel()
        connectTasks[id] = Task { @MainActor in
            // A replacement task may already own the slot if this one was cancelled.
            defer {
                if !Task.isCancelled {
                    connectTasks[id] = nil
                }
            }
            guard let display = externalDisplays.first(where: { $0.id == id }) else { return }
            let saved = MonitorSettingsStore.shared.settings(for: display.settingsKey)
            let isNative = DisplayHardwareManager.shared.supportsNativeBrightness(id)
            let hasDDC = await DDCController.shared.hasService(for: id)
            guard !Task.isCancelled else { return }

            mutateDisplay(id) { $0.hasHardwareControl = isNative || hasDDC }
            applyGamma(for: id)

            // Brightness: automation wins, then saved settings, then whatever the monitor reports.
            if let level = automationBrightness() {
                updateBrightness(for: id, level: level)
            } else if restoreMonitorSettings, let brightness = saved?.brightness, !isNative {
                updateBrightness(for: id, level: brightness)
            } else if hasDDC, !isNative, let reading = await DDCController.shared.read(DDCVCP.brightness, from: id), reading.max > 0 {
                guard !Task.isCancelled else { return }
                mutateDisplay(id) { $0.brightness = Float(reading.current) / Float(reading.max) }
            }

            guard hasDDC, !Task.isCancelled else { return }

            if restoreMonitorSettings, let volume = saved?.volume {
                updateVolume(for: id, level: volume)
                if saved?.isMuted == true {
                    setMonitorMuted(true, for: id)
                }
            } else if let reading = await DDCController.shared.read(DDCVCP.volume, from: id), reading.max > 0 {
                guard !Task.isCancelled else { return }
                mutateDisplay(id) { $0.volume = Float(reading.current) / Float(reading.max) }
            }

            await refreshInputSource(for: id)
            if saved?.inputSources == nil {
                await loadInputSources(for: id)
            }
        }
    }

    private func mutateDisplay(_ id: CGDirectDisplayID, _ change: (inout ExternalDisplayInfo) -> Void) {
        guard let index = externalDisplays.firstIndex(where: { $0.id == id }) else { return }
        var display = externalDisplays[index]
        change(&display)
        if display != externalDisplays[index] {
            externalDisplays[index] = display
        }
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
        } else if canTurnOffBuiltin, let bID = builtinDisplayID {
            turnOffBuiltinDisplay(displayID: bID)
        }
    }

    private func turnOffBuiltinDisplay(displayID: CGDirectDisplayID) {
        guard canTurnOffBuiltin, !isTransitioning else { return }
        isTransitioning = true

        if DisplayHardwareManager.shared.turnOffBuiltinDisplay(displayID: displayID) {
            isBuiltinTurnedOff = true
            keyboardRestoreTask?.cancel()
            if turnOffKeyboardWithScreen {
                DisplayHardwareManager.shared.turnOffKeyboardBacklight()
            }
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
        // Restore regardless of the current setting so the backlight is never left off.
        restoreKeyboardBacklight()
        isTransitioning = false
        refreshDisplays()
    }

    /// After an unplug, macOS re-applies its own (dark) keyboard backlight state once the display
    /// reconfiguration settles, overriding an immediate restore. The first attempt is synchronous so quitting
    /// still restores it; the saved state is only cleared after the last retry (or at next launch).
    private func restoreKeyboardBacklight() {
        keyboardRestoreTask?.cancel()
        DisplayHardwareManager.shared.restoreKeyboardBacklight(clearSaved: false)
        keyboardRestoreTask = Task { @MainActor in
            let delays: [Int] = [500, 1500, 3000]
            for (index, delay) in delays.enumerated() {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled else { return }
                DisplayHardwareManager.shared.restoreKeyboardBacklight(clearSaved: index == delays.count - 1)
            }
        }
    }

    // MARK: - Caffeine

    public func toggleCaffeine() {
        if isCaffeinated {
            isCaffeinated = false
        } else {
            startCaffeine(for: nil)
        }
    }

    /// Pass nil to stay awake until turned off.
    public func startCaffeine(for duration: TimeInterval?) {
        // Set the end date first: assigning isCaffeinated re-evaluates expiry against it.
        caffeineEndDate = duration.map { Date().addingTimeInterval($0) }
        isCaffeinated = true
    }

    private func scheduleCaffeineExpiry() {
        caffeineExpiryTask?.cancel()
        caffeineExpiryTask = nil
        guard isCaffeinated, let end = caffeineEndDate else { return }
        // Task.sleep runs on the continuous clock, so time spent asleep counts toward the timer.
        caffeineExpiryTask = Task {
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            updateCaffeine()
        }
    }

    /// Re-evaluates manual expiry and the automatic rules, then holds or releases the assertion.
    /// Called whenever an input changes: the timer, displays, power source, or wireless streaming.
    func updateCaffeine() {
        if isCaffeinated, let end = caffeineEndDate, end <= Date() {
            isCaffeinated = false // didSet re-enters with the timer cleared
            return
        }
        let automatic = (caffeinateWhileExternalConnected && hasExternalDisplays)
            || (caffeinateWhileOnPower && PowerSource.isOnACPower)
            || (caffeinateWhileStreaming && WirelessDisplayManager.shared.isStreaming)
        if automatic != isCaffeineAutomatic {
            isCaffeineAutomatic = automatic
        }
        let active = isCaffeinated || automatic
        guard active != isCaffeineActive else { return }
        isCaffeineActive = active
        updateCaffeineAssertion()
    }

    private func updateCaffeineAssertion() {
        if isCaffeineActive {
            guard caffeineAssertionID == 0 else { return }
            // Preventing display sleep also prevents idle system sleep.
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Aeron Tools Caffeine" as CFString,
                &caffeineAssertionID
            )
            if result != kIOReturnSuccess {
                dlog("Failed to create caffeine assertion: \(result)")
                caffeineAssertionID = 0
            }
        } else if caffeineAssertionID != 0 {
            IOPMAssertionRelease(caffeineAssertionID)
            caffeineAssertionID = 0
        }
    }

    // MARK: - Brightness Automation

    private func resetBrightnessAutomation() {
        lastMatchedBuiltinBrightness = nil
        lastScheduleIsNight = nil
        // Also runs on wake; re-register in case macOS dropped the notifications while asleep.
        for id in observedBrightnessIDs {
            DisplayHardwareManager.shared.stopObservingBrightness(of: id)
        }
        observedBrightnessIDs.removeAll()
        updateBrightnessObservers()
        runBrightnessAutomation()
        scheduleNextBrightnessTransition()
    }

    /// Sleeps until the next day or night start, so the schedule needs no polling.
    private func scheduleNextBrightnessTransition() {
        scheduleTask?.cancel()
        scheduleTask = nil
        guard brightnessAutomation == .schedule else { return }
        let now = Date()
        let next = [scheduleNightStart, scheduleDayStart].compactMap { minutes in
            Calendar.current.nextDate(after: now, matching: DateComponents(hour: minutes / 60, minute: minutes % 60),
                                      matchingPolicy: .nextTime)
        }.min()
        guard let next else { return }
        scheduleTask = Task {
            // A second past the boundary so the minute-of-day check lands on the new side of it.
            try? await Task.sleep(for: .seconds(next.timeIntervalSince(now) + 1))
            guard !Task.isCancelled else { return }
            runBrightnessAutomation()
            scheduleNextBrightnessTransition()
        }
    }

    /// Native displays whose brightness can change outside the app: Apple external displays (to keep their
    /// sliders accurate) and the MacBook screen while external displays follow it.
    private func updateBrightnessObservers() {
        let hardware = DisplayHardwareManager.shared
        var wanted = Set(externalDisplays.map(\.id).filter { hardware.supportsNativeBrightness($0) })
        if brightnessAutomation == .matchMacBook, hasExternalDisplays, let bID = builtinDisplayID, !isBuiltinTurnedOff {
            wanted.insert(bID)
        }

        for id in observedBrightnessIDs.subtracting(wanted) {
            hardware.stopObservingBrightness(of: id)
        }
        observedBrightnessIDs.formIntersection(wanted)
        for id in wanted.subtracting(observedBrightnessIDs) where hardware.startObservingBrightness(of: id) {
            observedBrightnessIDs.insert(id)
        }

        polledBrightnessIDs = wanted.subtracting(observedBrightnessIDs)
        if polledBrightnessIDs.isEmpty {
            brightnessPollTask?.cancel()
            brightnessPollTask = nil
        } else if brightnessPollTask == nil {
            brightnessPollTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    for id in polledBrightnessIDs {
                        if let level = hardware.nativeBrightness(for: id) {
                            nativeBrightnessChanged(id, to: level)
                        }
                    }
                }
            }
        }
    }

    private func nativeBrightnessChanged(_ displayID: CGDirectDisplayID, to level: Float) {
        if displayID == builtinDisplayID {
            runBrightnessAutomation()
        } else {
            mutateDisplay(displayID) { display in
                if abs(display.brightness - level) > 0.005 {
                    display.brightness = level
                }
            }
        }
    }

    /// The level automation wants right now, or nil when it's off or has nothing to follow.
    private func automationBrightness() -> Float? {
        switch brightnessAutomation {
        case .off:
            return nil
        case .matchMacBook:
            guard let bID = builtinDisplayID, !isBuiltinTurnedOff else { return nil }
            return DisplayHardwareManager.shared.nativeBrightness(for: bID)
        case .schedule:
            return scheduleIsNight() ? scheduleNightBrightness : scheduleDayBrightness
        }
    }

    private func scheduleIsNight() -> Bool {
        BrightnessSchedule.isNight(minuteOfDay: BrightnessSchedule.minuteOfDay(Date()),
                                   nightStart: scheduleNightStart, dayStart: scheduleDayStart)
    }

    /// Following the MacBook applies every change; the schedule only acts at day/night transitions so manual
    /// adjustments in between stick.
    private func runBrightnessAutomation() {
        guard hasExternalDisplays else { return }
        switch brightnessAutomation {
        case .off:
            return
        case .matchMacBook:
            guard let level = automationBrightness() else { return }
            if let last = lastMatchedBuiltinBrightness, abs(last - level) < 0.01 { return }
            lastMatchedBuiltinBrightness = level
            applyBrightnessToAll(level)
        case .schedule:
            let isNight = scheduleIsNight()
            guard isNight != lastScheduleIsNight else { return }
            lastScheduleIsNight = isNight
            applyBrightnessToAll(isNight ? scheduleNightBrightness : scheduleDayBrightness)
        }
    }

    private func applyBrightnessToAll(_ level: Float) {
        for display in externalDisplays {
            updateBrightness(for: display.id, level: level)
        }
    }

    // MARK: - Media Keys

    /// Brightness keys act on the external display under the pointer; volume keys act on the monitor that is
    /// the current sound output. The HUD is shown on the display under the pointer.
    /// Returns false when the key should fall through to macOS (built-in display, or sound not going to a monitor).
    public func handleMediaKey(_ key: MediaKey, on pointerDisplayID: CGDirectDisplayID) -> Bool {
        let step: Float = 1.0 / 16.0

        switch key {
        case .brightnessUp, .brightnessDown:
            guard let display = externalDisplays.first(where: { $0.id == pointerDisplayID }) else { return false }
            let isUp = key == .brightnessUp
            // With extra dimming on, keys continue below 0% hardware brightness and undo that dimming first.
            if extraDimmingEnabled && (isUp ? display.extraDimming < 1 : display.brightness <= 0) {
                let dimming = max(Self.minimumExtraDimming, min(1, display.extraDimming + (isUp ? step : -step)))
                updateExtraDimming(for: display.id, level: dimming)
                OSDController.shared.show(.brightness, level: 0, title: "\(display.name) – Extra Dimming", on: pointerDisplayID)
                return true
            }
            let level = max(0, min(1, display.brightness + (isUp ? step : -step)))
            updateBrightness(for: display.id, level: level)
            OSDController.shared.show(.brightness, level: level, title: display.name, on: pointerDisplayID)
            return true

        case .volumeUp, .volumeDown, .mute:
            guard let display = externalDisplays.first(where: {
                DisplayHardwareManager.shared.isDefaultOutput(monitorName: $0.name)
            }) else {
                return false
            }
            if key == .mute {
                toggleMonitorMuted(for: display.id)
            } else {
                if display.isMuted {
                    toggleMonitorMuted(for: display.id)
                }
                let delta = key == .volumeUp ? step : -step
                updateVolume(for: display.id, level: max(0, min(1, display.volume + delta)))
            }
            if let updated = externalDisplays.first(where: { $0.id == display.id }) {
                OSDController.shared.show(updated.isMuted ? .muted : .volume, level: updated.volume,
                                          title: updated.name, on: pointerDisplayID)
            }
            return true
        }
    }

    // MARK: - External Controls

    public static let minimumExtraDimming: Float = 0.1

    public func updateBrightness(for displayID: CGDirectDisplayID, level: Float) {
        guard let display = externalDisplays.first(where: { $0.id == displayID }) else { return }
        let clamped = max(0, min(1, level))
        mutateDisplay(displayID) { $0.brightness = clamped }
        MonitorSettingsStore.shared.update(display.settingsKey) { $0.brightness = clamped }
        if display.hasHardwareControl {
            DisplayHardwareManager.shared.setExternalBrightness(for: displayID, level: clamped)
        } else {
            applyGamma(for: displayID)
        }
    }

    public func updateExtraDimming(for displayID: CGDirectDisplayID, level: Float) {
        guard let display = externalDisplays.first(where: { $0.id == displayID }) else { return }
        let clamped = max(Self.minimumExtraDimming, min(1, level))
        mutateDisplay(displayID) { $0.extraDimming = clamped }
        MonitorSettingsStore.shared.update(display.settingsKey) { $0.extraDimming = clamped }
        applyGamma(for: displayID)
    }

    private func applyGamma(for displayID: CGDirectDisplayID) {
        guard let display = externalDisplays.first(where: { $0.id == displayID }) else { return }
        applyGamma(for: display)
    }

    /// Software dimming combines the extra-dimming level with brightness for monitors without hardware control.
    private func applyGamma(for display: ExternalDisplayInfo) {
        var factor: Float = extraDimmingEnabled ? display.extraDimming : 1
        if !display.hasHardwareControl {
            // Keep a floor so 0% brightness never turns the screen fully black.
            factor *= 0.15 + 0.85 * display.brightness
        }
        DisplayHardwareManager.shared.setGammaFactor(factor, for: display.id)
    }

    public func updateVolume(for displayID: CGDirectDisplayID, level: Float) {
        guard let display = externalDisplays.first(where: { $0.id == displayID }) else { return }
        let clamped = max(0, min(1, level))
        mutateDisplay(displayID) { $0.volume = clamped }
        MonitorSettingsStore.shared.update(display.settingsKey) { $0.volume = clamped }
        DisplayHardwareManager.shared.setMonitorVolume(level: clamped, displayID: displayID, displayName: display.name)
    }

    public func toggleMonitorMuted(for displayID: CGDirectDisplayID) {
        guard let display = externalDisplays.first(where: { $0.id == displayID }) else { return }
        setMonitorMuted(!display.isMuted, for: displayID)
    }

    private func setMonitorMuted(_ isMuted: Bool, for displayID: CGDirectDisplayID) {
        guard let display = externalDisplays.first(where: { $0.id == displayID }) else { return }
        mutateDisplay(displayID) { $0.isMuted = isMuted }
        MonitorSettingsStore.shared.update(display.settingsKey) { $0.isMuted = isMuted }
        DisplayHardwareManager.shared.setMonitorMuted(isMuted, displayID: displayID, displayName: display.name)
    }

    // MARK: - Input Sources

    /// Inputs to offer: what the monitor reported, else the common ones.
    public func inputChoices(for display: ExternalDisplayInfo) -> [UInt8] {
        var choices = display.inputSources.isEmpty ? InputSource.commonCodes : display.inputSources
        if let current = display.currentInput, !choices.contains(current) {
            choices.insert(current, at: 0)
        }
        return choices
    }

    /// Switching away from this Mac makes the monitor disconnect, which the usual unplug handling covers.
    public func selectInput(_ code: UInt8, for displayID: CGDirectDisplayID) {
        mutateDisplay(displayID) { $0.currentInput = code }
        DisplayHardwareManager.shared.setInputSource(code, for: displayID)
    }

    public func refreshInputSource(for displayID: CGDirectDisplayID) async {
        guard let reading = await DDCController.shared.read(DDCVCP.inputSource, from: displayID) else { return }
        // Some monitors report the input in the high byte.
        let code = UInt8(truncatingIfNeeded: reading.current & 0xFF == 0 ? reading.current >> 8 : reading.current)
        mutateDisplay(displayID) { $0.currentInput = code }
    }

    /// Reads the capabilities string once per monitor and caches the input list.
    public func loadInputSources(for displayID: CGDirectDisplayID) async {
        guard let display = externalDisplays.first(where: { $0.id == displayID }),
              let capabilities = await DDCController.shared.capabilities(for: displayID) else { return }
        let sources = DDCProtocol.inputSources(fromCapabilities: capabilities)
        MonitorSettingsStore.shared.update(display.settingsKey) { $0.inputSources = sources }
        mutateDisplay(displayID) { $0.inputSources = sources }
    }

    // MARK: - Display Modes

    public func displayModes(for displayID: CGDirectDisplayID) -> (options: [DisplayModeOption], currentID: Int32?) {
        DisplayHardwareManager.shared.displayModes(for: displayID)
    }

    public func setDisplayMode(_ modeID: Int32, for displayID: CGDirectDisplayID) {
        DisplayHardwareManager.shared.setDisplayMode(modeID, for: displayID)
    }

    /// The built-in panel, when it's on, for the resolution picker.
    public var activeBuiltinDisplayID: CGDirectDisplayID? {
        guard let bID = builtinDisplayID, !isBuiltinTurnedOff else { return nil }
        return bID
    }

    // MARK: - Shutdown

    /// Leaves the Mac as the app found it.
    public func prepareForTermination() {
        WirelessDisplayManager.shared.stopSessionForTermination()
        turnOnBuiltin()
        DisplayHardwareManager.shared.resetAllGamma()
        if caffeineAssertionID != 0 {
            IOPMAssertionRelease(caffeineAssertionID)
            caffeineAssertionID = 0
        }
    }
}
