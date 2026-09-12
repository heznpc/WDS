import XCTest
@testable import WDSAppCore

final class FeatureSettingsTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "WDSFeatureSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testNewInstallStartsWithBothFeaturesOff() {
        withDefaults { defaults in
            XCTAssertEqual(FeatureSettings(defaults: defaults), FeatureSettings())
        }
    }

    func testLegacyEngineMigratesBothFeaturesWithoutChangingOptIn() {
        for legacy in [false, true] {
            withDefaults { defaults in
                defaults.set(legacy, forKey: FeatureSettings.legacyEnabledKey)
                let settings = FeatureSettings(defaults: defaults)
                XCTAssertEqual(settings.inputCleanupEnabled, legacy)
                XCTAssertEqual(settings.sourceSeparationEnabled, legacy)
            }
        }
    }

    func testAllFourCombinationsSurviveReloadAndOverrideLegacySetting() {
        for cleanup in [false, true] {
            for source in [false, true] {
                withDefaults { defaults in
                    defaults.set(true, forKey: FeatureSettings.legacyEnabledKey)
                    let settings = FeatureSettings(inputCleanupEnabled: cleanup, sourceSeparationEnabled: source)
                    settings.save(to: defaults)
                    XCTAssertEqual(FeatureSettings(defaults: defaults), settings)
                    XCTAssertEqual(settings.anyEnabled, cleanup || source)
                }
            }
        }
    }

    func testDisablingCleanupPreservesSourceOptIn() {
        withDefaults { defaults in
            defaults.set(true, forKey: FeatureSettings.legacyEnabledKey)
            var settings = FeatureSettings(defaults: defaults)
            settings.inputCleanupEnabled = false
            settings.save(to: defaults)
            let reloaded = FeatureSettings(defaults: defaults)
            XCTAssertFalse(reloaded.inputCleanupEnabled)
            XCTAssertTrue(reloaded.sourceSeparationEnabled)
        }
    }

    func testDisablingSourcePreservesCleanupOptIn() {
        withDefaults { defaults in
            defaults.set(true, forKey: FeatureSettings.legacyEnabledKey)
            var settings = FeatureSettings(defaults: defaults)
            settings.sourceSeparationEnabled = false
            settings.save(to: defaults)
            let reloaded = FeatureSettings(defaults: defaults)
            XCTAssertTrue(reloaded.inputCleanupEnabled)
            XCTAssertFalse(reloaded.sourceSeparationEnabled)
        }
    }
}
