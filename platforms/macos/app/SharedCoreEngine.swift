import Foundation
import Observation

/// SwiftUI facade over the Rust `AeronEngine`.
///
/// The menu-bar app starts this once. It owns HID input. Display schedules, extra dimming,
/// media keys, and the OSD stay in `DisplayStateModel` and call the engine for the hardware write.
@Observable
@MainActor
public final class SharedCoreEngine {
    public static let shared = SharedCoreEngine()

    public private(set) var snapshot: CoreAppSnapshot?
    public private(set) var lastError: String?
    public private(set) var isInitialized: Bool = false

    public nonisolated static var version: String {
        aeronEngineVersion()
    }

    public nonisolated static var defaultPreferences: CoreAppPreferences {
        aeronDefaultPreferences()
    }

    private nonisolated final class EngineBox: @unchecked Sendable {
        let engine: AeronEngine
        init(_ engine: AeronEngine) {
            self.engine = engine
        }
    }

    private var box: EngineBox?

    public init() {}

    /// Lazily initializes the underlying Rust `AeronCore` instance off the main thread
    /// and publishes the initial snapshot.
    public func startIfNeeded() async {
        guard box == nil else { return }
        let created = await Task.detached(priority: .userInitiated) { () -> (EngineBox, CoreAppSnapshot) in
            let engine = AeronEngine()
            let initial = engine.snapshot()
            return (EngineBox(engine), initial)
        }.value
        self.box = created.0
        self.snapshot = created.1
        self.isInitialized = true
        reportBatteryAlerts(created.1)
    }

