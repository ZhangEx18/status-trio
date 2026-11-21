import Foundation
import XCTest
@testable import StatusTrioCore

@MainActor
final class BatteryMonitorTests: XCTestCase {
    private lazy var isolateSampleStore: URL = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryMonitorSamples-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }()

    func testChargingTelemetryMatchesPublishedFallback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryMonitorTelemetryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = BatteryTelemetryRecorder(directory: directory, powerReader: { _, _ in nil })
        let monitor = BatteryMonitor(reader: FakeBatteryReader(result: BatteryReading(
            currentCapacity: 80, maxCapacity: 100, isCharging: true,
            timeToFullChargeMinutes: 60, chargeLimit: 95, chargeLimitKnown: true,
            isConnectedToPower: true, isPresent: true)),
            lowPowerModeProvider: { false }, telemetryRecorder: recorder,
            sampleStoreDirectory: isolateSampleStore)
        monitor.refresh()
        var iterator = monitor.updates.makeAsyncIterator()
        let published = await iterator.next()
        recorder.flush()
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil).first)
        let line = try XCTUnwrap(Data(contentsOf: file).split(separator: 0x0A).first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let observation = try decoder.decode(BatteryTelemetryRecorder.Observation.self,
                                             from: Data(line))
        XCTAssertEqual(observation.displayedMinutes, published?.timeToFullChargeMinutes)
        XCTAssertEqual(observation.displayedMinutesSource, "system")
        XCTAssertEqual(observation.estimatorTargetPercent, 95)
        monitor.stop()
    }

    func testRefreshPersistsNewSampleBeforeNextLaunch() throws {
        let suite = "BatteryMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryMonitorPersistTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_000_000)
        let reading = BatteryReading(currentCapacity: 50, maxCapacity: 100,
                                     isCharging: false, isConnectedToPower: false, isPresent: true)
        let first = BatteryMonitor(reader: FakeBatteryReader(result: reading),
                                   lowPowerModeProvider: { false },
                                   nowProvider: { date }, defaults: defaults,
                                   sampleStoreDirectory: directory)
        first.refresh()
        let decoder = JSONDecoder()
        func storedSamples() throws -> [BatteryTimeEstimator.Sample] {
            let data = try Data(contentsOf: directory
                .appendingPathComponent("estimator-samples.json"))
            return try decoder.decode([BatteryTimeEstimator.Sample].self, from: data)
        }
        XCTAssertEqual(try storedSamples().count, 1)
        XCTAssertNil(defaults.data(forKey: "battery.timeEstimator.samples.v1"))
        let second = BatteryMonitor(reader: FakeBatteryReader(result: reading),
                                    lowPowerModeProvider: { false },
                                    nowProvider: { date.addingTimeInterval(60) },
                                    defaults: defaults,
                                    sampleStoreDirectory: directory)
        second.refresh()
        XCTAssertEqual(try storedSamples().count, 2)
        first.stop()
        second.stop()
    }

    func testInitSeedsBidirectionalProfilesWithoutReplacingLegacySamples() throws {
        let suite = "BatteryMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryMonitorMigrateTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_000_000)
        var samples: [BatteryTimeEstimator.Sample] = []
        for (index, percentage) in (19...95).enumerated() {
            samples.append(.init(date: start.addingTimeInterval(Double(index * 60)),
                                 percentage: Double(percentage), charging: true,
                                 target: 95, connectedToPower: true, segment: 1))
        }
        for (index, percentage) in stride(from: 95, through: 5, by: -1).enumerated() {
            samples.append(.init(date: start.addingTimeInterval(10_000 + Double(index * 120)),
                                 percentage: Double(percentage), charging: false,
                                 target: 0, connectedToPower: false, segment: 2))
        }
        let legacyData = try JSONEncoder().encode(samples)
        defaults.set(legacyData, forKey: "battery.timeEstimator.samples.v1")
        let monitor = BatteryMonitor(reader: FakeBatteryReader(result: makeReading(percentage: 19)),
                                     lowPowerModeProvider: { false },
                                     nowProvider: { start.addingTimeInterval(30_000) },
                                     defaults: defaults,
                                     sampleStoreDirectory: directory)

        XCTAssertNil(defaults.data(forKey: "battery.timeEstimator.samples.v1"))
        let migratedData = try Data(contentsOf: directory
            .appendingPathComponent("estimator-samples.json"))
        XCTAssertEqual(try JSONDecoder().decode([BatteryTimeEstimator.Sample].self,
                                                from: migratedData), samples)
        let profileData = try XCTUnwrap(defaults.data(forKey: BatteryTimeProfileStore.modelKey))
        let catalog = try JSONDecoder().decode(BatteryTimeProfileStore.Model.self, from: profileData).catalog
        XCTAssertEqual(Set(catalog.profiles.map(\.direction)), [.charging, .discharging])
        monitor.stop()
    }

    func testMonitorPublishesDeviceProfileAndRecordsLegacyShadow() async throws {
        let suite = "BatteryMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryMonitorShadowTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let start = Date(timeIntervalSince1970: 1_000_000)
        let now = start.addingTimeInterval(151 * 60)
        let samples = (0...75).map { index in
            BatteryTimeEstimator.Sample(
                date: start.addingTimeInterval(Double(index * 120)),
                percentage: Double(20 + index),
                charging: true,
                target: 95,
                connectedToPower: true,
                segment: 1
            )
        }
        defaults.set(try JSONEncoder().encode(samples), forKey: "battery.timeEstimator.samples.v1")
        let deviceProfile = BatteryTimeProfile(
            direction: .charging,
            targetPercent: 95,
            sessionStart: start,
            sessionEnd: now.addingTimeInterval(-30),
            sessionStartPercent: 20,
            sessionEndPercent: 95,
            bands: stride(from: 20, to: 95, by: 5)
                .map { .init(lowerPercent: $0, minutes: 5) }
        )
        let dischargeProfile = BatteryTimeProfile(
            direction: .discharging,
            targetPercent: 5,
            sessionStart: start,
            sessionEnd: now.addingTimeInterval(-30),
            sessionStartPercent: 95,
            sessionEndPercent: 5,
            bands: stride(from: 5, to: 95, by: 5)
                .map { .init(lowerPercent: $0, minutes: 2) }
        )
        let catalog = BatteryTimeProfileCatalog(profiles: [deviceProfile, dischargeProfile])
        BatteryTimeProfileStore(defaults: defaults).save(catalog)
        let recorder = BatteryTelemetryRecorder(directory: directory, powerReader: { _, _ in nil })
        let monitor = BatteryMonitor(
            reader: FakeBatteryReader(result: BatteryReading(
                currentCapacity: 30, maxCapacity: 100, isCharging: true,
                chargeLimit: 95, chargeLimitKnown: true,
                isConnectedToPower: true, isPresent: true
            )),
            lowPowerModeProvider: { false },
            nowProvider: { now },
            defaults: defaults,
            telemetryRecorder: recorder,
            sampleStoreDirectory: directory
        )
        monitor.refresh()
        var iterator = monitor.updates.makeAsyncIterator()
        let battery = await iterator.next()
        recorder.flush()

        XCTAssertEqual(battery?.timeToFullChargeMinutes, 65)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil).first)
        let line = try XCTUnwrap(Data(contentsOf: file).split(separator: 0x0A).first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let observation = try decoder.decode(BatteryTelemetryRecorder.Observation.self,
                                             from: Data(line))
        XCTAssertEqual(observation.profileEstimatorMinutes, 65)
        XCTAssertEqual(observation.legacyEstimatorMinutes, 130)
        XCTAssertEqual(observation.estimatorMinutes, 65)
        XCTAssertEqual(observation.selectedEstimatorSource, "deviceProfile")
        monitor.stop()
    }

    func testUnknownChargeLimitStaysDistinctFromConfirmedNoLimit() throws {
        let suite = "BatteryMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryMonitorUnknownLimitTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_000_000)
        let reader = FakeBatteryReader(result: BatteryReading(
            currentCapacity: 60, maxCapacity: 100, isCharging: true,
            isConnectedToPower: true, isPresent: true))
        let monitor = BatteryMonitor(reader: reader, lowPowerModeProvider: { false },
                                     nowProvider: { date }, defaults: defaults,
                                     sampleStoreDirectory: directory)
        monitor.refresh()
        let decoder = JSONDecoder()
        func storedSamples() throws -> [BatteryTimeEstimator.Sample] {
            let data = try Data(contentsOf: directory
                .appendingPathComponent("estimator-samples.json"))
            return try decoder.decode([BatteryTimeEstimator.Sample].self, from: data)
        }
        let unknown = try storedSamples()
        XCTAssertNil(unknown.last?.target)
        reader.result?.chargeLimitKnown = true
        let next = BatteryMonitor(reader: reader, lowPowerModeProvider: { false },
                                  nowProvider: { date.addingTimeInterval(60) },
                                  defaults: defaults, sampleStoreDirectory: directory)
        next.refresh()
        let confirmed = try storedSamples()
        XCTAssertEqual(confirmed.last?.target, 100)
        XCTAssertNotEqual(confirmed.first?.segment, confirmed.last?.segment)
        monitor.stop()
        next.stop()
    }
    func testConfiguredCeilingCountsAsFullOnlyOnPower() async {
        for connected in [false, true] {
            let monitor = BatteryMonitor(reader: FakeBatteryReader(result: BatteryReading(
                currentCapacity: 95, maxCapacity: 100, isCharging: false,
                chargeLimit: 95, isConnectedToPower: connected, isPresent: true)),
                lowPowerModeProvider: { false },
                sampleStoreDirectory: isolateSampleStore)
            monitor.refresh()
            var iterator = monitor.updates.makeAsyncIterator()
            let result = await iterator.next()
            XCTAssertEqual(result?.isCharged, connected)
            XCTAssertEqual(result?.percentage, 95)
            XCTAssertEqual(result?.chargeLimit, 95)
            XCTAssertNil(result?.timeToFullChargeMinutes)
            monitor.stop()
        }
    }

    func testChargeLimitNearTargetAndCalibrationAboveTarget() async {
        for (percentage, expectedCharged) in [(92, true), (100, false)] {
            let monitor = BatteryMonitor(reader: FakeBatteryReader(result: BatteryReading(
                currentCapacity: percentage, maxCapacity: 100, isCharging: false,
                chargeLimit: 95, isConnectedToPower: true, isPresent: true)),
                lowPowerModeProvider: { false },
                sampleStoreDirectory: isolateSampleStore)
            monitor.refresh()
            var iterator = monitor.updates.makeAsyncIterator()
            let result = await iterator.next()
            XCTAssertEqual(result?.isCharged, expectedCharged)
            monitor.stop()
        }
    }

    func testRemainingTimeIsPublishedOnlyWhileDischarging() async {
        for connected in [false, true] {
            let reader = FakeBatteryReader(result: BatteryReading(
                currentCapacity: 70, maxCapacity: 100, isCharging: false,
                remainingMinutes: 123, isConnectedToPower: connected, isPresent: true))
            let monitor = BatteryMonitor(reader: reader, lowPowerModeProvider: { false },
                                         sampleStoreDirectory: isolateSampleStore)
            monitor.refresh()
            var iterator = monitor.updates.makeAsyncIterator()
            let battery = await iterator.next()
            XCTAssertEqual(battery?.remainingMinutes, connected ? nil : 123)
            monitor.stop()
        }
    }

    func testParserReadsMinutesToEmptyWithoutCapacityArithmetic() {
        let reading = IOPSBatteryReader.parse([
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSCurrentCapacityKey: 70, kIOPSMaxCapacityKey: 100,
            kIOPSTimeToEmptyKey: 123
        ])
        XCTAssertEqual(reading?.remainingMinutes, 123)
    }

    func testParserRejectsBooleanFractionalAndInfiniteTimeEstimates() {
        for invalid: Any in [true, 1.5, Double.infinity, Double.nan, -1, 0] {
            let description: [String: Any] = [
                kIOPSTypeKey: kIOPSInternalBatteryType,
                kIOPSCurrentCapacityKey: 68, kIOPSMaxCapacityKey: 100,
                kIOPSIsChargingKey: true,
                kIOPSTimeToFullChargeKey: invalid
            ]
            XCTAssertNil(IOPSBatteryReader.parse(description)?.timeToFullChargeMinutes)
        }
    }

    func testParserConvertsValidInternalBatteryDescription() {
        let description: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSCurrentCapacityKey: 73,
            kIOPSMaxCapacityKey: 100,
            kIOPSIsChargingKey: true,
            kIOPSPowerSourceStateKey: kIOPSACPowerValue,
            kIOPSIsPresentKey: true
        ]

        XCTAssertEqual(
            IOPSBatteryReader.parse(description),
            BatteryReading(
                currentCapacity: 73,
                maxCapacity: 100,
                isCharging: true,
                isConnectedToPower: true,
                isPresent: true
            )
        )
    }

    func testParserReadsChargedStateAndTimeToFullCharge() {
        let description: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSCurrentCapacityKey: 68,
            kIOPSMaxCapacityKey: 100,
            kIOPSIsChargingKey: true,
            kIOPSIsChargedKey: false,
            kIOPSTimeToFullChargeKey: 85,
            kIOPSPowerSourceStateKey: kIOPSACPowerValue,
            kIOPSIsPresentKey: true
        ]

        XCTAssertEqual(
            IOPSBatteryReader.parse(description),
            BatteryReading(
                currentCapacity: 68,
                maxCapacity: 100,
                isCharging: true,
                isCharged: false,
                timeToFullChargeMinutes: 85,
                isConnectedToPower: true,
                isPresent: true
            )
        )
    }

    func testParserTreatsMissingAndNonPositiveTimeToFullAsUnknown() {
        for time in [nil, 0, -1] as [Int?] {
            var description: [String: Any] = [
                kIOPSTypeKey: kIOPSInternalBatteryType,
                kIOPSCurrentCapacityKey: 68,
                kIOPSMaxCapacityKey: 100,
                kIOPSIsChargingKey: true,
                kIOPSIsChargedKey: false,
                kIOPSPowerSourceStateKey: kIOPSACPowerValue,
                kIOPSIsPresentKey: true
            ]
            description[kIOPSTimeToFullChargeKey] = time

            XCTAssertNil(IOPSBatteryReader.parse(description)?.timeToFullChargeMinutes)
        }
    }

    func testMonitorOnlyEmitsTimeWhileCharging() async {
        let reader = FakeBatteryReader(result: BatteryReading(
            currentCapacity: 68,
            maxCapacity: 100,
            isCharging: false,
            isCharged: true,
            timeToFullChargeMinutes: 85,
            isConnectedToPower: true,
            isPresent: true
        ))
        let monitor = BatteryMonitor(
            reader: reader,
            lowPowerModeProvider: { false },
            sampleStoreDirectory: isolateSampleStore
        )

        monitor.refresh()
        var iterator = monitor.updates.makeAsyncIterator()
        let value = await iterator.next()

        XCTAssertTrue(value?.isCharged == true)
        XCTAssertNil(value?.timeToFullChargeMinutes)
        monitor.stop()
    }

    func testParserRejectsInvalidInternalBatteryDescription() {
        let description: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSCurrentCapacityKey: "73",
            kIOPSMaxCapacityKey: 100
        ]

        XCTAssertNil(IOPSBatteryReader.parse(description))
    }

    func testParserRejectsNonBatteryDescription() {
        let description: [String: Any] = [
            kIOPSTypeKey: "UPS",
            kIOPSCurrentCapacityKey: 73,
            kIOPSMaxCapacityKey: 100
        ]

        XCTAssertNil(IOPSBatteryReader.parse(description))
    }

    func testMonitorConvertsReaderOutput() async {
        let reader = FakeBatteryReader(result: BatteryReading(
            currentCapacity: 2,
            maxCapacity: 3,
            isCharging: true,
            isConnectedToPower: true,
            isPresent: true
        ))
        let monitor = BatteryMonitor(
            reader: reader,
            lowPowerModeProvider: { true },
            sampleStoreDirectory: isolateSampleStore
        )

        monitor.refresh()
        var iterator = monitor.updates.makeAsyncIterator()
        let value = await iterator.next()

        XCTAssertEqual(value?.percentage, 67)
        XCTAssertTrue(value?.isCharging == true)
        XCTAssertTrue(value?.isConnectedToPower == true)
        XCTAssertTrue(value?.isLowPowerMode == true)
        monitor.stop()
    }

    func testMissingReaderResultUsesFullValue() async {
        let monitor = BatteryMonitor(
            reader: FakeBatteryReader(result: nil),
            lowPowerModeProvider: { false },
            sampleStoreDirectory: isolateSampleStore
        )

        monitor.refresh()
        var iterator = monitor.updates.makeAsyncIterator()
        let value = await iterator.next()

        XCTAssertTrue(value?.isPresent == false)
        XCTAssertEqual(value?.percentage, 100)
        XCTAssertFalse(value?.isCharging == true)
        XCTAssertFalse(value?.isConnectedToPower == true)
        monitor.stop()
    }

    func testNonPresentReadingUsesFullValue() async {
        let monitor = BatteryMonitor(
            reader: FakeBatteryReader(result: BatteryReading(
                currentCapacity: 42,
                maxCapacity: 100,
                isCharging: true,
                isConnectedToPower: true,
                isPresent: false
            )),
            lowPowerModeProvider: { false },
            sampleStoreDirectory: isolateSampleStore
        )

        monitor.refresh()
        var iterator = monitor.updates.makeAsyncIterator()
        let value = await iterator.next()

        XCTAssertTrue(value?.isPresent == false)
        XCTAssertEqual(value?.percentage, 100)
        XCTAssertFalse(value?.isCharging == true)
        XCTAssertFalse(value?.isConnectedToPower == true)
        monitor.stop()
    }

    func testZeroMaxCapacityFallsBackToCurrentCapacity() async {
        let monitor = BatteryMonitor(
            reader: FakeBatteryReader(result: BatteryReading(
                currentCapacity: 73,
                maxCapacity: 0,
                isCharging: false,
                isConnectedToPower: false,
                isPresent: true
            )),
            lowPowerModeProvider: { false },
            sampleStoreDirectory: isolateSampleStore
        )

        monitor.refresh()
        var iterator = monitor.updates.makeAsyncIterator()
        let value = await iterator.next()

        XCTAssertEqual(value?.percentage, 73)
        monitor.stop()
    }

    func testStartImmediatelyEmitsCurrentReading() async {
        let monitor = BatteryMonitor(
            reader: FakeBatteryReader(result: BatteryReading(
                currentCapacity: 81,
                maxCapacity: 100,
                isCharging: false,
                isConnectedToPower: false,
                isPresent: true
            )),
            lowPowerModeProvider: { false },
            sampleStoreDirectory: isolateSampleStore,
            iopsRunLoopSourceFactory: { _, _ in nil }
        )

        monitor.start()
        var iterator = monitor.updates.makeAsyncIterator()
        let value = await iterator.next()

        XCTAssertEqual(value?.percentage, 81)
        monitor.stop()
    }

    func testNilIOPSNotificationSourceStillRefreshesAndStops() async {
        let reader = FakeBatteryReader(result: makeReading(percentage: 64))
        let monitor = BatteryMonitor(
            reader: reader,
            lowPowerModeProvider: { false },
            sampleStoreDirectory: isolateSampleStore,
            iopsRunLoopSourceFactory: { _, _ in nil }
        )

        monitor.start()
        var iterator = monitor.updates.makeAsyncIterator()
        let value = await iterator.next()

        XCTAssertEqual(value?.percentage, 64)
        XCTAssertEqual(reader.readCount, 1)

        monitor.stop()
        let stoppedValue = await iterator.next()

        XCTAssertNil(stoppedValue)
        XCTAssertEqual(reader.readCount, 1)
    }

    func testRecoverReinstallsNotificationsAndKeepsStreamAlive() async {
        let reader = FakeBatteryReader(result: makeReading(percentage: 50))
        let harness = IOPSNotificationSourceHarness()
        defer { harness.releaseRetainedContexts() }
        let monitor = BatteryMonitor(
            reader: reader,
            lowPowerModeProvider: { false },
            sampleStoreDirectory: isolateSampleStore,
            iopsRunLoopSourceFactory: harness.factory
        )

        monitor.start()
        var iterator = monitor.updates.makeAsyncIterator()
        _ = await iterator.next()

        monitor.recover()

        XCTAssertEqual(harness.factoryInvocationCount, 2)
        XCTAssertNotNil(harness.contextPointer)
        XCTAssertNotNil(harness.callback)
        XCTAssertTrue(CFRunLoopContainsSource(CFRunLoopGetMain(), harness.source, .defaultMode))

        reader.result = makeReading(percentage: 60)
        harness.invokeCallback()
        let callbackValue = await iterator.next()
        XCTAssertEqual(callbackValue?.percentage, 60)

        let lowPowerStateRead = expectation(description: "low power state read")
        lowPowerStateRead.assertForOverFulfill = true
        reader.onReadCount = { count in
            if count == 3 {
                lowPowerStateRead.fulfill()
            }
        }
        NotificationCenter.default.post(
            name: .NSProcessInfoPowerStateDidChange,
            object: nil
        )
        await fulfillment(of: [lowPowerStateRead], timeout: 1)

        XCTAssertEqual(reader.readCount, 3)
        monitor.stop()
    }

    func testStartAndStopAreIdempotent() {
        let reader = FakeBatteryReader(result: makeReading(percentage: 50))
        let harness = IOPSNotificationSourceHarness()
        defer { harness.releaseRetainedContexts() }
        let monitor = BatteryMonitor(
            reader: reader,
            lowPowerModeProvider: { false },
            sampleStoreDirectory: isolateSampleStore,
            iopsRunLoopSourceFactory: harness.factory
        )

        monitor.start()
        monitor.start()

        XCTAssertEqual(harness.factoryInvocationCount, 1)
        XCTAssertEqual(reader.readCount, 1)
        XCTAssertTrue(CFRunLoopContainsSource(CFRunLoopGetMain(), harness.source, .defaultMode))

        monitor.stop()
        monitor.stop()

        XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), harness.source, .defaultMode))
        XCTAssertEqual(reader.readCount, 1)
    }

    func testIOPSNotificationCallbackRefreshesUntilStopped() async {
        let reader = FakeBatteryReader(result: makeReading(percentage: 50))
        let harness = IOPSNotificationSourceHarness()
        defer { harness.releaseRetainedContexts() }
        let monitor = BatteryMonitor(
            reader: reader,
            lowPowerModeProvider: { false },
            sampleStoreDirectory: isolateSampleStore,
            iopsRunLoopSourceFactory: harness.factory
        )

        var iterator = monitor.updates.makeAsyncIterator()
        monitor.start()

        XCTAssertNotNil(harness.contextPointer)
        XCTAssertNotNil(harness.callback)
        XCTAssertTrue(CFRunLoopContainsSource(CFRunLoopGetMain(), harness.source, .defaultMode))
        let immediateValue = await iterator.next()
        XCTAssertEqual(immediateValue?.percentage, 50)
        XCTAssertEqual(reader.readCount, 1)

        reader.result = makeReading(percentage: 60)
        harness.invokeCallback()
        let callbackValue = await iterator.next()
        XCTAssertEqual(callbackValue?.percentage, 60)
        XCTAssertEqual(reader.readCount, 2)

        monitor.stop()

        XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), harness.source, .defaultMode))
        let stoppedValue = await iterator.next()
        XCTAssertNil(stoppedValue)

        reader.result = makeReading(percentage: 70)
        harness.invokeCallback()
        await drainMainActorTasks()

        XCTAssertEqual(reader.readCount, 2)
        let postStopValue = await iterator.next()
        XCTAssertNil(postStopValue)
    }

    func testPowerStateNotificationRefreshesUntilStopped() async {
        let reader = FakeBatteryReader(result: makeReading(percentage: 50))
        let monitor = BatteryMonitor(
            reader: reader,
            lowPowerModeProvider: { false },
            sampleStoreDirectory: isolateSampleStore,
            iopsRunLoopSourceFactory: { _, _ in nil }
        )

        monitor.start()
        XCTAssertEqual(reader.readCount, 1)

        let powerStateRead = expectation(description: "power state read")
        powerStateRead.assertForOverFulfill = true
        reader.onReadCount = { count in
            if count == 2 {
                powerStateRead.fulfill()
            }
        }
        NotificationCenter.default.post(
            name: .NSProcessInfoPowerStateDidChange,
            object: nil
        )
        await fulfillment(of: [powerStateRead], timeout: 1)

        monitor.stop()
        NotificationCenter.default.post(
            name: .NSProcessInfoPowerStateDidChange,
            object: nil
        )
        await drainMainActorTasks()

        XCTAssertEqual(reader.readCount, 2)
    }

    func testRefreshAfterStopDoesNotReadOrEmitAnotherUpdate() async {
        let reader = FakeBatteryReader(result: makeReading(percentage: 50))
        let monitor = BatteryMonitor(
            reader: reader,
            lowPowerModeProvider: { false },
            sampleStoreDirectory: isolateSampleStore,
            iopsRunLoopSourceFactory: { _, _ in nil }
        )

        monitor.start()
        var iterator = monitor.updates.makeAsyncIterator()
        _ = await iterator.next()

        monitor.stop()
        monitor.refresh()

        let stoppedValue = await iterator.next()
        XCTAssertNil(stoppedValue)
        XCTAssertEqual(reader.readCount, 1)
    }

    func testStartAfterStopDoesNotRestart() {
        let reader = FakeBatteryReader(result: makeReading(percentage: 50))
        let harness = IOPSNotificationSourceHarness()
        defer { harness.releaseRetainedContexts() }
        let monitor = BatteryMonitor(
            reader: reader,
            lowPowerModeProvider: { false },
            sampleStoreDirectory: isolateSampleStore,
            iopsRunLoopSourceFactory: harness.factory
        )

        monitor.stop()
        monitor.start()

        XCTAssertEqual(harness.factoryInvocationCount, 0)
        XCTAssertEqual(reader.readCount, 0)
    }

    func testRecoverAfterStopDoesNotReinstallOrEmit() async {
        let reader = FakeBatteryReader(result: makeReading(percentage: 50))
        let harness = IOPSNotificationSourceHarness()
        defer { harness.releaseRetainedContexts() }
        let monitor = BatteryMonitor(
            reader: reader,
            lowPowerModeProvider: { false },
            sampleStoreDirectory: isolateSampleStore,
            iopsRunLoopSourceFactory: harness.factory
        )

        monitor.start()
        var iterator = monitor.updates.makeAsyncIterator()
        _ = await iterator.next()
        monitor.stop()

        monitor.recover()

        XCTAssertEqual(harness.factoryInvocationCount, 1)
        XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), harness.source, .defaultMode))
        XCTAssertEqual(reader.readCount, 1)
        let finalValue = await iterator.next()
        XCTAssertNil(finalValue)
    }

    func testDeinitRemovesSourceWhenStopWasNotCalled() {
        let harness = IOPSNotificationSourceHarness()
        defer { harness.releaseRetainedContexts() }
        weak var weakMonitor: BatteryMonitor?

        do {
            let monitor = BatteryMonitor(
                reader: FakeBatteryReader(result: makeReading(percentage: 50)),
                lowPowerModeProvider: { false },
                sampleStoreDirectory: isolateSampleStore,
                iopsRunLoopSourceFactory: harness.factory
            )
            weakMonitor = monitor

            monitor.start()
            XCTAssertTrue(CFRunLoopContainsSource(CFRunLoopGetMain(), harness.source, .defaultMode))
        }

        XCTAssertNil(weakMonitor)
        XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), harness.source, .defaultMode))
    }

    private func makeReading(percentage: Int) -> BatteryReading {
        BatteryReading(
            currentCapacity: percentage,
            maxCapacity: 100,
            isCharging: false,
            isConnectedToPower: false,
            isPresent: true
        )
    }

    private func drainMainActorTasks() async {
        await Task { @MainActor in }.value
    }
}

