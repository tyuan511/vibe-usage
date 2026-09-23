import XCTest
@testable import VibeUsageApp

final class LegacyDefaultsMigrationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "LegacyDefaultsMigrationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testCopiesLegacySettingsExceptLoginItemState() {
        LegacyDefaultsMigration.run(
            legacyValues: [
                "menuBarMetricMode": "tokens",
                "hiddenAgentSourceIDs": ["codex"],
                LoginItemController.defaultRegistrationAttemptedKey: true,
                LoginItemController.defaultRegistrationErrorKey: "failed"
            ],
            into: defaults,
            currentDomain: "vibeusage.fastvibe.dev"
        )

        XCTAssertEqual(defaults.string(forKey: "menuBarMetricMode"), "tokens")
        XCTAssertEqual(defaults.stringArray(forKey: "hiddenAgentSourceIDs"), ["codex"])
        XCTAssertNil(defaults.object(forKey: LoginItemController.defaultRegistrationAttemptedKey))
        XCTAssertNil(defaults.object(forKey: LoginItemController.defaultRegistrationErrorKey))
    }

    func testDoesNotOverwriteCurrentSettingsOrRunTwice() {
        defaults.set("spend", forKey: "menuBarMetricMode")

        LegacyDefaultsMigration.run(
            legacyValues: ["menuBarMetricMode": "tokens"],
            into: defaults,
            currentDomain: "vibeusage.fastvibe.dev"
        )
        LegacyDefaultsMigration.run(
            legacyValues: ["enablesLimitMonitoring": false],
            into: defaults,
            currentDomain: "vibeusage.fastvibe.dev"
        )

        XCTAssertEqual(defaults.string(forKey: "menuBarMetricMode"), "spend")
        XCTAssertNil(defaults.object(forKey: "enablesLimitMonitoring"))
    }

    func testSkipsWhenRunningUnderLegacyIdentifier() {
        LegacyDefaultsMigration.run(
            legacyValues: ["menuBarMetricMode": "tokens"],
            into: defaults,
            currentDomain: LegacyDefaultsMigration.legacyDomain
        )

        XCTAssertNil(defaults.object(forKey: "menuBarMetricMode"))
        XCTAssertFalse(defaults.bool(forKey: LegacyDefaultsMigration.completedKey))
    }
}
