import XCTest
@testable import StatusTrioCore

final class BatteryTimeProfileTests: XCTestCase {
    func testLatestCompleteChargeProfileUsesOnlyMeasuredContinuousBands() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var samples = makeSamples(19...50, start: start, offsetMinutes: 0,
                              charging: true, target: 95, connected: true, segment: 1)
        samples.append(.init(date: start.addingTimeInterval(31 * 60 + 20),
                             percentage: 50, charging: false, target: nil,
                             connectedToPower: true, segment: 2))
        samples += makeSamples(51...83, start: start, offsetMinutes: 32,
                           charging: true, target: 95, connected: true, segment: 3)
        samples.append(.init(date: start.addingTimeInterval(64 * 60 + 20),
                             percentage: 83, charging: false, target: nil,
                             connectedToPower: true, segment: 4))
        samples += makeSamples(84...93, start: start, offsetMinutes: 65,
                               charging: true, target: 95, connected: true, segment: 5)
        samples.append(.init(date: start.addingTimeInterval(75 * 60), percentage: 94,
                             charging: true, target: 95, connectedToPower: true,
                             segment: 5, source: .thermal))
        samples += makeSamples(94...95, start: start, offsetMinutes: 76,
                               charging: true, target: 95, connected: true, segment: 6)

        let profile = try XCTUnwrap(BatteryTimeProfileBuilder.latestCompleteProfile(
            from: samples,
            direction: .charging,
            targetPercent: 95
        ))