private final class FakeBatteryReader: BatteryReadingProviding {
    var result: BatteryReading?
    private(set) var readCount = 0
    var onReadCount: ((Int) -> Void)?

    init(result: BatteryReading?) {
        self.result = result
    }

    func read() -> BatteryReading? {
        readCount += 1
        onReadCount?(readCount)
        return result
    }
}

private final class IOPSNotificationSourceHarness {
    let source: CFRunLoopSource
    private(set) var callback: IOPSNotificationCallback?
    private(set) var contextPointer: UnsafeMutableRawPointer?
    private(set) var factoryInvocationCount = 0
    private var retainedContexts: [Unmanaged<AnyObject>] = []

    init() {
        var sourceContext = CFRunLoopSourceContext(
            version: 0,
            info: nil,
            retain: nil,
            release: nil,
            copyDescription: nil,
            equal: nil,
            hash: nil,
            schedule: nil,
            cancel: nil,
            perform: nil
        )
        source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &sourceContext)!
    }

    var factory: IOPSRunLoopSourceFactory {
        { [self] contextPointer, callback in
            factoryInvocationCount += 1
            self.contextPointer = contextPointer
            self.callback = callback
            if let contextPointer {
                retainedContexts.append(
                    Unmanaged<AnyObject>
                        .fromOpaque(contextPointer)
                        .retain()
                )
            }
            return source
        }
    }

    func invokeCallback() {
        callback?(contextPointer)
    }

    func releaseRetainedContexts() {
        retainedContexts.forEach { $0.release() }
        retainedContexts.removeAll()
    }
}
