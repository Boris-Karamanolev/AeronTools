import AppKit
import Foundation

private typealias HostActionHandler = @convention(c) (UnsafePointer<CChar>?) -> Void

@_silgen_name("aeron_set_host_action_handler")
private func aeronSetHostActionHandler(_ handler: HostActionHandler?)

nonisolated private func hostActionThunk(_ raw: UnsafePointer<CChar>?) {
    guard let raw else { return }
    let token = String(cString: raw)
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            EngineHostActions.perform(token)
        }
    }
}

/// Receives button and thumbwheel actions from the Rust input loop and runs them on the main actor.
enum EngineHostActions {
    static func install() {
        aeronSetHostActionHandler(hostActionThunk)
    }

    @MainActor
    static func perform(_ token: String) {
        let model = DisplayStateModel.shared
        guard let displayID = NSScreen.underPointer?.displayID else {
            performWithoutDisplay(token)
            return
        }
        switch token {
        case "brightnessUp":
            _ = model.handleMediaKey(.brightnessUp, on: displayID)
        case "brightnessDown":
            _ = model.handleMediaKey(.brightnessDown, on: displayID)
        case "volumeUp":
            _ = model.handleMediaKey(.volumeUp, on: displayID)
        case "volumeDown":
            _ = model.handleMediaKey(.volumeDown, on: displayID)
        default:
            performWithoutDisplay(token)
        }
    }

    @MainActor
    private static func performWithoutDisplay(_ token: String) {
        guard let action = AccessoryButtonAction(rawValue: token) else { return }
        AccessoryActions.perform(action)
    }
}
