import Foundation
import Testing
@testable import AeronTools

@Suite("Shared Rust Core Engine (UniFFI)")
struct SharedCoreEngineTests {
    @Test("UniFFI bridge returns the Rust engine version, matching the app's version")
    func engineVersionMatchesCargoPackage() {
        let version = SharedCoreEngine.version
        #expect(!version.isEmpty)
        // The host app's MARKETING_VERSION and the Cargo workspace version are bumped together for a release.
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        #expect(version == appVersion)
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
