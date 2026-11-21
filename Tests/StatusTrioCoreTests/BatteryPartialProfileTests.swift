import XCTest
@testable import StatusTrioCore

final class BatteryPartialProfileTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testPartialChargeSessionProducesBandsBelowTheTerminalTaper() throws {
        let samples = makeSamples(
            Array(40...80).map(Double.init), step: 60,
            charging: true, target: 95, segment: 1
        )

        let profiles = BatteryTimeProfileBuilder.partialChargeProfiles(from: samples)

        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.direction, .charging)
        XCTAssertEqual(profile.targetPercent, 95)
        XCTAssertEqual(profile.sessionStartPercent, 40)
        XCTAssertEqual(profile.sessionEndPercent, 80)
        XCTAssertFalse(profile.isComplete)
        XCTAssertEqual(profile.bands.map(\.lowerPercent), Array(stride(from: 40, through: 75, by: 5)))
        XCTAssertFalse(profile.bands.contains { $0.lowerPercent == 90 })
    }

    func testAChargeThatReachesNinetyFiveIsNotAlsoRecordedAsPartial() {
        let samples = makeSamples(
            Array(40...95).map(Double.init), step: 60,
            charging: true, target: 95, segment: 1
        )

        XCTAssertTrue(BatteryTimeProfileBuilder.partialChargeProfiles(from: samples).isEmpty)
    }

    func testPartialChargeNearNinetyDoesNotLearnTheTerminalBand() throws {
        let samples = makeSamples(
            Array(80...94).map(Double.init), step: 60,
            charging: true, target: 95, segment: 1
        )

        let profile = try XCTUnwrap(
            BatteryTimeProfileBuilder.partialChargeProfiles(from: samples).first
        )

        XCTAssertEqual(profile.bands.map(\.lowerPercent), [80, 85])
        XCTAssertFalse(profile.bands.contains { $0.lowerPercent == 90 })
    }

    func testPartialDischargeSessionProducesBandsWithoutReachingReserve() throws {
        let samples = makeSamples(
            Array(stride(from: 80, through: 55, by: -1)).map(Double.init), step: 120,
            charging: false, target: 0, segment: 2
        )

        let profile = try XCTUnwrap(
            BatteryTimeProfileBuilder.partialDischargeProfiles(from: samples).first
        )

        XCTAssertEqual(profile.direction, .discharging)
        XCTAssertEqual(profile.targetPercent, 5)
        XCTAssertEqual(profile.sessionStartPercent, 80)
        XCTAssertEqual(profile.sessionEndPercent, 55)
        XCTAssertFalse(profile.isComplete)
        XCTAssertEqual(profile.bands.map(\.lowerPercent), [55, 60, 65, 70, 75])
    }

    func testPartialMergeReplacesAnExtendedSessionAndKeepsOneCurve() {
        let first = partialProfile(
            direction: .discharging, target: 5, startPercent: 80, endPercent: 60,
            bands: [60, 65, 70, 75], sessionStart: start,
            date: start.addingTimeInterval(1_000)
        )
        let extended = partialProfile(
            direction: .discharging, target: 5, startPercent: 80, endPercent: 50,
            bands: [50, 55, 60, 65, 70, 75], sessionStart: start,
            date: start.addingTimeInterval(2_000)
        )
        var catalog = BatteryTimeProfileCatalog()

        XCTAssertTrue(catalog.mergePartialProfiles([first], now: start.addingTimeInterval(3_000)))
        XCTAssertTrue(catalog.mergePartialProfiles([extended], now: start.addingTimeInterval(3_000)))

        XCTAssertEqual(catalog.profiles.count, 1)
        XCTAssertEqual(catalog.profiles[0].sessionEndPercent, 50)
    }

    func testPartialMergeDoesNotOverrideACompleteSession() throws {
        let complete = BatteryTimeProfile(
            direction: .discharging, targetPercent: 5,
            sessionStart: start, sessionEnd: start.addingTimeInterval(10_000),
            sessionStartPercent: 95, sessionEndPercent: 5,
            bands: stride(from: 5, through: 90, by: 5).map {
                .init(lowerPercent: $0, minutes: 10)
            }
        )
        let partial = partialProfile(
            direction: .discharging, target: 5, startPercent: 95, endPercent: 80,
            bands: [80, 85, 90], sessionStart: start,
            date: start.addingTimeInterval(5_000)
        )
        var catalog = BatteryTimeProfileCatalog()
        XCTAssertTrue(catalog.addIfNewer(complete, now: start.addingTimeInterval(20_000)))

        XCTAssertFalse(catalog.mergePartialProfiles([partial], now: start.addingTimeInterval(20_000)))
        XCTAssertEqual(catalog.profiles.count, 1)
        XCTAssertTrue(try XCTUnwrap(catalog.profiles.first).isComplete)
    }

    func testMinutesPerBandBlendsPartialAndCompleteForDischarge() throws {
        let complete = BatteryTimeProfile(
            direction: .discharging, targetPercent: 5,
            sessionStart: start, sessionEnd: start.addingTimeInterval(10_000),
            sessionStartPercent: 95, sessionEndPercent: 5,
            bands: [.init(lowerPercent: 50, minutes: 10)]
        )
        let partial = partialProfile(
            direction: .discharging, target: 5, startPercent: 80, endPercent: 40,
            bands: [50], minutes: 4, date: start.addingTimeInterval(11_000)
        )
        let catalog = BatteryTimeProfileCatalog(profiles: [complete, partial])

        XCTAssertEqual(
            try XCTUnwrap(catalog.minutesPerBand(
                direction: .discharging, targetPercent: 5,
                lowerPercent: 50, now: start.addingTimeInterval(12_000)
            )),
            8,
            accuracy: 0.001
        )
    }

    func testMorePartialSessionsShiftTheDischargeMedianGradually() throws {
        let complete = BatteryTimeProfile(
            direction: .discharging, targetPercent: 5,
            sessionStart: start, sessionEnd: start.addingTimeInterval(10_000),
            sessionStartPercent: 95, sessionEndPercent: 5,
            bands: [.init(lowerPercent: 50, minutes: 10)]
        )
        let partials = (0..<6).map { index in
            partialProfile(
                direction: .discharging, target: 5, startPercent: 80, endPercent: 40,
                bands: [50], minutes: 4,
                date: start.addingTimeInterval(10_100 + Double(index * 10))
            )
        }
        let catalog = BatteryTimeProfileCatalog(profiles: [complete] + partials)

        XCTAssertEqual(
            try XCTUnwrap(catalog.minutesPerBand(
                direction: .discharging, targetPercent: 5,
                lowerPercent: 50, now: start.addingTimeInterval(12_000)
            )),
            5.5,
            accuracy: 0.001
        )
    }

    func testChargingTerminalBandStaysCompleteOnly() throws {
        let complete = BatteryTimeProfile(
            direction: .charging, targetPercent: 95,
            sessionStart: start, sessionEnd: start.addingTimeInterval(10_000),
            sessionStartPercent: 40, sessionEndPercent: 95,
            bands: [.init(lowerPercent: 90, minutes: 10),
                    .init(lowerPercent: 50, minutes: 5)]
        )
        let partials = (0..<6).map { index in
            partialProfile(
                direction: .charging, target: 95, startPercent: 40, endPercent: 80,
                bands: [50, 90], minutes: 3,
                date: start.addingTimeInterval(10_100 + Double(index * 10))
            )
        }
        let catalog = BatteryTimeProfileCatalog(profiles: [complete] + partials)
        let now = start.addingTimeInterval(12_000)

        XCTAssertEqual(
            catalog.minutesPerBand(direction: .charging, targetPercent: 95,
                                   lowerPercent: 90, now: now),
            10
        )
        XCTAssertEqual(
            try XCTUnwrap(catalog.minutesPerBand(
                direction: .charging, targetPercent: 95,
                lowerPercent: 50, now: now
            )),
            4.25,
            accuracy: 0.001
        )
    }

    func testPartialProfilesAloneDoNotActivateTheModel() {
        let charge = partialProfile(
            direction: .charging, target: 95, startPercent: 40, endPercent: 80,
            bands: [50], date: start.addingTimeInterval(1_000)
        )
        let discharge = partialProfile(
            direction: .discharging, target: 5, startPercent: 80, endPercent: 50,
            bands: [50], date: start.addingTimeInterval(2_000)
        )
        let catalog = BatteryTimeProfileCatalog(profiles: [charge, discharge])
        let now = start.addingTimeInterval(3_000)

        XCTAssertFalse(catalog.hasProfile(direction: .charging, targetPercent: 95, now: now))
        XCTAssertFalse(catalog.hasProfile(direction: .discharging, targetPercent: 5, now: now))
        XCTAssertFalse(catalog.hasBidirectionalProfiles(now: now))
    }

    func testCompleteProfilesActivateOnlyAfterBothDirectionsExist() {
        let charge = BatteryTimeProfile(
            direction: .charging, targetPercent: 95,
            sessionStart: start, sessionEnd: start.addingTimeInterval(1_000),
            sessionStartPercent: 40, sessionEndPercent: 95,
            bands: [.init(lowerPercent: 50, minutes: 5)]
        )
        let discharge = BatteryTimeProfile(
            direction: .discharging, targetPercent: 5,
            sessionStart: start, sessionEnd: start.addingTimeInterval(2_000),
            sessionStartPercent: 95, sessionEndPercent: 5,
            bands: [.init(lowerPercent: 50, minutes: 10)]
        )
        var catalog = BatteryTimeProfileCatalog()
        let now = start.addingTimeInterval(3_000)

        XCTAssertTrue(catalog.addIfNewer(charge, now: now))
        XCTAssertFalse(catalog.hasBidirectionalProfiles(now: now))
        XCTAssertTrue(catalog.addIfNewer(discharge, now: now))
        XCTAssertTrue(catalog.hasBidirectionalProfiles(now: now))
    }

    private func makeSamples(_ percentages: [Double], step: TimeInterval,
                            charging: Bool, target: Double, segment: Int)
        -> [BatteryTimeEstimator.Sample] {
        percentages.enumerated().map { index, percentage in
            BatteryTimeEstimator.Sample(
                date: start.addingTimeInterval(Double(index) * step),
                percentage: percentage,
                charging: charging,
                target: target,
                connectedToPower: charging,
                segment: segment
            )
        }
    }

    private func partialProfile(direction: BatteryTimeProfile.Direction,
                                target: Int, startPercent: Double, endPercent: Double,
                                bands: [Int], minutes: Double = 5,
                                sessionStart: Date? = nil, date: Date)
        -> BatteryTimeProfile {
        BatteryTimeProfile(
            direction: direction, targetPercent: target,
            sessionStart: sessionStart ?? date.addingTimeInterval(-600),
            sessionEnd: date,
            sessionStartPercent: startPercent,
            sessionEndPercent: endPercent,
            bands: bands.sorted().map { .init(lowerPercent: $0, minutes: minutes) }
        )
    }
}
