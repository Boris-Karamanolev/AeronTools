import Foundation
import Testing
@testable import AeronTools

@Suite("Shared Rust Core Engine (UniFFI)")
struct SharedCoreEngineTests {
    @Test("UniFFI bridge returns the Rust engine version")
    func engineVersionMatchesCargoPackage() {
        let version = SharedCoreEngine.version
        #expect(!version.isEmpty)
        #expect(version == "0.1.0")
    }

    @Test("UniFFI bridge returns default cross-platform preferences")
    func defaultPreferencesRoundTrip() {
        let prefs = SharedCoreEngine.defaultPreferences
        #expect(prefs.daemonPort == 47620)
        #expect(prefs.showAccessoriesCard)
        #expect(prefs.showWattageMeter)
        #expect(prefs.showThermals)
        #expect(!prefs.hotkeys.isEmpty)
    }
}