    /// Publishes the engine snapshot. The hardware watcher inside the engine is what talks to devices.
    public func startWatching() async {
        await startIfNeeded()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(400))
            await pullSnapshot()
        }
    }

    private func pullSnapshot() async {
        guard let box else { return }
        let updated = await Task.detached(priority: .utility) {
            box.engine.snapshot()
        }.value
        self.snapshot = updated
        reportBatteryAlerts(updated)
    }

    private func reportBatteryAlerts(_ snapshot: CoreAppSnapshot) {
        let accessories = snapshot.accessories
        let reports: [(String, String, UInt8?, Bool)] = [
            ("mx-master", accessories.mxMaster.name, accessories.mxMaster.batteryPercent, accessories.mxMaster.isCharging),
            ("mx-keyboard", accessories.mxKeyboard.name, accessories.mxKeyboard.batteryPercent, accessories.mxKeyboard.isCharging),
            ("logitech-g-mouse", accessories.logitechGMouse.name, accessories.logitechGMouse.batteryPercent, accessories.logitechGMouse.isCharging),
            ("logitech-g-keyboard", accessories.logitechGKeyboard.name, accessories.logitechGKeyboard.batteryPercent, accessories.logitechGKeyboard.isCharging),
            ("keychron", accessories.keychronM3Mini.name, accessories.keychronM3Mini.batteryPercent, accessories.keychronM3Mini.isCharging),
        ]
        for (id, name, percent, charging) in reports {
            AccessoryBatteryAlerts.shared.report(id: id, name: name, percent: percent.map(Int.init), isCharging: charging)
        }
    }

    public func refreshAll() async {
        await runMutation { engine in
            engine.refreshAll()
        }
    }

    public func refreshAccessoriesAndDocks() async {
        await startIfNeeded()
        guard let box else { return }
        let updated = await Task.detached(priority: .utility) { () -> CoreAppSnapshot in
            box.engine.refreshAccessoriesAndDocks()
            return box.engine.snapshot()
        }.value
        self.snapshot = updated
    }

    public func setDisplayBrightness(displayId: String, level: Float) async {
        await runThrowingMutation { engine in
            try engine.setDisplayBrightness(displayId: displayId, level: level)
        }
    }

    public func stepAllBrightness(delta: Float) async {
        await runThrowingMutation { engine in
            try engine.stepAllBrightness(delta: delta)
        }
    }

    public func setDisplayVolume(displayId: String, level: Float) async {
        await runThrowingMutation { engine in
            try engine.setDisplayVolume(displayId: displayId, level: level)
        }
    }

    public func setDisplayMuted(displayId: String, muted: Bool) async {
        await runThrowingMutation { engine in
            try engine.setDisplayMuted(displayId: displayId, muted: muted)
        }
    }

    public func setDisplayInput(displayId: String, inputCode: UInt8) async {
        await runThrowingMutation { engine in
            try engine.setDisplayInput(displayId: displayId, inputCode: inputCode)
        }
    }

    public func setBuiltinDisplayEnabled(_ enabled: Bool) async {
        await runThrowingMutation { engine in
            try engine.setBuiltinDisplayEnabled(enabled: enabled)
        }
    }

    public func toggleBuiltinDisplay() async {
        await runThrowingMutation { engine in
            try engine.toggleBuiltinDisplay()
        }
    }

    public func setCaffeine(active: Bool, durationSeconds: UInt64? = nil) async {
        await runThrowingMutation { engine in
            try engine.setCaffeine(active: active, durationSeconds: durationSeconds)
        }
    }

    public func toggleCaffeine() async {
        await runThrowingMutation { engine in
            try engine.toggleCaffeine()
        }
    }

    public func setGameModePolicy(_ policy: CoreGameModePolicy) async {
        await runThrowingMutation { engine in
            try engine.setGameModePolicy(policy: policy)
        }
    }

    public func toggleGameModeForced() async {
        await runThrowingMutation { engine in
            try engine.toggleGameModeForced()
        }
    }

    public func updatePreferences(_ prefs: CoreAppPreferences) async {
        await runMutation { engine in
            engine.updatePreferences(prefs: prefs)
        }
    }

    public func setMxMasterDpi(_ dpi: UInt16) async {
        await runMutation { engine in
            engine.setMxMasterDpi(dpi: dpi)
        }
    }

    public func setMxMasterSmartShift(
        wheelMode: CoreWheelMode,
        smartShiftEnabled: Bool,
        threshold: UInt8
    ) async {
        await runMutation { engine in
            engine.setMxMasterSmartShift(
                wheelMode: wheelMode,
                smartShiftEnabled: smartShiftEnabled,
                threshold: threshold
            )
        }
    }

    public func setMxMasterOptions(_ options: CoreMxMasterOptions) async {
        await runMutation { engine in
            engine.setMxMasterOptions(opts: options)
        }
    }

    public func setLogitechGDpi(_ dpi: UInt16) async {
        await runMutation { engine in
            engine.setLogitechGDpi(dpi: dpi)
        }
    }

    public func setLogitechGReportRate(_ hz: UInt16) async {
        await runMutation { engine in
            engine.setLogitechGReportRate(hz: hz)
        }
    }

    public func setLogitechGTriggers(_ triggers: CoreTriggerSettings) async {
        await runMutation { engine in
            engine.setLogitechGTriggers(triggers: triggers)
        }
    }

    public func setLogitechGOptions(
        backButton: CoreButtonAction,
        forwardButton: CoreButtonAction,
        savesToOnboardProfile: Bool
    ) async {
        await runMutation { engine in
            engine.setLogitechGOptions(
                backButton: backButton,
                forwardButton: forwardButton,
                savesToOnboardProfile: savesToOnboardProfile
            )
        }
    }

    public func setMxKeyboardBacklight(
        enabled: Bool,
        autoBrightness: Bool,
        batterySaving: Bool,
        level: UInt8,
        durationSeconds: UInt16,
        effect: CoreBacklightEffect
    ) async {
        await runMutation { engine in
            engine.setMxKeyboardBacklight(
                enabled: enabled,
                autoBrightness: autoBrightness,
                batterySaving: batterySaving,
                level: level,
                durationSeconds: durationSeconds,
                effect: effect
            )
        }
    }

    public func setMxKeyboardFnInversion(standardFn: Bool) async {
        await runMutation { engine in
            engine.setMxKeyboardFnInversion(standardFn: standardFn)
        }
    }

    public func setMxKeyboardKeyAction(position: UInt8, action: CoreButtonAction) async {
        await runMutation { engine in
            engine.setMxKeyboardKeyAction(position: position, action: action)
        }
    }

    public func setGKeyboardLighting(brightness: UInt16, lighting: CoreRgbLighting) async {
        await runMutation { engine in
            engine.setGKeyboardLighting(brightness: brightness, lighting: lighting)
        }
    }

    public func setKeychronSettings(
        activeStage: UInt8,
        dpi: UInt16,
        reportRateHz: UInt16,
        liftOffMm: UInt8,
        motionSync: Bool,
        angleSnapping: Bool
    ) async {
        await runMutation { engine in
            engine.setKeychronSettings(
                activeStage: activeStage,
                dpi: dpi,
                reportRateHz: reportRateHz,
                liftOffMm: liftOffMm,
                motionSync: motionSync,
                angleSnapping: angleSnapping
            )
        }
    }

    public func setKeychronSideButtons(
        backButton: CoreButtonAction,
        forwardButton: CoreButtonAction
    ) async {
        await runMutation { engine in
            engine.setKeychronSideButtons(backButton: backButton, forwardButton: forwardButton)
        }
    }

    public func setRazerDockLighting(
        brightness: UInt8?,
        lighting: CoreRazerLighting?
    ) async {
        await runMutation { engine in
            engine.setRazerDockLighting(brightness: brightness, lighting: lighting)
        }
    }

    public func prepareForTermination() {
        box?.engine.prepareForTermination()
    }

    // MARK: - Helpers

    private func runMutation(
        _ work: @escaping @Sendable (AeronEngine) -> CoreAppSnapshot
    ) async {
        await startIfNeeded()
        guard let box else { return }
        let updated = await Task.detached(priority: .userInitiated) {
            work(box.engine)
        }.value
        self.snapshot = updated
        self.lastError = nil
    }

    private func runThrowingMutation(
        _ work: @escaping @Sendable (AeronEngine) throws -> CoreAppSnapshot
    ) async {
        await startIfNeeded()
        guard let box else { return }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<CoreAppSnapshot, Error> in
            do {
                return .success(try work(box.engine))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let updated):
            self.snapshot = updated
            self.lastError = nil
        case .failure(let error):
            self.lastError = error.localizedDescription
        }
    }
}
