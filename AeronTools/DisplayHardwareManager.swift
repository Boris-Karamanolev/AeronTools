import Foundation
import CoreGraphics
import IOKit
import CoreAudio
import AudioToolbox
import Darwin
import os

private let displayLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AeronTools", category: "Display")

func dlog(_ message: String) {
    displayLogger.notice("\(message, privacy: .public)")
}

// CGDisplayIsActive returns -1 for a disabled panel once macOS's placeholder display takes over, so only 1 means active.
func isDisplayActive(_ displayID: CGDirectDisplayID) -> Bool {
    CGDisplayIsActive(displayID) == 1
}

// MARK: - DisplayHardwareManager

public final class DisplayHardwareManager: @unchecked Sendable {
    public static let shared = DisplayHardwareManager()
    public static let disabledPanelIDKey = "disabledBuiltinPanelID"

    private let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    
    // Function signatures
    private typealias SLSConfigureDisplayEnabledFunc = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private typealias SLSGetDisplayListFunc = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>, UnsafeMutablePointer<UInt32>) -> CGError
    private typealias DisplayServicesSetBrightnessFunc = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias DisplayServicesGetBrightnessFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias DisplayServicesCanChangeBrightnessFunc = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias DisplayServicesRegisterBrightnessFunc = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?, CFNotificationCallback) -> Int32
    private typealias DisplayServicesUnregisterBrightnessFunc = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?) -> Int32

    private var slsConfigureDisplayEnabled: SLSConfigureDisplayEnabledFunc?
    private var slsGetDisplayList: SLSGetDisplayListFunc?
    private var dsSetBrightness: DisplayServicesSetBrightnessFunc?
    private var dsGetBrightness: DisplayServicesGetBrightnessFunc?
    private var dsCanChangeBrightness: DisplayServicesCanChangeBrightnessFunc?
    private var dsRegisterBrightness: DisplayServicesRegisterBrightnessFunc?
    private var dsUnregisterBrightness: DisplayServicesUnregisterBrightnessFunc?

    private init() {
        loadDynamicSymbols()
    }

    private func loadDynamicSymbols() {
        // 1. SkyLight / CoreGraphics for display connect / disconnect & list
        let skyLightHandle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        if let sym = dlsym(skyLightHandle ?? rtldDefault, "SLSConfigureDisplayEnabled") ??
                     dlsym(rtldDefault, "CGSConfigureDisplayEnabled") {
            slsConfigureDisplayEnabled = unsafeBitCast(sym, to: SLSConfigureDisplayEnabledFunc.self)
        }
        if let symList = dlsym(skyLightHandle ?? rtldDefault, "SLSGetDisplayList") {
            slsGetDisplayList = unsafeBitCast(symList, to: SLSGetDisplayListFunc.self)
        }

        // 2. DisplayServices for native Apple displays
        let dsHandle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        if let setBrightSym = dlsym(dsHandle ?? rtldDefault, "DisplayServicesSetBrightness") {
            dsSetBrightness = unsafeBitCast(setBrightSym, to: DisplayServicesSetBrightnessFunc.self)
        }
        if let getBrightSym = dlsym(dsHandle ?? rtldDefault, "DisplayServicesGetBrightness") {
            dsGetBrightness = unsafeBitCast(getBrightSym, to: DisplayServicesGetBrightnessFunc.self)
        }

        if let canChangeSym = dlsym(dsHandle ?? rtldDefault, "DisplayServicesCanChangeBrightness") {
            dsCanChangeBrightness = unsafeBitCast(canChangeSym, to: DisplayServicesCanChangeBrightnessFunc.self)
        }
        if let registerSym = dlsym(dsHandle ?? rtldDefault, "DisplayServicesRegisterForBrightnessChangeNotifications"),
           let unregisterSym = dlsym(dsHandle ?? rtldDefault, "DisplayServicesUnregisterForBrightnessChangeNotifications") {
            dsRegisterBrightness = unsafeBitCast(registerSym, to: DisplayServicesRegisterBrightnessFunc.self)
            dsUnregisterBrightness = unsafeBitCast(unregisterSym, to: DisplayServicesUnregisterBrightnessFunc.self)
        }

        // These are private APIs; a future macOS may drop them.
        if slsConfigureDisplayEnabled == nil || dsSetBrightness == nil {
            dlog("Missing private display APIs: configure=\(slsConfigureDisplayEnabled != nil) brightness=\(dsSetBrightness != nil)")
        }
    }

    // MARK: - Query Displays (Clean Filtering: Only Physically Online Displays)

    public func getOnlineDisplayIDs() -> [CGDirectDisplayID] {
        var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(32, &onlineDisplays, &displayCount)
        let valid = Array(onlineDisplays.prefix(Int(displayCount)))
        return valid.filter { CGDisplayIsOnline($0) != 0 }
    }

    // A disabled built-in panel can stay "online" while CGDisplayIsBuiltin reports 0, so exclude it by ID and require externals to be active.
    public func getExternalDisplayIDs(builtinID: CGDirectDisplayID?) -> [CGDirectDisplayID] {
        getOnlineDisplayIDs().filter { id in
            id != builtinID && CGDisplayIsBuiltin(id) == 0 && isDisplayActive(id)
        }
    }

    public func findBuiltinDisplayID() -> CGDirectDisplayID? {
        // 1. Check online displays first
        let online = getOnlineDisplayIDs()
        for id in online {
            if CGDisplayIsBuiltin(id) != 0 {
                return id
            }
        }

        // 2. If disabled/detached, locate via SLSGetDisplayList
        if let listFunc = slsGetDisplayList {
            var list = [CGDirectDisplayID](repeating: 0, count: 32)
            var count: UInt32 = 0
            if listFunc(32, &list, &count) == .success {
                let all = Array(list.prefix(Int(count)))
                for id in all {
                    if CGDisplayIsBuiltin(id) != 0 {
                        return id
                    }
                }
            }
        }

        return nil
    }

    // MARK: - MacBook Display Power Down & Restore

    @discardableResult
    public func turnOffBuiltinDisplay(displayID: CGDirectDisplayID) -> Bool {
        // Safety check: Never disable built-in screen if 0 external displays are online
        guard !getExternalDisplayIDs(builtinID: displayID).isEmpty else {
            dlog("Not turning off built-in display: no external display online")
            return false
        }

        let current = builtinBrightness(for: displayID)
        if current > 0.05 {
            UserDefaults.standard.set(current, forKey: "savedBuiltinBrightness")
        }

        // Disabling powers the panel down; zeroing the backlight too left it dark after re-enable.
        let disabled = setDisplayEnabled(displayID: displayID, enabled: false)
        if disabled {
            // Built-in detection is unreliable while the panel is off, so remember its ID now.
            UserDefaults.standard.set(Int(displayID), forKey: Self.disabledPanelIDKey)
        }
        return disabled
    }

    @discardableResult
    public func turnOnBuiltinDisplay(displayID: CGDirectDisplayID) -> Bool {
        // 1. Re-enable in WindowServer
        var enabledSuccess = true
        if !isDisplayActive(displayID) {
            enabledSuccess = setDisplayEnabled(displayID: displayID, enabled: true)
            usleep(50_000)
        }

        // 2. Restore physical backlight to exactly what was previously set
        let saved = UserDefaults.standard.float(forKey: "savedBuiltinBrightness")
        let restoreLevel = saved > 0.05 ? saved : 0.75
        setBuiltinBrightness(for: displayID, level: restoreLevel)

        return enabledSuccess
    }

    @discardableResult
    public func setDisplayEnabled(displayID: CGDirectDisplayID, enabled: Bool) -> Bool {
        guard let configureFunc = slsConfigureDisplayEnabled else {
            dlog("SLSConfigureDisplayEnabled not found")
            return false
        }

        // If already in target state, avoid redundant configuration transaction
        if enabled && isDisplayActive(displayID) {
            return true
        }

        var configRef: CGDisplayConfigRef?
        let beginStatus = CGBeginDisplayConfiguration(&configRef)
        guard beginStatus == .success, let config = configRef else {
            dlog("CGBeginDisplayConfiguration failed: \(beginStatus)")
            return false
        }

        let configureStatus = configureFunc(config, displayID, enabled)
        guard configureStatus == .success else {
            dlog("SLSConfigureDisplayEnabled(\(displayID), \(enabled)) failed: \(configureStatus)")
            CGCancelDisplayConfiguration(config)
            return false
        }

        // .forSession so a stuck-disabled panel recovers on logout/reboot.
        let completeStatus = CGCompleteDisplayConfiguration(config, .forSession)
        if completeStatus != .success {
            dlog("CGCompleteDisplayConfiguration failed: \(completeStatus)")
            CGCancelDisplayConfiguration(config)
            return false
        }

        dlog("Display \(displayID) \(enabled ? "enabled" : "disabled")")
        return true
    }

    // MARK: - Brightness

    /// Built-in panel brightness, falling back to the last level the app saw.
    public func builtinBrightness(for displayID: CGDirectDisplayID) -> Float {
        if let value = nativeBrightness(for: displayID), value > 0 {
            return value
        }
        let saved = UserDefaults.standard.float(forKey: "savedBuiltinBrightness")
        return saved > 0.05 ? saved : 0.75
    }

    /// DisplayServices only drives Apple panels: the built-in screen, Studio Display and Pro Display XDR.
    public func supportsNativeBrightness(_ displayID: CGDirectDisplayID) -> Bool {
        if CGDisplayIsBuiltin(displayID) != 0 {
            return dsGetBrightness != nil
        }
        return dsCanChangeBrightness?(displayID) == true
    }

    public func nativeBrightness(for displayID: CGDirectDisplayID) -> Float? {
        guard supportsNativeBrightness(displayID), let getBrightnessFunc = dsGetBrightness else { return nil }
        var value: Float = 0
        return getBrightnessFunc(displayID, &value) == 0 ? value : nil
    }

    /// Called on the main actor when macOS changes a native display's brightness: brightness keys,
    /// auto-brightness, System Settings, or this app.
    public var onNativeBrightnessChange: ((CGDirectDisplayID, Float) -> Void)?

    /// Starts brightness-change notifications for a native display. Returns false when unavailable,
    /// so the caller can fall back to polling `nativeBrightness(for:)`.
    public func startObservingBrightness(of displayID: CGDirectDisplayID) -> Bool {
        guard supportsNativeBrightness(displayID), let register = dsRegisterBrightness else { return false }
        return register(displayID, Self.observerToken(for: displayID), nativeBrightnessCallback) == 0
    }

    public func stopObservingBrightness(of displayID: CGDirectDisplayID) {
        _ = dsUnregisterBrightness?(displayID, Self.observerToken(for: displayID))
    }

    /// The display ID doubles as the observer token, so the callback knows which display changed.
    fileprivate static func observerToken(for displayID: CGDirectDisplayID) -> UnsafeRawPointer? {
        UnsafeRawPointer(bitPattern: UInt(displayID))
    }

    public func setBuiltinBrightness(for displayID: CGDirectDisplayID, level: Float) {
        let clamped = max(0.0, min(1.0, level))
        if clamped > 0.05 {
            UserDefaults.standard.set(clamped, forKey: "savedBuiltinBrightness")
        }
        _ = dsSetBrightness?(displayID, clamped)
    }

    /// Hardware brightness for an external monitor: DisplayServices for Apple displays, DDC/CI for the rest.
    public func setExternalBrightness(for displayID: CGDirectDisplayID, level: Float) {
        let clamped = max(0.0, min(1.0, level))
        if supportsNativeBrightness(displayID), let setBrightnessFunc = dsSetBrightness, setBrightnessFunc(displayID, clamped) == 0 {
            return
        }
        DDCController.shared.write(DDCVCP.brightness, value: UInt16((clamped * 100).rounded()), to: displayID)
    }

    // MARK: - Software Dimming (Gamma)

    private var gammaFactors: [CGDirectDisplayID: Float] = [:]

    /// Scales a display's output through its gamma table; 1 removes the effect. Used to dim below the hardware
    /// minimum and as the brightness control for monitors without DDC/CI.
    public func setGammaFactor(_ factor: Float, for displayID: CGDirectDisplayID) {
        let clamped = max(0.05, min(1.0, factor))
        if clamped >= 0.999 {
            guard gammaFactors.removeValue(forKey: displayID) != nil else { return }
            // There's no per-display reset, so restore every display and re-apply the others.
            CGDisplayRestoreColorSyncSettings()
            reapplyGamma()
        } else {
            gammaFactors[displayID] = clamped
            applyGamma(clamped, to: displayID)
        }
    }

    /// macOS resets gamma tables on display reconfiguration and wake.
    public func reapplyGamma() {
        for (displayID, factor) in gammaFactors {
            applyGamma(factor, to: displayID)
        }
    }

    public func forgetGamma(for displayID: CGDirectDisplayID) {
        gammaFactors.removeValue(forKey: displayID)
    }

    /// Never leave a screen dimmed after the app quits.
    public func resetAllGamma() {
        guard !gammaFactors.isEmpty else { return }
        gammaFactors.removeAll()
        CGDisplayRestoreColorSyncSettings()
    }

    private func applyGamma(_ factor: Float, to displayID: CGDirectDisplayID) {
        var red: [CGGammaValue] = [0, CGGammaValue(factor)]
        var green = red
        var blue = red
        CGSetDisplayTransferByTable(displayID, 2, &red, &green, &blue)
    }

    // MARK: - Monitor Audio (DDC/CI, plus the matching CoreAudio device if the monitor exposes one)

    public func setMonitorVolume(level: Float, displayID: CGDirectDisplayID, displayName: String) {
        let clamped = max(0.0, min(1.0, level))
        DDCController.shared.write(DDCVCP.volume, value: UInt16((clamped * 100).rounded()), to: displayID)
        setCoreAudioDeviceVolumeIfMatched(displayName: displayName, volume: clamped)
    }

    public func setMonitorMuted(_ isMuted: Bool, displayID: CGDirectDisplayID, displayName: String) {
        // MCCS audio mute: 1 = muted, 2 = unmuted.
        DDCController.shared.write(DDCVCP.audioMute, value: isMuted ? 1 : 2, to: displayID)
        setCoreAudioDeviceMuteIfMatched(displayName: displayName, isMuted: isMuted)
    }

    public func setInputSource(_ code: UInt8, for displayID: CGDirectDisplayID) {
        DDCController.shared.write(DDCVCP.inputSource, value: UInt16(code), to: displayID)
    }

    // MARK: - Targeted CoreAudio Helper (Only Matches Monitor Name, NEVER Touches Headphones)

    /// The monitor's CoreAudio output device, which macOS names after the display.
    private func findAudioDeviceForMonitor(displayName: String) -> AudioObjectID? {
        let candidates = allAudioDeviceIDs().filter(hasOutputStreams).compactMap { id -> AudioDeviceCandidate? in
            guard let name = audioDeviceName(id) else { return nil }
            return AudioDeviceCandidate(id: id, name: name, isDisplayTransport: isDisplayTransport(id))
        }
        return Self.bestAudioMatch(for: displayName, among: candidates)
    }

    struct AudioDeviceCandidate {
        let id: AudioObjectID
        let name: String
        let isDisplayTransport: Bool
    }

    /// Exact name first, then a device whose name contains the display's. DisplayPort/HDMI devices win ties so a
    /// similarly named USB or Bluetooth device is never picked.
    nonisolated static func bestAudioMatch(for displayName: String, among candidates: [AudioDeviceCandidate]) -> AudioObjectID? {
        func normalized(_ string: String) -> String {
            string.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let target = normalized(displayName)
        guard target.count >= 2 else { return nil }
        func pick(_ matches: (String) -> Bool) -> AudioObjectID? {
            let found = candidates.filter { matches(normalized($0.name)) }
            return (found.first(where: \.isDisplayTransport) ?? found.first)?.id
        }
        return pick { $0 == target } ?? pick { $0.contains(target) }
    }

    private func allAudioDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else { return [] }
        var deviceIDs = [AudioObjectID](repeating: 0, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }
        return deviceIDs
    }

    private func audioDeviceName(_ device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private func isDisplayTransport(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeDisplayPort || transport == kAudioDeviceTransportTypeHDMI
    }

    private func setCoreAudioDeviceVolumeIfMatched(displayName: String, volume: Float) {
        guard let devID = findAudioDeviceForMonitor(displayName: displayName) else { return }

        var vol = volume
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(devID, &volumeAddress) {
            AudioObjectSetPropertyData(devID, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float>.size), &vol)
        } else {
            volumeAddress.mSelector = kAudioDevicePropertyVolumeScalar
            if AudioObjectHasProperty(devID, &volumeAddress) {
                AudioObjectSetPropertyData(devID, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float>.size), &vol)
            }
        }
    }

    private func setCoreAudioDeviceMuteIfMatched(displayName: String, isMuted: Bool) {
        guard let devID = findAudioDeviceForMonitor(displayName: displayName) else { return }

        var muteValue: UInt32 = isMuted ? 1 : 0
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(devID, &muteAddress) {
            AudioObjectSetPropertyData(devID, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muteValue)
        }
    }

    public func isDefaultOutput(monitorName: String) -> Bool {
        guard let defaultDevice = defaultOutputDevice() else { return false }
        return findAudioDeviceForMonitor(displayName: monitorName) == defaultDevice
    }

    private var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func defaultOutputDevice() -> AudioObjectID? {
        var address = defaultOutputAddress
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return device
    }

    /// True for the MacBook's internal speakers; false for headphones on the jack and any non-built-in device
    /// (USB/Bluetooth/AirPlay speakers, headsets, etc).
    private func isBuiltInSpeakers(_ device: AudioObjectID) -> Bool {
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeBuiltIn else { return false }

        // Headphones on the built-in jack also report a built-in transport; their data source is 'hdpn'.
        var sourceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var source: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &sourceAddress),
           AudioObjectGetPropertyData(device, &sourceAddress, 0, nil, &size, &source) == noErr {
            return source != 0x6864_706E // 'hdpn'
        }
        return true
    }

    private func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    public enum OutputSwitchResult {
        case switched, notOnSpeakers, monitorAudioNotFound
    }

    /// Makes the monitor the default output, but only when sound is currently going to the MacBook speakers.
    public func switchOutputToMonitorIfOnSpeakers(displayName: String) -> OutputSwitchResult {
        guard let current = defaultOutputDevice(), isBuiltInSpeakers(current) else { return .notOnSpeakers }
        guard let monitor = findAudioDeviceForMonitor(displayName: displayName), hasOutputStreams(monitor) else {
            return .monitorAudioNotFound
        }
        var address = defaultOutputAddress
        var device = monitor
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &device
        )
        guard status == noErr else {
            dlog("Failed to switch audio output to \(displayName): \(status)")
            return .monitorAudioNotFound
        }
        dlog("Switched audio output to \(displayName)")
        return .switched
    }

    // MARK: - Built-in Keyboard Backlight (private CoreBrightness KeyboardBrightnessClient)

    private static let savedKeyboardStateKey = "savedKeyboardBacklight"

    private lazy var keyboardClient: NSObject? = {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            dlog("KeyboardBrightnessClient not available")
            return nil
        }
        return cls.init()
    }()

    private func builtinKeyboardIDs(_ client: NSObject) -> [UInt64] {
        let copySel = NSSelectorFromString("copyKeyboardBacklightIDs")
        let builtInSel = NSSelectorFromString("isKeyboardBuiltIn:")
        guard client.responds(to: copySel), client.responds(to: builtInSel),
              let ids = client.perform(copySel)?.takeRetainedValue() as? [NSNumber] else { return [] }
        typealias IsBuiltIn = @convention(c) (AnyObject, Selector, UInt64) -> Bool
        let isBuiltIn = unsafeBitCast(client.method(for: builtInSel), to: IsBuiltIn.self)
        return ids.map(\.uint64Value).filter { isBuiltIn(client, builtInSel, $0) }
    }

    private func setKeyboard(_ client: NSObject, id: UInt64, brightness: Float, autoBrightness: Bool) {
        typealias SetAuto = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool
        typealias SetBrightness = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
        let autoSel = NSSelectorFromString("enableAutoBrightness:forKeyboard:")
        let brightnessSel = NSSelectorFromString("setBrightness:forKeyboard:")
        guard client.responds(to: autoSel), client.responds(to: brightnessSel) else { return }
        _ = unsafeBitCast(client.method(for: autoSel), to: SetAuto.self)(client, autoSel, autoBrightness, id)
        _ = unsafeBitCast(client.method(for: brightnessSel), to: SetBrightness.self)(client, brightnessSel, brightness, id)
    }

    /// Saves the built-in keyboard's backlight state (persisted, so a restart can still restore it) and turns it off.
    public func turnOffKeyboardBacklight() {
        guard let client = keyboardClient else { return }
        typealias GetBrightness = @convention(c) (AnyObject, Selector, UInt64) -> Float
        typealias GetAuto = @convention(c) (AnyObject, Selector, UInt64) -> Bool
        let brightnessSel = NSSelectorFromString("brightnessForKeyboard:")
        let autoSel = NSSelectorFromString("isAutoBrightnessEnabledForKeyboard:")
        guard client.responds(to: brightnessSel), client.responds(to: autoSel) else { return }
        let getBrightness = unsafeBitCast(client.method(for: brightnessSel), to: GetBrightness.self)
        let getAuto = unsafeBitCast(client.method(for: autoSel), to: GetAuto.self)

        var saved: [String: [String: Any]] = [:]
        for id in builtinKeyboardIDs(client) {
            saved[String(id)] = ["brightness": getBrightness(client, brightnessSel, id), "auto": getAuto(client, autoSel, id)]
            setKeyboard(client, id: id, brightness: 0, autoBrightness: false)
        }
        // Don't overwrite an earlier save with the already-dark state.
        if !saved.isEmpty && UserDefaults.standard.dictionary(forKey: Self.savedKeyboardStateKey) == nil {
            UserDefaults.standard.set(saved, forKey: Self.savedKeyboardStateKey)
        }
    }

    /// Re-applies the saved backlight state. Pass `clearSaved: false` to keep it around for another attempt.
    public func restoreKeyboardBacklight(clearSaved: Bool = true) {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.savedKeyboardStateKey) as? [String: [String: Any]],
              let client = keyboardClient else { return }
        for (key, state) in saved {
            guard let id = UInt64(key) else { continue }
            let brightness = (state["brightness"] as? NSNumber)?.floatValue ?? 0.5
            let auto = state["auto"] as? Bool ?? true
            setKeyboard(client, id: id, brightness: brightness, autoBrightness: auto)
        }
        if clearSaved {
            UserDefaults.standard.removeObject(forKey: Self.savedKeyboardStateKey)
        }
    }

    // MARK: - Display Modes

    public func displayModes(for displayID: CGDirectDisplayID) -> (options: [DisplayModeOption], currentID: Int32?) {
        let currentID = CGDisplayCopyDisplayMode(displayID)?.ioDisplayModeID
        let options = allDisplayModes(for: displayID).map(DisplayModeOption.init)
        return (DisplayModeOption.menuOptions(from: options, keeping: currentID), currentID)
    }

    @discardableResult
    public func setDisplayMode(_ modeID: Int32, for displayID: CGDirectDisplayID) -> Bool {
        guard let mode = allDisplayModes(for: displayID).first(where: { $0.ioDisplayModeID == modeID }) else { return false }
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        let status = CGCompleteDisplayConfiguration(config, .permanently)
        if status != .success {
            dlog("Failed to set display mode \(modeID) on \(displayID): \(status)")
        }
        return status == .success
    }

    private func allDisplayModes(for displayID: CGDirectDisplayID) -> [CGDisplayMode] {
        // Without this option macOS hides the non-HiDPI variants of each size.
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] ?? []
        return modes.filter { $0.isUsableForDesktopGUI() }
    }
}

