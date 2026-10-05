import XCTest
@testable import StatusTrioCore

final class BatteryProfileMigrationTests: XCTestCase {
    func testLegacyCatalogIsRebuiltRatherThanPromotedAndOtherSettingsSurvive() throws {
        let name = "BatteryProfileMigrationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date()
        let legacy = BatteryTimeProfileCatalog(profiles: [
            BatteryTimeProfile(direction: .charging, targetPercent: 95,
                               sessionStart: now.addingTimeInterval(-600), sessionEnd: now,
                               sessionStartPercent: 90, sessionEndPercent: 95,
                               bands: [.init(lowerPercent: 90, minutes: 10)])
        ])
        let data = try JSONEncoder().encode(legacy)
        defaults.set(data, forKey: BatteryTimeProfileStore.key)
        defaults.set("zh-Hans", forKey: "testUnrelatedSetting")
        let store = BatteryTimeProfileStore(defaults: defaults)
        let catalog = try store.loadOrRebuild(samples: [], now: now)
        XCTAssertTrue(catalog.profiles.isEmpty)
        XCTAssertEqual(defaults.data(forKey: BatteryTimeProfileStore.key), data)
        XCTAssertEqual(defaults.string(forKey: "testUnrelatedSetting"), "zh-Hans")
        XCTAssertNotNil(defaults.data(forKey: BatteryTimeProfileStore.modelKey))
    }

    func testValidV2IsLoadedWithoutRepeatingMigration() throws {
        let name = "BatteryProfileMigrationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = BatteryTimeProfileStore(defaults: defaults)
        _ = try store.loadOrRebuild(samples: [], now: Date())
        let bytes = defaults.data(forKey: BatteryTimeProfileStore.modelKey)
        _ = try store.loadOrRebuild(samples: [], now: Date().addingTimeInterval(60))
        XCTAssertEqual(defaults.data(forKey: BatteryTimeProfileStore.modelKey), bytes)
    }

    func testMalformedV2IsRebuiltWithoutTrustingLegacyBands() throws {
        let name = "BatteryProfileMigrationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("broken".utf8), forKey: BatteryTimeProfileStore.modelKey)
        let store = BatteryTimeProfileStore(defaults: defaults)
        XCTAssertTrue(try store.loadOrRebuild(samples: [], now: Date()).profiles.isEmpty)
        XCTAssertNotNil(store.load())
    }
}
