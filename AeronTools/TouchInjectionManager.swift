import Foundation
import CoreGraphics
import ApplicationServices

// MARK: - Touch & Pointer Event Injection Engine

/// Translates normalized `(0.0...1.0)` web canvas coordinates from a Tesla, iPad, or desktop browser
/// into global CoreGraphics display coordinates for the specific virtual display and posts `CGEvent`s.
nonisolated final class TouchInjectionManager: @unchecked Sendable {
    private let eventQueue = DispatchQueue(label: "com.aeronlabs.idisplays.touch", qos: .userInteractive)
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private let configLock = NSLock()
    private var _targetDisplayID: CGDirectDisplayID = CGMainDisplayID()
    private var _isEnabled: Bool = true

    private var isLeftButtonDown = false
    private var cachedDisplayID: CGDirectDisplayID = 0
    private var cachedBounds: CGRect = .zero
    private var lastBoundsCheckTime: CFAbsoluteTime = 0

    func updateTarget(displayID: CGDirectDisplayID?, isEnabled: Bool) {
        configLock.lock()
        _targetDisplayID = displayID ?? CGMainDisplayID()
        _isEnabled = isEnabled
        configLock.unlock()
    }

    /// Fast-path injection directly from the network queue without hopping through `@MainActor`.
    func injectTouch(_ payload: TouchEventPayload, intoDisplay explicitDisplayID: CGDirectDisplayID? = nil) {
        configLock.lock()
        let enabled = _isEnabled
        let targetID = explicitDisplayID ?? _targetDisplayID
        configLock.unlock()

        guard enabled else { return }
        eventQueue.async { [weak self] in
            self?.performInject(payload, intoDisplay: targetID)
        }
    }

    private func bounds(for displayID: CGDirectDisplayID) -> CGRect {
        let now = CFAbsoluteTimeGetCurrent()
        if displayID == cachedDisplayID, cachedBounds.width > 0, (now - lastBoundsCheckTime) < 2.0 {
            return cachedBounds
        }
        let fresh = CGDisplayBounds(displayID)
        cachedDisplayID = displayID
        cachedBounds = fresh
        lastBoundsCheckTime = now
        return fresh
    }

    private func performInject(_ payload: TouchEventPayload, intoDisplay displayID: CGDirectDisplayID) {
        let rect = bounds(for: displayID)
        guard rect.width > 0, rect.height > 0 else { return }

        let clampedX = min(1.0, max(0.0, payload.x))
        let clampedY = min(1.0, max(0.0, payload.y))

        let globalPoint = CGPoint(
            x: rect.origin.x + CGFloat(clampedX) * rect.width,
            y: rect.origin.y + CGFloat(clampedY) * rect.height
        )

        let src = eventSource

        switch payload.type {
        case "down":
            isLeftButtonDown = true
            if let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: globalPoint, mouseButton: .left) {
                move.post(tap: .cghidEventTap)
            }
            if let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: globalPoint, mouseButton: .left) {
                down.post(tap: .cghidEventTap)
            }

        case "move":
            let eventType: CGEventType = isLeftButtonDown ? .leftMouseDragged : .mouseMoved
            if let move = CGEvent(mouseEventSource: src, mouseType: eventType, mouseCursorPosition: globalPoint, mouseButton: .left) {
                move.post(tap: .cghidEventTap)
            }

        case "up":
            isLeftButtonDown = false
            if let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: globalPoint, mouseButton: .left) {
                up.post(tap: .cghidEventTap)
            }

        case "click":
            isLeftButtonDown = false
            if let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: globalPoint, mouseButton: .left),
               let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: globalPoint, mouseButton: .left) {
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }

        case "doubleClick":
            isLeftButtonDown = false
            for clickCount in 1...2 {
                if let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: globalPoint, mouseButton: .left),
                   let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: globalPoint, mouseButton: .left) {
                    down.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
                    up.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                }
            }

        case "rightClick":
            // Ensure any held left button from a long-press gesture is cleanly released first
            if isLeftButtonDown {
                isLeftButtonDown = false
                if let leftUp = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: globalPoint, mouseButton: .left) {
                    leftUp.post(tap: .cghidEventTap)
                }
            }
            if let down = CGEvent(mouseEventSource: src, mouseType: .rightMouseDown, mouseCursorPosition: globalPoint, mouseButton: .right),
               let up = CGEvent(mouseEventSource: src, mouseType: .rightMouseUp, mouseCursorPosition: globalPoint, mouseButton: .right) {
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }

        case "scroll":
            let dy = Int32((payload.deltaY ?? 0).rounded())
            let dx = Int32((payload.deltaX ?? 0).rounded())
            if let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: globalPoint, mouseButton: .left) {
                move.post(tap: .cghidEventTap)
            }
            if let scroll = CGEvent(
                scrollWheelEvent2Source: src,
                units: .pixel,
                wheelCount: 2,
                wheel1: dy,
                wheel2: dx,
                wheel3: 0
            ) {
                scroll.post(tap: .cghidEventTap)
            }

        default:
            break
        }
    }
}
