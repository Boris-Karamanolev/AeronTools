import AppKit
import ApplicationServices

public enum MediaKey {
    case brightnessUp, brightnessDown, volumeUp, volumeDown, mute

    // NX_KEYTYPE_* values from IOKit/hidsystem/ev_keymap.h
    init?(nxKeyType: Int) {
        switch nxKeyType {
        case 0: self = .volumeUp
        case 1: self = .volumeDown
        case 2: self = .brightnessUp
        case 3: self = .brightnessDown
        case 7: self = .mute
        default: return nil
        }
    }
}

/// Intercepts brightness/volume keys so they act on the external display under the pointer.
/// Requires Accessibility permission (needed for an event tap that can swallow events).
@MainActor
final class MediaKeyController {
    static let shared = MediaKeyController()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isEnabled = false
    // Key-ups are swallowed only if their key-down was, so macOS never sees half a key press.
    private var swallowedKeys = Set<MediaKey>()

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
        guard tap == nil else { return }

        let permission = AccessibilityPermission.shared
        permission.request()
        // Started again from the permission change handler once the user grants access.
        guard permission.isGranted else { return }

        let systemDefinedMask = CGEventMask(1 << NSEvent.EventType.systemDefined.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: systemDefinedMask,
            callback: mediaKeyTapCallback,
            userInfo: nil
        ) else {
            dlog("Failed to create media key event tap")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
    }

    private func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        swallowedKeys.removeAll()
    }

    fileprivate func reenableAfterTimeout() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// Returns true if the event should be swallowed.
    fileprivate func handle(_ key: MediaKey, keyDown: Bool) -> Bool {
        guard keyDown else {
            return swallowedKeys.remove(key) != nil
        }
        guard let displayID = NSScreen.underPointer?.displayID,
              DisplayStateModel.shared.handleMediaKey(key, on: displayID) else {
            swallowedKeys.remove(key)
            return false
        }
        swallowedKeys.insert(key)
        return true
    }
}

// The tap's run loop source is on the main run loop, so this always runs on the main thread.
private nonisolated func mediaKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let passThrough = Unmanaged.passUnretained(event)

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { MediaKeyController.shared.reenableAfterTimeout() }
        return passThrough
    }

    let swallow = MainActor.assumeIsolated { () -> Bool in
        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.type == .systemDefined,
              nsEvent.subtype.rawValue == 8 else { return false } // NX_SUBTYPE_AUX_CONTROL_BUTTONS

        let data1 = nsEvent.data1
        let keyType = (data1 & 0xFFFF_0000) >> 16
        let keyDown = ((data1 & 0xFF00) >> 8) == 0xA
        guard let key = MediaKey(nxKeyType: keyType) else { return false }
        return MediaKeyController.shared.handle(key, keyDown: keyDown)
    }
    return swallow ? nil : passThrough
}
