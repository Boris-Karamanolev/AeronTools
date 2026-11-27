import Foundation
import CoreGraphics
import ObjectiveC.runtime

// MARK: - Dynamic Private CoreGraphics Virtual Display Bridge

/// Dynamically bridges Apple's private `CGVirtualDisplay` classes inside CoreGraphics
/// via the Objective-C runtime so no private bridging header is required.
/// Creates a single extended virtual monitor on macOS 14+ and cleanly unplugs it when deallocated.
final class VirtualDisplayManager {
    nonisolated static let virtualVendorID: UInt32 = 0x1337
    nonisolated static let virtualProductID: UInt32 = 0x51DE

    struct ActiveVirtualDisplay {
        let displayID: CGDirectDisplayID
        let width: Int
        let height: Int
        let backingObject: NSObject
    }

    private(set) var activeDisplay: ActiveVirtualDisplay?

    /// Returns true if the given `CGDirectDisplayID` belongs to an Aeron Tools virtual display.
    nonisolated static func isVirtualDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(displayID) == virtualVendorID
    }

    nonisolated var isRuntimeSupported: Bool {
        NSClassFromString("CGVirtualDisplay") != nil &&
        NSClassFromString("CGVirtualDisplayDescriptor") != nil &&
        NSClassFromString("CGVirtualDisplaySettings") != nil &&
        NSClassFromString("CGVirtualDisplayMode") != nil
    }

    var activeDisplayID: CGDirectDisplayID? {
        activeDisplay?.displayID
    }

    /// Creates or replaces the single virtual extended display.
    /// Returns the `CGDirectDisplayID` if creation succeeds, or `nil` if unavailable.
    func createVirtualDisplay(
        name: String = "Aeron Tools Wireless",
        width: Int,
        height: Int,
        scale: DisplayScale = .standard,
        refreshRate: Double = 60.0
    ) -> CGDirectDisplayID? {
        destroyVirtualDisplay()

        guard
            let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
            let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type,
            let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
            let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type
        else {
            return nil
        }

        let logicalW = max(640, Int((Double(width) / (scale == .compact ? scale.multiplier : 1.0)).rounded()))
        let logicalH = max(480, Int((Double(height) / (scale == .compact ? scale.multiplier : 1.0)).rounded()))
        let maxPixelsW = scale.usesHiDPI ? max(logicalW * 2, Int((Double(width) * scale.multiplier).rounded())) : logicalW
        let maxPixelsH = scale.usesHiDPI ? max(logicalH * 2, Int((Double(height) * scale.multiplier).rounded())) : logicalH

        // 1. Configure CGVirtualDisplayDescriptor
        let descriptor = descriptorClass.init()
        descriptor.setValue(name, forKey: "name")
        descriptor.setValue(NSNumber(value: maxPixelsW), forKey: "maxPixelsWide")
        descriptor.setValue(NSNumber(value: maxPixelsH), forKey: "maxPixelsHigh")
        descriptor.setValue(CGSize(width: 380, height: 240), forKey: "sizeInMillimeters")
        descriptor.setValue(NSNumber(value: Self.virtualVendorID), forKey: "vendorID")
        descriptor.setValue(NSNumber(value: Self.virtualProductID), forKey: "productID")
        descriptor.setValue(NSNumber(value: 0x1001), forKey: "serialNum")
        descriptor.setValue(DispatchQueue.main, forKey: "queue")

        // 2. Instantiate CGVirtualDisplay with exact +1 retain semantics so dealloc unplugs the display
        let allocSel = NSSelectorFromString("alloc")
        let initDescSel = NSSelectorFromString("initWithDescriptor:")
        guard
            let allocMethod = class_getClassMethod(displayClass, allocSel),
            let initDescMethod = class_getInstanceMethod(displayClass, initDescSel)
        else {
            return nil
        }

        typealias AllocIMP = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?
        typealias InitWithDescriptorIMP = @convention(c) (UnsafeMutableRawPointer, Selector, AnyObject) -> UnsafeMutableRawPointer?

        let allocFn = unsafeBitCast(method_getImplementation(allocMethod), to: AllocIMP.self)
        let initDescFn = unsafeBitCast(method_getImplementation(initDescMethod), to: InitWithDescriptorIMP.self)

        guard
            let rawAllocated = allocFn(displayClass, allocSel),
            let rawInitialized = initDescFn(rawAllocated, initDescSel, descriptor)
        else {
            return nil
        }
        let virtualDisplayObj = Unmanaged<NSObject>.fromOpaque(rawInitialized).takeRetainedValue()

        // 3. Create CGVirtualDisplayMode(s) with exact +1 retain semantics
        let initModeSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard
            let modeAllocMethod = class_getClassMethod(modeClass, allocSel),
            let modeInitMethod = class_getInstanceMethod(modeClass, initModeSel)
        else {
            return nil
        }

        typealias InitModeIMP = @convention(c) (UnsafeMutableRawPointer, Selector, UInt, UInt, Double) -> UnsafeMutableRawPointer?
        let modeAllocFn = unsafeBitCast(method_getImplementation(modeAllocMethod), to: AllocIMP.self)
        let modeInitFn = unsafeBitCast(method_getImplementation(modeInitMethod), to: InitModeIMP.self)

        func makeMode(w: Int, h: Int, hz: Double) -> NSObject? {
            guard
                let rawModeAlloc = modeAllocFn(modeClass, allocSel),
                let rawModeInit = modeInitFn(rawModeAlloc, initModeSel, UInt(w), UInt(h), hz)
            else {
                return nil
            }
            return Unmanaged<NSObject>.fromOpaque(rawModeInit).takeRetainedValue()
        }

        var modes: [NSObject] = []
        if let primaryMode = makeMode(w: logicalW, h: logicalH, hz: refreshRate) {
            modes.append(primaryMode)
        }
        if refreshRate != 30.0, let fallbackMode = makeMode(w: logicalW, h: logicalH, hz: 30.0) {
            modes.append(fallbackMode)
        }
        if scale.usesHiDPI {
            if let backingMode = makeMode(w: maxPixelsW, h: maxPixelsH, hz: refreshRate) {
                modes.append(backingMode)
            }
            if logicalW != maxPixelsW / 2, let retinaBacking = makeMode(w: logicalW * 2, h: logicalH * 2, hz: refreshRate) {
                modes.append(retinaBacking)
            }
        }

        guard !modes.isEmpty else { return nil }

        // 4. Configure CGVirtualDisplaySettings & applySettings:
        let settings = settingsClass.init()
        settings.setValue(NSNumber(value: scale.usesHiDPI ? 1 : 0), forKey: "hiDPI")
        settings.setValue(modes, forKey: "modes")

        let applySelector = NSSelectorFromString("applySettings:")
        if virtualDisplayObj.responds(to: applySelector) {
            _ = virtualDisplayObj.perform(applySelector, with: settings)
        }

        // 5. Extract displayID
        guard let displayIDNumber = virtualDisplayObj.value(forKey: "displayID") as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(displayIDNumber.uint32Value)
        guard displayID != 0, displayID != kCGNullDirectDisplay else {
            return nil
        }

        // Ensure macOS treats the virtual display as an Extended Desktop rather than Mirroring the main display
        detachFromMirroringIfNeeded(displayID: displayID)

        activeDisplay = ActiveVirtualDisplay(
            displayID: displayID,
            width: logicalW,
            height: logicalH,
            backingObject: virtualDisplayObj
        )

        return displayID
    }

    /// Ensures the virtual display is configured as a separate extended space instead of mirroring the main display.
    private func detachFromMirroringIfNeeded(displayID: CGDirectDisplayID) {
        if CGDisplayIsInMirrorSet(displayID) != 0 {
            var configRef: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef {
                CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
                CGCompleteDisplayConfiguration(config, .forSession)
            }
        }
    }

    func destroyVirtualDisplay() {
        activeDisplay = nil
    }
}