        XCTAssertEqual(profile.sessionStartPercent, 19)
        XCTAssertEqual(profile.sessionEndPercent, 95)
        let catalog = BatteryTimeProfileCatalog(profiles: [profile])
        XCTAssertNotNil(catalog.minutesPerBand(direction: .charging, targetPercent: 95,
                                               lowerPercent: 20, now: profile.sessionEnd))
        XCTAssertNil(catalog.minutesPerBand(direction: .charging, targetPercent: 95,
                                            lowerPercent: 50, now: profile.sessionEnd),
                     "The 50–55% band crosses a mixed-power segment.")
        XCTAssertNotNil(catalog.minutesPerBand(direction: .charging, targetPercent: 95,
                                               lowerPercent: 85, now: profile.sessionEnd))
        XCTAssertNil(catalog.minutesPerBand(direction: .charging, targetPercent: 95,
                                            lowerPercent: 90, now: profile.sessionEnd),
                     "Thermal samples must not train a band.")
    }

    func testPartialSessionsDoNotReplaceTheCompletedProfile() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let samples = makeSamples(16...92, start: start, offsetMinutes: 0,
                              charging: true, target: 95, connected: true, segment: 1)

        XCTAssertNil(BatteryTimeProfileBuilder.latestCompleteProfile(
            from: samples,
            direction: .charging,
            targetPercent: 95
        ))
    }

    func testChargeLimitReportedAsIdleCompletesTheFinalBandWhenContinuous() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var samples = makeSamples(19...94, start: start, offsetMinutes: 0,
                                  charging: true, target: 95, connected: true, segment: 1)
        samples.append(.init(date: start.addingTimeInterval(76 * 60), percentage: 95,
                             charging: false, target: nil, connectedToPower: true, segment: 2))

        let profile = try XCTUnwrap(BatteryTimeProfileBuilder.latestCompleteProfile(
            from: samples, direction: .charging, targetPercent: 95
        ))

        XCTAssertEqual(profile.sessionEndPercent, 95)
        let finalBandMinutes = try XCTUnwrap(BatteryTimeProfileCatalog(profiles: [profile]).minutesPerBand(
            direction: .charging, targetPercent: 95, lowerPercent: 90, now: profile.sessionEnd
        ))
        XCTAssertEqual(finalBandMinutes, 5, accuracy: 0.001)
    }

    func testIdleChargeTerminalDoesNotTrainAcrossUntrustedTransitions() {
        let start = Date(timeIntervalSince1970: 1_000)
        let invalidEndpoints: [(String, TimeInterval, Bool, BatteryTimeEstimator.Sample.Source)] = [
            ("long gap", 79 * 60, true, .iops),
            ("disconnected", 76 * 60, false, .iops),
            ("thermal terminal", 76 * 60, true, .thermal),
            ("legacy terminal", 76 * 60, true, .legacy)
        ]

        for (name, offset, connected, source) in invalidEndpoints {
            var samples = makeSamples(19...94, start: start, offsetMinutes: 0,
                                      charging: true, target: 95, connected: true, segment: 1)
            samples.append(.init(date: start.addingTimeInterval(offset), percentage: 95,
                                 charging: false, target: nil, connectedToPower: connected,
                                 segment: 2, source: source))
            let profile = BatteryTimeProfileBuilder.latestCompleteProfile(
                from: samples, direction: .charging, targetPercent: 95
            )

            XCTAssertNil(profile?.bands.first(where: { $0.lowerPercent == 90 }), name)
        }

        var reversed = makeSamples(19...94, start: start, offsetMinutes: 0,
                                   charging: true, target: 95, connected: true, segment: 1)
        reversed.append(.init(date: start.addingTimeInterval(75.5 * 60), percentage: 93,
                              charging: true, target: 95, connectedToPower: true, segment: 2))
        reversed.append(.init(date: start.addingTimeInterval(76 * 60), percentage: 95,
                              charging: false, target: nil, connectedToPower: true, segment: 3))
        let reversedProfile = BatteryTimeProfileBuilder.latestCompleteProfile(
            from: reversed, direction: .charging, targetPercent: 95
        )
        XCTAssertNil(reversedProfile?.bands.first(where: { $0.lowerPercent == 90 }),
                     "A capacity reversal must not be bridged to the terminal reading.")

        var changedTarget = makeSamples(19...89, start: start, offsetMinutes: 0,
                                        charging: true, target: 95, connected: true, segment: 1)
        changedTarget.append(.init(date: start.addingTimeInterval(71 * 60), percentage: 89,
                                   charging: true, target: 80, connectedToPower: true, segment: 2))
        changedTarget.append(.init(date: start.addingTimeInterval(72 * 60), percentage: 95,
                                   charging: false, target: nil, connectedToPower: true, segment: 3))
        let changedTargetProfile = BatteryTimeProfileBuilder.latestCompleteProfile(
            from: changedTarget, direction: .charging, targetPercent: 95
        )
        XCTAssertNil(changedTargetProfile?.bands.first(where: { $0.lowerPercent == 90 }),
                     "A charge-target change must not be bridged into the terminal band.")
    }

    func testThermalTaggedChargingSamplesKeepTheTerminalBandOutOfTheProfile() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let activeSamples = makeSamples(19...94, start: start, offsetMinutes: 0,
                                        charging: true, target: 95, connected: true, segment: 1)
        var samples = activeSamples.map { sample -> BatteryTimeEstimator.Sample in
            guard sample.percentage == 93 || sample.percentage == 94 else { return sample }
            return BatteryTimeEstimator.Sample(
                date: sample.date, percentage: sample.percentage, charging: true,
                target: 95, connectedToPower: true, segment: sample.segment, source: .thermal
            )
        }
        samples.append(.init(date: start.addingTimeInterval(76 * 60), percentage: 95,
                             charging: false, target: nil, connectedToPower: true, segment: 2))

        let profile = try XCTUnwrap(BatteryTimeProfileBuilder.latestCompleteProfile(
            from: samples, direction: .charging, targetPercent: 95
        ))

        XCTAssertNil(profile.bands.first(where: { $0.lowerPercent == 90 }),
                     "Thermal-tagged capacity samples must not train the terminal band.")
    }

    func testReserveReportedAsPluggedIdleCompletesDischargeWithoutBridgingTheTransition() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var samples = stride(from: 95, through: 6, by: -1).enumerated().map { index, percentage in
            BatteryTimeEstimator.Sample(
                date: start.addingTimeInterval(Double(index) * 120),
                percentage: Double(percentage), charging: false, target: 0,
                connectedToPower: false, segment: 1
            )
        }
        samples.append(.init(date: start.addingTimeInterval(180 * 60), percentage: 5,
                             charging: false, target: nil, connectedToPower: true, segment: 2))

        let profile = try XCTUnwrap(BatteryTimeProfileBuilder.latestCompleteProfile(
            from: samples, direction: .discharging, targetPercent: 5
        ))

        XCTAssertEqual(profile.sessionEndPercent, 5)
        XCTAssertNil(BatteryTimeProfileCatalog(profiles: [profile]).minutesPerBand(
            direction: .discharging, targetPercent: 5, lowerPercent: 5, now: profile.sessionEnd
        ), "The power transition cannot train the 5–10% band.")
    }

    func testContinuousRateResetCanCompleteABandWithoutCrossingSleepOrPowerState() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let firstSegment = stride(from: 95, through: 10, by: -1).enumerated().map { index, percentage in
            BatteryTimeEstimator.Sample(
                date: start.addingTimeInterval(Double(index) * 60),
                percentage: Double(percentage), charging: false, target: 0,
                connectedToPower: false, segment: 1
            )
        }
        let secondSegment = stride(from: 9, through: 5, by: -1).enumerated().map { index, percentage in
            BatteryTimeEstimator.Sample(
                date: start.addingTimeInterval(Double(86 + index) * 60),
                percentage: Double(percentage), charging: false, target: 0,
                connectedToPower: false, segment: 2
            )
        }
        let profile = try XCTUnwrap(BatteryTimeProfileBuilder.latestCompleteProfile(
            from: firstSegment + secondSegment,
            direction: .discharging,
            targetPercent: 5
        ))

        XCTAssertEqual(BatteryTimeProfileCatalog(profiles: [profile]).minutesPerBand(
            direction: .discharging, targetPercent: 5, lowerPercent: 5, now: profile.sessionEnd
        ), 5)
    }

    func testDischargeProfileIsNotCreatedUntilFivePercentIsObserved() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let completeSamples = stride(from: 95, through: 5, by: -1).enumerated().map { index, percentage in
            BatteryTimeEstimator.Sample(
                date: start.addingTimeInterval(Double(index) * 120),
                percentage: Double(percentage),
                charging: false,
                target: 0,
                connectedToPower: false,
                segment: 1
            )
        }
        let partialSamples = completeSamples.filter { $0.percentage > 5 }

        XCTAssertNil(BatteryTimeProfileBuilder.latestCompleteProfile(
            from: partialSamples,
            direction: .discharging,
            targetPercent: 5
        ))

        let profile = try XCTUnwrap(BatteryTimeProfileBuilder.latestCompleteProfile(
            from: completeSamples,
            direction: .discharging,
            targetPercent: 5
        ))

        XCTAssertEqual(profile.sessionStartPercent, 95)
        XCTAssertEqual(profile.sessionEndPercent, 5)
        XCTAssertEqual(profile.bands.count, 18)
        XCTAssertEqual(BatteryTimeProfileCatalog(profiles: [profile]).minutesPerBand(
            direction: .discharging, targetPercent: 5, lowerPercent: 5, now: profile.sessionEnd
        ), 10)
    }

    func testLatestCompleteProfilesKeepChargingAndDischargingCurvesSeparate() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let charging = makeSamples(19...50, start: start, offsetMinutes: 0,
                                   charging: true, target: 95, connected: true, segment: 1)
        let dischargingStart = start.addingTimeInterval(10_000)
        let discharging = stride(from: 95, through: 5, by: -1).enumerated().map { index, percentage in
            BatteryTimeEstimator.Sample(
                date: dischargingStart.addingTimeInterval(Double(index) * 120),
                percentage: Double(percentage),
                charging: false,
                target: 0,
                connectedToPower: false,
                segment: 2
            )
        }
        let completeCharge = makeSamples(51...95, start: start, offsetMinutes: 32,
                                         charging: true, target: 95, connected: true, segment: 3)

        let profiles = BatteryTimeProfileBuilder.latestCompleteProfiles(
            from: charging + completeCharge + discharging
        )
        let charge = try XCTUnwrap(profiles.profiles.first { $0.direction == .charging })
        let discharge = try XCTUnwrap(profiles.profiles.first { $0.direction == .discharging })

        XCTAssertEqual(charge.targetPercent, 95)
        XCTAssertEqual(charge.sessionStartPercent, 19)
        XCTAssertEqual(charge.sessionEndPercent, 95)
        XCTAssertEqual(discharge.targetPercent, 5)
        XCTAssertEqual(discharge.sessionStartPercent, 95)
        XCTAssertEqual(discharge.sessionEndPercent, 5)
    }

    func testEstimatorUsesLocalChargeProfileForWholeTargetEta() {
        let profile = chargingProfile(minutesPerBand: 5)
        var estimator = BatteryTimeEstimator(
            profiles: BatteryTimeProfileCatalog(profiles: [profile])
        )

        let estimate = estimator.add(date: profile.sessionEnd.addingTimeInterval(60),
                                     percentage: 30, charging: true, target: 95)

        XCTAssertEqual(estimate, 65)
    }

    func testEstimatorUsesCompleteDischargeProfileToFivePercentReserve() {
        let date = Date(timeIntervalSince1970: 2_000)
        let profile = BatteryTimeProfile(
            direction: .discharging,
            targetPercent: 5,
            sessionStart: date.addingTimeInterval(-10_000),
            sessionEnd: date.addingTimeInterval(-60),
            sessionStartPercent: 95,
            sessionEndPercent: 5,
            bands: stride(from: 5, to: 95, by: 5)
                .map { .init(lowerPercent: $0, minutes: 10) }
        )
        var estimator = BatteryTimeEstimator(
            profiles: BatteryTimeProfileCatalog(profiles: [profile])
        )

        let estimate = estimator.add(date: date, percentage: 95,
                                     charging: false, target: 0)

        XCTAssertEqual(estimate, 180)
    }

    func testMeasuredLowBatteryBandIsNotReducedByLegacyReserveDamping() {
        let date = Date(timeIntervalSince1970: 2_000)
        let profile = BatteryTimeProfile(
            direction: .discharging,
            targetPercent: 5,
            sessionStart: date.addingTimeInterval(-3_600),
            sessionEnd: date.addingTimeInterval(-60),
            sessionStartPercent: 95,
            sessionEndPercent: 5,
            bands: [.init(lowerPercent: 5, minutes: 10)]
        )
        var estimator = BatteryTimeEstimator(
            profiles: BatteryTimeProfileCatalog(profiles: [profile])
        )

        let estimate = estimator.add(date: date, percentage: 8,
                                     charging: false, target: 0)

        XCTAssertEqual(estimate, 6)
    }

    func testMissingLocalBandFallsBackToLegacyBandHistory() {
        let profile = chargingProfile(minutesPerBand: 5, missingBand: 50)
        var estimator = BatteryTimeEstimator(
            profiles: BatteryTimeProfileCatalog(profiles: [profile])
        )
        let start = Date(timeIntervalSince1970: 2_000)
        for step in 0...75 {
            _ = estimator.add(date: start.addingTimeInterval(Double(step * 120)),
                              percentage: Double(20 + step), charging: true, target: 95)
        }

        let estimate = estimator.add(date: start.addingTimeInterval(151 * 60),
                                     percentage: 30, charging: true, target: 95)

        XCTAssertEqual(estimate, 70)
    }

    func testCatalogIgnoresInvalidBandObservation() {
        let date = Date(timeIntervalSince1970: 1_000)
        let profile = BatteryTimeProfile(
            direction: .charging,
            targetPercent: 95,
            sessionStart: date,
            sessionEnd: date.addingTimeInterval(3_600),
            sessionStartPercent: 19,
            sessionEndPercent: 95,
            bands: [
                .init(lowerPercent: 20, minutes: .nan)
            ]
        )

        XCTAssertNil(BatteryTimeProfileCatalog(profiles: [profile]).minutesPerBand(
            direction: .charging, targetPercent: 95, lowerPercent: 20,
            now: date.addingTimeInterval(3_600)
        ))
    }

    func testProfileStoreKeepsLegacySamplesForRollback() throws {
        let suiteName = "BatteryTimeProfileTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacySamples = Data("legacy estimator history".utf8)
        defaults.set(legacySamples, forKey: "battery.timeEstimator.samples.v1")
        let date = Date(timeIntervalSince1970: 1_000)
        let profile = BatteryTimeProfile(
            direction: .charging,
            targetPercent: 95,
            sessionStart: date,
            sessionEnd: date.addingTimeInterval(3_600),
            sessionStartPercent: 19,
            sessionEndPercent: 95,
            bands: [.init(lowerPercent: 20, minutes: 4)]
        )
        let store = BatteryTimeProfileStore(defaults: defaults)

        store.save(BatteryTimeProfileCatalog(profiles: [profile]))

        XCTAssertEqual(defaults.data(forKey: "battery.timeEstimator.samples.v1"), legacySamples)
        XCTAssertEqual(store.load(), BatteryTimeProfileCatalog(profiles: [profile]))
    }

    func testExpiredProfilesAreRemovedFromTheLocalCatalog() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        let expiredProfile = BatteryTimeProfile(
            direction: .discharging,
            targetPercent: 5,
            sessionStart: now.addingTimeInterval(-70 * 24 * 60 * 60),
            sessionEnd: now.addingTimeInterval(-61 * 24 * 60 * 60),
            sessionStartPercent: 95,
            sessionEndPercent: 5,
            bands: [.init(lowerPercent: 90, minutes: 8)]
        )
        var catalog = BatteryTimeProfileCatalog(profiles: [expiredProfile])

        XCTAssertTrue(catalog.pruneExpired(now: now))
        XCTAssertTrue(catalog.profiles.isEmpty)
    }

    func testCatalogEnrichesSameCompletedSessionWithoutReplacingOtherSessions() {
        let sparse = chargingProfile(minutesPerBand: 5, missingBand: 90)
        let previous = BatteryTimeProfile(
            direction: .charging,
            targetPercent: 95,
            sessionStart: sparse.sessionStart.addingTimeInterval(-10_000),
            sessionEnd: sparse.sessionEnd.addingTimeInterval(-10_000),
            sessionStartPercent: 20,
            sessionEndPercent: 95,
            bands: [.init(lowerPercent: 90, minutes: 7)]
        )
        let enriched = BatteryTimeProfile(
            direction: sparse.direction,
            targetPercent: sparse.targetPercent,
            sessionStart: sparse.sessionStart,
            sessionEnd: sparse.sessionEnd,
            sessionStartPercent: sparse.sessionStartPercent,
            sessionEndPercent: sparse.sessionEndPercent,
            bands: sparse.bands + [.init(lowerPercent: 90, minutes: 6.7)]
        )
        let now = sparse.sessionEnd.addingTimeInterval(60)
        var catalog = BatteryTimeProfileCatalog(profiles: [previous, sparse])

        XCTAssertTrue(catalog.addIfNewer(enriched, now: now))
        XCTAssertEqual(catalog.profiles.count, 2)
        let rebuilt = catalog.profiles.first { $0.sessionStart == sparse.sessionStart }
        XCTAssertEqual(rebuilt?.bands.first(where: { $0.lowerPercent == 90 })?.minutes, 6.7)
        XCTAssertFalse(catalog.addIfNewer(sparse, now: now),
                       "An older sparse rebuild must not erase the added terminal band.")
    }

    func testBidirectionalActivationRequiresBothFreshProfiles() {
        let charge = chargingProfile(minutesPerBand: 4)
        let discharge = BatteryTimeProfile(
            direction: .discharging,
            targetPercent: 5,
            sessionStart: charge.sessionStart,
            sessionEnd: charge.sessionEnd,
            sessionStartPercent: 95,
            sessionEndPercent: 5,
            bands: [.init(lowerPercent: 90, minutes: 5)]
        )
        let now = charge.sessionEnd.addingTimeInterval(60)
        var catalog = BatteryTimeProfileCatalog(profiles: [charge])

        XCTAssertFalse(catalog.hasBidirectionalProfiles(now: now))
        catalog.add(discharge, now: now)
        XCTAssertTrue(catalog.hasBidirectionalProfiles(now: now))
        XCTAssertFalse(catalog.hasBidirectionalProfiles(
            now: now.addingTimeInterval(BatteryLongTermBaseline.retentionHorizon + 1)
        ))
    }

    private func makeSamples(
        _ percentages: ClosedRange<Int>,
        start: Date,
        offsetMinutes: Int,
        charging: Bool,
        target: Double?,
        connected: Bool,
        segment: Int,
        secondsPerPoint: TimeInterval = 60
    ) -> [BatteryTimeEstimator.Sample] {
        percentages.enumerated().map { index, percentage in
            BatteryTimeEstimator.Sample(
                date: start.addingTimeInterval(Double(offsetMinutes * 60) + Double(index) * secondsPerPoint),
                percentage: Double(percentage),
                charging: charging,
                target: target,
                connectedToPower: connected,
                segment: segment
            )
        }
    }

    private func chargingProfile(minutesPerBand: Double, missingBand: Int? = nil) -> BatteryTimeProfile {
        let date = Date(timeIntervalSince1970: 1_000)
        return BatteryTimeProfile(
            direction: .charging,
            targetPercent: 95,
            sessionStart: date,
            sessionEnd: date.addingTimeInterval(1_000),
            sessionStartPercent: 20,
            sessionEndPercent: 95,
            bands: stride(from: 20, to: 95, by: 5)
                .filter { $0 != missingBand }
                .map { .init(lowerPercent: $0, minutes: minutesPerBand) }
        )
    }
}
