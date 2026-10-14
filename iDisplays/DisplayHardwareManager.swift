import Foundation
import CoreGraphics
import IOKit
import CoreAudio
import AudioToolbox
import Darwin
import os

private let displayLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "iDisplays", category: "Display")

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
    private typealias IOAVServiceCreateWithServiceFunc = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?
    private typealias IOAVServiceWriteI2CFunc = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private var slsConfigureDisplayEnabled: SLSConfigureDisplayEnabledFunc?
    private var slsGetDisplayList: SLSGetDisplayListFunc?
    private var dsSetBrightness: DisplayServicesSetBrightnessFunc?
    private var dsGetBrightness: DisplayServicesGetBrightnessFunc?
    private var ioavCreateWithService: IOAVServiceCreateWithServiceFunc?
    private var ioavWriteI2C: IOAVServiceWriteI2CFunc?

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

        // 3. CoreDisplay / IOAVService for Apple Silicon DDC/CI
        let cdHandle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
        if let avCreateSym = dlsym(cdHandle ?? rtldDefault, "IOAVServiceCreateWithService") {
            ioavCreateWithService = unsafeBitCast(avCreateSym, to: IOAVServiceCreateWithServiceFunc.self)
        }
        if let avWriteSym = dlsym(cdHandle ?? rtldDefault, "IOAVServiceWriteI2C") {
            ioavWriteI2C = unsafeBitCast(avWriteSym, to: IOAVServiceWriteI2CFunc.self)
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

        let current = getBrightness(for: displayID)
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
        setBrightness(for: displayID, level: restoreLevel)

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

    // MARK: - Display Brightness Control (Synced with Saved State)

    public func getBrightness(for displayID: CGDirectDisplayID) -> Float {
        if CGDisplayIsBuiltin(displayID) != 0 {
            if let getBrightnessFunc = dsGetBrightness {
                var value: Float = 0.75
                if getBrightnessFunc(displayID, &value) == 0 && value > 0 {
                    return value
                }
            }
            let saved = UserDefaults.standard.float(forKey: "savedBuiltinBrightness")
            return saved > 0.05 ? saved : 0.75
        } else {
            // Check saved brightness for this external monitor
            let saved = UserDefaults.standard.float(forKey: "monitorBrightness_\(displayID)")
            if saved > 0.01 {
                return saved
            }
            if let getBrightnessFunc = dsGetBrightness {
                var value: Float = 0.75
                if getBrightnessFunc(displayID, &value) == 0 && value > 0 {
                    return value
                }
            }
            return 0.75
        }
    }

    public func setBrightness(for displayID: CGDirectDisplayID, level: Float) {
        let clamped = max(0.0, min(1.0, level))
        
        // Persist level
        if CGDisplayIsBuiltin(displayID) != 0 {
            if clamped > 0.05 {
                UserDefaults.standard.set(clamped, forKey: "savedBuiltinBrightness")
            }
        } else {
            UserDefaults.standard.set(clamped, forKey: "monitorBrightness_\(displayID)")
        }

        // 1. Try DisplayServices (Apple built-in & Apple displays)
        var dsSuccess = false
        if let setBrightnessFunc = dsSetBrightness {
            let res = setBrightnessFunc(displayID, clamped)
            if res == 0 {
                dsSuccess = true
            }
        }

        // 2. Send DDC/CI packet (VCP code 0x10) for external third-party monitors
        guard CGDisplayIsBuiltin(displayID) == 0 else { return }
        let ddcValue = UInt8(clamped * 100.0)
        let ddcSuccess = sendDDCCommand(vcpCode: 0x10, value: ddcValue)

        // 3. Fallback: If neither native API nor DDC wrote successfully, adjust gamma table
        if !dsSuccess && !ddcSuccess {
            setGammaBrightness(for: displayID, level: clamped)
        }
    }

    private func setGammaBrightness(for displayID: CGDirectDisplayID, level: Float) {
        let clamped = max(0.01, min(1.0, level))
        var redTable: [CGGammaValue] = [0.0, CGGammaValue(clamped)]
        var greenTable: [CGGammaValue] = [0.0, CGGammaValue(clamped)]
        var blueTable: [CGGammaValue] = [0.0, CGGammaValue(clamped)]
        CGSetDisplayTransferByTable(displayID, 2, &redTable, &greenTable, &blueTable)
    }

    // MARK: - Monitor Hardware Volume Control (DDC/CI Only - Never Touches Headphones)

    public func setMonitorVolume(level: Float, displayName: String) {
        let clamped = max(0.0, min(1.0, level))
        UserDefaults.standard.set(clamped, forKey: "monitorVolume_\(displayName)")

        // 1. Send DDC/CI Audio Volume (VCP 0x62) directly to the external monitor
        let ddcValue = UInt8(clamped * 100.0)
        _ = sendDDCCommand(vcpCode: 0x62, value: ddcValue)

        // 2. Only adjust CoreAudio IF an audio output device specifically matches the monitor name
        setCoreAudioDeviceVolumeIfMatched(displayName: displayName, volume: clamped)
    }

    public func setMonitorMuted(_ isMuted: Bool, displayName: String) {
        UserDefaults.standard.set(isMuted, forKey: "monitorMuted_\(displayName)")
        // VCP 0x8D is DDC Audio Mute (1 = Mute, 2 = Unmute)
        _ = sendDDCCommand(vcpCode: 0x8D, value: isMuted ? 1 : 2)
        setCoreAudioDeviceMuteIfMatched(displayName: displayName, isMuted: isMuted)
    }

    // MARK: - DDC/CI Transport (Apple Silicon DCPAVServiceProxy)

    @discardableResult
    private func sendDDCCommand(vcpCode: UInt8, value: UInt8) -> Bool {
        guard let avCreate = ioavCreateWithService,
              let avWrite = ioavWriteI2C else {
            return false
        }

        var iterator = io_iterator_t()
        let matchingDict = IOServiceMatching("DCPAVServiceProxy")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }

        var anySuccess = false
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }

            // Skip built-in embedded display services
            if let locCF = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0) {
                let location = "\(locCF.takeRetainedValue())"
                if location == "Embedded" {
                    continue
                }
            }

            guard let unmanagedService = avCreate(kCFAllocatorDefault, entry) else {
                continue
            }
            let avService = unmanagedService.takeRetainedValue()

            // Standard DDC/CI packet format
            var packet: [UInt8] = [0x84, 0x03, vcpCode, 0x00, value]
            var checksum: UInt8 = 0x6E ^ 0x51
            for byte in packet {
                checksum ^= byte
            }
            packet.append(checksum)

            let chipAddress: UInt32 = 0x37
            let dataAddress: UInt32 = 0x51
            let packetCount = UInt32(packet.count)

            let status = packet.withUnsafeMutableBytes { ptr in
                avWrite(avService, chipAddress, dataAddress, ptr.baseAddress!, packetCount)
            }

            if status == kIOReturnSuccess {
                anySuccess = true
            }
        }
        return anySuccess
    }

    // MARK: - Targeted CoreAudio Helper (Only Matches Monitor Name, NEVER Touches Headphones)

    private func findAudioDeviceForMonitor(displayName: String) -> AudioObjectID? {
        guard !displayName.isEmpty else { return nil }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        let getStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        guard getStatus == noErr else { return nil }

        let cleanTarget = displayName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        for devID in deviceIDs {
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: Unmanaged<CFString>? = nil
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            if AudioObjectGetPropertyData(devID, &nameAddress, 0, nil, &nameSize, &name) == noErr,
               let cfName = name?.takeRetainedValue() {
                let devName = (cfName as String).lowercased()
                if devName.contains(cleanTarget) || cleanTarget.contains(devName) {
                    return devID
                }
            }
        }
        return nil
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
}
