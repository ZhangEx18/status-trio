import XCTest

@testable import StatusTrioCore

final class BatterySampleFileStoreTests: XCTestCase {
    private var directory: URL!
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatterySampleFileStoreTests-\(UUID().uuidString)")
        defaultsSuiteName = "BatterySampleFileStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    private func sample(date: Date, percentage: Double = 80, charging: Bool = true)
        -> BatteryTimeEstimator.Sample {
        BatteryTimeEstimator.Sample(date: date, percentage: percentage, charging: charging,
                                    target: nil, connectedToPower: charging)
    }

    func testPersistRoundTripsSamples() throws {
        let store = BatterySampleFileStore(directory: directory, defaults: nil)
        let samples = [sample(date: Date(timeIntervalSince1970: 1_700_000_000))]
        store.persist(samples)
        let loaded = store.load()
        XCTAssertEqual(loaded, samples)
    }

    func testLoadWithNoFileAndNoLegacyReturnsEmpty() {
        let store = BatterySampleFileStore(directory: directory, defaults: defaults)
        XCTAssertTrue(store.load().isEmpty)
    }

    func testLegacyDefaultsBlobIsMigratedAndKeyRemoved() throws {
        let legacySamples = [
            sample(date: Date(timeIntervalSince1970: 1_700_000_000)),
            sample(date: Date(timeIntervalSince1970: 1_700_000_015), percentage: 79),
        ]
        defaults.set(try JSONEncoder().encode(legacySamples),
                     forKey: "battery.timeEstimator.samples.v1")
        let store = BatterySampleFileStore(directory: directory, defaults: defaults)

        let loaded = store.load()
        XCTAssertEqual(loaded, legacySamples)
        // The file is seeded and the defaults key is gone (plist shrinks back).
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("estimator-samples.json").path))
        XCTAssertNil(defaults.data(forKey: "battery.timeEstimator.samples.v1"))

        // A second load reads from the file, legacy path no longer participates.
        XCTAssertEqual(store.load(), legacySamples)
    }

    func testExistingFileWinsOverLegacyBlob() throws {
        let fileSamples = [sample(date: Date(timeIntervalSince1970: 1_800_000_000))]
        let store = BatterySampleFileStore(directory: directory, defaults: nil)
        store.persist(fileSamples)
        defaults.set(try JSONEncoder().encode([sample(date: Date(timeIntervalSince1970: 1_700_000_000))]),
                     forKey: "battery.timeEstimator.samples.v1")

        let loaded = BatterySampleFileStore(directory: directory, defaults: defaults).load()
        XCTAssertEqual(loaded, fileSamples)
        XCTAssertNil(defaults.data(forKey: "battery.timeEstimator.samples.v1"))
    }

    func testLargerLegacyHistoryWinsOverAStaleTestFile() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fileSamples = [
            sample(date: now.addingTimeInterval(-60), percentage: 91),
            sample(date: now.addingTimeInterval(-30), percentage: 92),
        ]
        let legacySamples = (0..<10).map {
            sample(date: now.addingTimeInterval(Double($0) * 15), percentage: Double(80 + $0))
        }
        BatterySampleFileStore(directory: directory, defaults: nil).persist(fileSamples)
        defaults.set(try JSONEncoder().encode(legacySamples),
                     forKey: "battery.timeEstimator.samples.v1")

        let loaded = BatterySampleFileStore(directory: directory, defaults: defaults).load()

        XCTAssertEqual(loaded, legacySamples)
        XCTAssertNil(defaults.data(forKey: "battery.timeEstimator.samples.v1"))
        let persisted = try JSONDecoder().decode(
            [BatteryTimeEstimator.Sample].self,
            from: Data(contentsOf: directory.appendingPathComponent("estimator-samples.json"))
        )
        XCTAssertEqual(persisted, legacySamples)
    }

    func testNewerFileWinsOverOlderLargerLegacyHistory() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fileSamples = [
            sample(date: now.addingTimeInterval(-60), percentage: 91),
            sample(date: now, percentage: 92),
        ]
        let legacySamples = (0..<10).map {
            sample(date: now.addingTimeInterval(-2 * 24 * 60 * 60 + Double($0) * 15),
                   percentage: Double(80 + $0))
        }
        BatterySampleFileStore(directory: directory, defaults: nil).persist(fileSamples)
        defaults.set(try JSONEncoder().encode(legacySamples),
                     forKey: "battery.timeEstimator.samples.v1")

        let loaded = BatterySampleFileStore(directory: directory, defaults: defaults).load()

        XCTAssertEqual(loaded, fileSamples)
        XCTAssertNil(defaults.data(forKey: "battery.timeEstimator.samples.v1"))
    }

    func testEqualRecencyAndCountMergesWithoutDuplicateTimestamps() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let shared = sample(date: now.addingTimeInterval(-60), percentage: 90)
        let fileSamples = [
            shared,
            sample(date: now, percentage: 92),
        ]
        let legacySamples = [
            sample(date: now.addingTimeInterval(-120), percentage: 89),
            sample(date: now, percentage: 91),
        ]
        BatterySampleFileStore(directory: directory, defaults: nil).persist(fileSamples)
        defaults.set(try JSONEncoder().encode(legacySamples),
                     forKey: "battery.timeEstimator.samples.v1")

        let loaded = BatterySampleFileStore(directory: directory, defaults: defaults).load()

        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded.last?.percentage, 92, "The file wins a shared timestamp")
    }

    func testLegacyKeySurvivesWhenTheReplacementCannotBePersisted() throws {
        let blocker = directory.appendingPathComponent("not-a-directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("blocker".utf8).write(to: blocker)
        let legacySamples = [sample(date: Date(timeIntervalSince1970: 1_800_000_000))]
        defaults.set(try JSONEncoder().encode(legacySamples),
                     forKey: "battery.timeEstimator.samples.v1")

        let loaded = BatterySampleFileStore(directory: blocker, defaults: defaults).load()

        XCTAssertEqual(loaded, legacySamples)
        XCTAssertNotNil(defaults.data(forKey: "battery.timeEstimator.samples.v1"))
    }

    func testRemoveAllDeletesPersistedFile() throws {
        let store = BatterySampleFileStore(directory: directory, defaults: nil)
        store.persist([sample(date: Date())])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("estimator-samples.json").path))
        store.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("estimator-samples.json").path))
    }
}
