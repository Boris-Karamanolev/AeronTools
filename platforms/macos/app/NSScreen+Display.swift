import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// The screen the mouse pointer is currently on.
    static var underPointer: NSScreen? {
        let pointer = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(pointer, $0.frame, false) }
    }
}