// MARK: - DDC VCP Codes

nonisolated enum DDCVCP {
    static let brightness: UInt8 = 0x10
    static let inputSource: UInt8 = 0x60
    static let volume: UInt8 = 0x62
    static let audioMute: UInt8 = 0x8D
}

// MARK: - DisplayModeOption

nonisolated public struct DisplayModeOption: Identifiable, Hashable, Sendable {
    public let id: Int32
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Double

    public init(id: Int32, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double) {
        self.id = id
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
    }

    init(_ mode: CGDisplayMode) {
        self.init(id: mode.ioDisplayModeID, width: mode.width, height: mode.height,
                  pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight, refreshRate: mode.refreshRate)
    }

    public var isHiDPI: Bool { pixelWidth > width }

    public var title: String {
        var title = "\(width) × \(height)"
        if isHiDPI {
            title += " (HiDPI)"
        }
        if refreshRate > 0 {
            title += " · \(Int(refreshRate.rounded())) Hz"
        }
        return title
    }

    /// One entry per distinct size, scale and refresh rate (macOS lists many duplicates), largest first.
    /// The current mode always represents its group so the menu can show it as selected.
    static func menuOptions(from modes: [DisplayModeOption], keeping currentID: Int32?) -> [DisplayModeOption] {
        struct GroupKey: Hashable {
            let width: Int, height: Int, isHiDPI: Bool, refresh: Int
        }
        var groups: [GroupKey: DisplayModeOption] = [:]
        for mode in modes {
            let key = GroupKey(width: mode.width, height: mode.height, isHiDPI: mode.isHiDPI, refresh: Int(mode.refreshRate.rounded()))
            if groups[key] == nil || mode.id == currentID {
                groups[key] = mode
            }
        }
        return groups.values.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            if $0.height != $1.height { return $0.height > $1.height }
            if $0.isHiDPI != $1.isHiDPI { return $0.isHiDPI }
            return $0.refreshRate > $1.refreshRate
        }
    }
}

// DisplayServices delivers these on a background thread with the new level under "value".
private nonisolated func nativeBrightnessCallback(
    center: CFNotificationCenter?,
    observer: UnsafeMutableRawPointer?,
    name: CFNotificationName?,
    object: UnsafeRawPointer?,
    userInfo: CFDictionary?
) {
    guard let observer,
          let value = (userInfo as NSDictionary?)?["value"] as? NSNumber else { return }
    let displayID = CGDirectDisplayID(truncatingIfNeeded: UInt(bitPattern: observer))
    let level = value.floatValue
    Task { @MainActor in
        DisplayHardwareManager.shared.onNativeBrightnessChange?(displayID, level)
    }
}
