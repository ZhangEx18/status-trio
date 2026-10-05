import XCTest
@testable import StatusTrioCore

final class BatteryTimeEstimatorTests: XCTestCase {
    private func interval(_ rate: Double, index: Int = 0) -> BatteryDischargeStateMachine.Interval {
        .init(segment: 0, start: Date(timeIntervalSince1970: Double(index * 60)),
              end: Date(timeIntervalSince1970: Double((index + 1) * 60)), rate: rate)
    }

    func testRepeatedFastIntervalDoesNotConfirmHighLoad() {
        var machine = BatteryDischargeStateMachine()
        for _ in 0..<5 { machine.update(baseline: 1, recentIntervals: [interval(1.4)]) }
        XCTAssertEqual(machine.state, .transient)
    }

    func testDirtySegmentDoesNotSeedAProfileAcrossBoundary() {
        let start = Date(timeIntervalSince1970: 1000)
        let samples = (85...95).enumerated().map { offset, percentage in
            BatteryTimeEstimator.Sample(date: start.addingTimeInterval(Double(offset * 60)),
                percentage: Double(percentage), charging: true, target: 95,
                segment: percentage < 88 ? 0 : 1)
        }
        let estimator = BatteryTimeEstimator(samples: samples)
        XCTAssertFalse(estimator.completedBands(mode: .charging, target: 95,
            segmentPolicy: .verifiedContinuousSamples).contains { $0.lowerPercent == 85 })
    }

    func testSystemChargeEstimateIsUsedDirectlyWithoutTaper() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1000)
        _ = estimator.add(date: start, percentage: 90, charging: true, target: 95,
                          systemMinutes: 48)
        XCTAssertEqual(estimator.add(date: start.addingTimeInterval(60), percentage: 90,
            charging: true, target: 95, systemMinutes: 48), 48)
    }

    func testHighChargePercentCannotCreateAPhysicalReference() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1000)
        _ = estimator.add(date: start, percentage: 85, charging: true, target: 95)
        XCTAssertNil(estimator.add(date: start.addingTimeInterval(60), percentage: 86,
                                  charging: true, target: 95))
    }

    func testDirtyBoundaryClearsChargePhysicalReference() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1000)
        _ = estimator.add(date: start, percentage: 70, charging: true, target: 95)
        XCTAssertNotNil(estimator.add(date: start.addingTimeInterval(60), percentage: 71,
                                     charging: true, target: 95))
        estimator.markDirtyInterval()
        XCTAssertNil(estimator.add(date: start.addingTimeInterval(120), percentage: 72,
                                  charging: true, target: 95))
    }

    func testShortDirtyBoundaryDoesNotCreateAFragmentRate() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1000)
        for minute in 0...5 {
            if minute == 3 { estimator.markDirtyInterval() }
            _ = estimator.add(date: start.addingTimeInterval(Double(minute * 60)),
                              percentage: Double(80 - minute), charging: false, target: 0)
        }
        XCTAssertEqual(estimator.diagnostics.validRateCount, 0)
        XCTAssertNil(estimator.diagnostics.rawETA)
    }

    func testUnchangedChargePercentReevaluatesSystemEstimateAvailability() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(estimator.add(date: start, percentage: 90, charging: true,
            target: 95, systemMinutes: 60), 60)
        XCTAssertNil(estimator.add(date: start.addingTimeInterval(15), percentage: 90,
            charging: true, target: 95, systemMinutes: nil))
        XCTAssertEqual(estimator.add(date: start.addingTimeInterval(30), percentage: 90,
            charging: true, target: 95, systemMinutes: 48), 48)
        XCTAssertEqual(estimator.persistedSamples.count, 1)
    }

    func testSingleSlowIntervalUsesMinuteWeightedTransientCorrection() {
        var stateMachine = BatteryDischargeStateMachine()
        let baselineRate = 1.0 / 9.0
        let slowRate = 1.0 / 15.0

        stateMachine.update(baseline: baselineRate, recentIntervals: [interval(slowRate)])

        XCTAssertEqual(stateMachine.state, .transient)
        let selected = stateMachine.selectedRate(baseline: baselineRate, recent: slowRate)
        XCTAssertEqual(1 / selected, 12.6, accuracy: 0.01)

        stateMachine.update(baseline: baselineRate, recentIntervals: [interval(baselineRate, index: 3)])
        XCTAssertEqual(stateMachine.state, .baseline)
    }

    func testTwoFastIntervalsEnterHighLoadForResponsiveForecasts() {
        var stateMachine = BatteryDischargeStateMachine()
        for index in 0..<2 {
            stateMachine.update(baseline: 1.0, recentIntervals: [interval(1.4, index: index)])
        }
        XCTAssertEqual(stateMachine.state, .highLoad)
    }

    func testThreeSlowIntervalsEnterLowLoadAndOneNormalIntervalExits() {
        var stateMachine = BatteryDischargeStateMachine()
        let baselineRate = 1.0
        let slowRate = 0.7

        for index in 0..<3 {
            stateMachine.update(baseline: baselineRate, recentIntervals: [interval(slowRate, index: index)])
        }
        XCTAssertEqual(stateMachine.state, .lowLoad)

        stateMachine.update(baseline: baselineRate, recentIntervals: [interval(baselineRate, index: 3)])
        XCTAssertEqual(stateMachine.state, .baseline)
    }

    func testFragmentRateDoesNotBridgeASleepGap() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)

        _ = estimator.add(date: start, percentage: 80,
                          charging: false, target: 0)
        _ = estimator.add(date: start.addingTimeInterval(60), percentage: 79,
                          charging: false, target: 0)
        let result = estimator.add(
            date: start.addingTimeInterval(4 * 60 * 60),
            percentage: 76,
            charging: false,
            target: 0
        )

        XCTAssertNil(result)
        XCTAssertNotEqual(estimator.persistedSamples[1].segment,
                          estimator.persistedSamples[2].segment)
    }

    func testObservedChargeSlowdownKeepsMeasuredSourceAndReportsReferenceChange() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = estimator.add(date: start, percentage: 50, charging: true, target: 95)
        _ = estimator.add(date: start.addingTimeInterval(60), percentage: 51,
                          charging: true, target: 95)
        _ = estimator.add(date: start.addingTimeInterval(180), percentage: 52,
                          charging: true, target: 95)
        XCTAssertTrue(estimator.diagnostics.chargingThermalThrottled)
        XCTAssertEqual(estimator.persistedSamples.last?.source, .iops)
        XCTAssertEqual(estimator.diagnostics.completedBandObservationCount, 0)
    }

    func testCompletedFivePercentBandCountsOnceDespiteOverlappingSamples() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        for minute in 0...5 {
            _ = estimator.add(date: start.addingTimeInterval(Double(minute * 60)),
                              percentage: Double(50 + minute), charging: true, target: 95)
            _ = estimator.add(date: start.addingTimeInterval(Double(minute * 60 + 15)),
                              percentage: Double(50 + minute), charging: true, target: 95)
        }
        XCTAssertEqual(estimator.diagnostics.completedBandObservationCount, 1)
    }

    func testRecentFivePercentForecastStaysInShadowWithoutACompletedTargetBand() {
        let percentages = [87, 87, 88, 89, 89, 90, 91, 92, 93]
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        for (minute, percentage) in percentages.dropLast().enumerated() {
            _ = estimator.add(date: start.addingTimeInterval(Double(minute * 60)),
                              percentage: Double(percentage), charging: true, target: 95)
        }
        XCTAssertEqual(estimator.diagnostics.nextTwoPercentMinutes ?? 0, 2.4, accuracy: 0.2)
        XCTAssertNil(estimator.add(date: start.addingTimeInterval(7 * 60 + 15),
                                   percentage: 92, charging: true, target: 95))
        let result = estimator.add(date: start.addingTimeInterval(8 * 60),
                                   percentage: 93, charging: true, target: 95)
        XCTAssertNil(result)
        XCTAssertNotNil(estimator.diagnostics.nextTwoPercentMinutes)
        XCTAssertNil(estimator.diagnostics.predictionMethod)

        var distant = BatteryTimeEstimator()
        for (minute, percentage) in percentages.enumerated() {
            _ = distant.add(date: start.addingTimeInterval(Double(minute * 60)),
                            percentage: Double(percentage - 12), charging: true, target: 95)
        }
        XCTAssertNil(distant.add(date: start.addingTimeInterval(8 * 60),
                                  percentage: 80, charging: true, target: 95))
    }

    func testLearnedChargeProfileStaysAtBaselineWhileShortForecastIsInShadow() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        for minute in 0...45 {
            _ = estimator.add(date: start.addingTimeInterval(Double(minute * 60)),
                              percentage: Double(50 + minute), charging: true, target: 95)
        }
        _ = estimator.add(date: start.addingTimeInterval(46 * 60), percentage: 95,
                          charging: false, target: nil, connectedToPower: true)
        var result: Int?
        for step in 0...5 {
            result = estimator.add(date: start.addingTimeInterval(Double((47 + step * 2) * 60)),
                                   percentage: Double(50 + step), charging: true, target: 95)
        }
        XCTAssertNotNil(result)
        XCTAssertEqual(result, 40)
        XCTAssertEqual(estimator.diagnostics.predictionMethod, "intervalProfile")
        XCTAssertEqual(estimator.diagnostics.completedBandObservationCount, 10)
        XCTAssertGreaterThan(estimator.diagnostics.recentCorrectionFactor ?? 0, 1)
    }

    func testLearnedDischargeProfileKeepsBaselineWhileShortForecastIsInShadow() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        for minute in 0...75 {
            _ = estimator.add(date: start.addingTimeInterval(Double(minute * 60)),
                              percentage: Double(80 - minute), charging: false, target: 0)
        }
        _ = estimator.add(date: start.addingTimeInterval(76 * 60), percentage: 5,
                          charging: false, target: nil, connectedToPower: true)
        var result: Int?
        for step in 0...5 {
            result = estimator.add(date: start.addingTimeInterval(Double((77 + step * 2) * 60)),
                                   percentage: Double(80 - step), charging: false, target: 0)
        }
        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result ?? 0, 70)
        XCTAssertNotNil(estimator.diagnostics.nextTwoPercentMinutes)
        XCTAssertEqual(estimator.diagnostics.predictionMethod, "intervalProfile")
        XCTAssertEqual(estimator.diagnostics.dischargeState, "lowLoad")
    }

    func testIndependentBandMedianResistsOneLongOutlier() {
        var stored: [BatteryTimeEstimator.Sample] = []
        for session in 0..<10 {
            let duration = session == 9 ? 50 : 5
            for minute in 0...duration {
                let gained = session == 9 ? minute / 10 : minute
                stored.append(.init(date: Date(timeIntervalSince1970:
                    Double(session * 10_000 + minute * 60)),
                    percentage: Double(50 + gained), charging: true,
                    target: 55, segment: session))
            }
        }
        var estimator = BatteryTimeEstimator(samples: stored)
        let result = estimator.add(date: Date(timeIntervalSince1970: 100_000),
                                   percentage: 50, charging: true, target: 55)
        XCTAssertEqual(result, 5)
        XCTAssertEqual(estimator.diagnostics.completedBandObservationCount, 10)
    }

    func testSubminuteCapacityChangeIsPreservedForAccurateCrossingTimes() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = estimator.add(date: start, percentage: 50, charging: true, target: 95)
        _ = estimator.add(date: start.addingTimeInterval(40),
                          percentage: 51, charging: true, target: 95)
        XCTAssertEqual(estimator.persistedSamples.count, 2)
    }

    func testTwoPointForecastIsCheckedAgainstActualCrossing() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        for minute in 0...5 {
            _ = estimator.add(date: start.addingTimeInterval(Double(minute * 60)),
                              percentage: Double(50 + minute), charging: true, target: 95)
        }
        XCTAssertEqual(estimator.diagnostics.pendingProbeTargetPercent, 57)
        XCTAssertEqual(estimator.diagnostics.pendingProbePredictedMinutes ?? 0, 2, accuracy: 0.01)
        XCTAssertNil(estimator.diagnostics.pendingProbeBaselineMinutes)
        _ = estimator.add(date: start.addingTimeInterval(7 * 60),
                          percentage: 56, charging: true, target: 95)
        _ = estimator.add(date: start.addingTimeInterval(9 * 60),
                          percentage: 57, charging: true, target: 95)
        XCTAssertEqual(estimator.diagnostics.completedProbeTargetPercent, 57)
        XCTAssertNil(estimator.diagnostics.completedProbeBaselineMinutes)
        XCTAssertEqual(estimator.diagnostics.completedProbePredictedMinutes ?? 0, 2, accuracy: 0.01)
        XCTAssertEqual(estimator.diagnostics.completedProbeActualMinutes ?? 0, 4, accuracy: 0.01)
        XCTAssertEqual(estimator.diagnostics.completedProbeErrorRatio ?? 0, 2, accuracy: 0.01)
        XCTAssertEqual(estimator.diagnostics.pendingProbeTargetPercent, 59)
        XCTAssertGreaterThan(estimator.diagnostics.nextTwoPercentMinutes ?? 0, 2.8)
    }

    func testPowerTransitionDiscardsPendingTwoPointForecast() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        for minute in 0...5 {
            _ = estimator.add(date: start.addingTimeInterval(Double(minute * 60)),
                              percentage: Double(50 + minute), charging: true, target: 95)
        }
        XCTAssertEqual(estimator.diagnostics.pendingProbeTargetPercent, 57)
        _ = estimator.add(date: start.addingTimeInterval(6 * 60), percentage: 55,
                          charging: false, target: nil, connectedToPower: true)
        _ = estimator.add(date: start.addingTimeInterval(7 * 60),
                          percentage: 57, charging: true, target: 95)
        XCTAssertNil(estimator.diagnostics.completedProbeActualMinutes)
        XCTAssertNil(estimator.diagnostics.completedProbeErrorRatio)
    }

    func testSubminuteCrossingsTrainOneCompleteBand() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        for point in 0...5 {
            _ = estimator.add(date: start.addingTimeInterval(Double(point * 40)),
                              percentage: Double(50 + point), charging: true, target: 95)
        }
        XCTAssertEqual(estimator.diagnostics.completedBandObservationCount, 1)
    }

    func testRoundedCapacityAtBandBoundaryStillStartsTrainingInterval() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        for minute in 0...5 {
            let percentage = minute == 0 ? 55.00000000000001 : Double(55 + minute)
            _ = estimator.add(date: start.addingTimeInterval(Double(minute * 60)),
                              percentage: percentage, charging: true, target: 95)
        }
        XCTAssertEqual(estimator.diagnostics.completedBandObservationCount, 1)
    }

    func testNoShortForecastIsStartedAfterReachingTarget() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        for minute in 0...7 {
            _ = estimator.add(date: start.addingTimeInterval(Double(minute * 60)),
                              percentage: Double(89 + minute), charging: true, target: 95)
        }
        XCTAssertNil(estimator.diagnostics.pendingProbeTargetPercent)
    }

    func testDischargeBelowReserveDoesNotForecastFurther() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        for minute in 0...6 {
            _ = estimator.add(date: start.addingTimeInterval(Double(minute * 60)),
                              percentage: Double(10 - minute), charging: false, target: 0)
        }
        XCTAssertNil(estimator.diagnostics.pendingProbeTargetPercent)
        XCTAssertNil(estimator.diagnostics.nextTwoPercentMinutes)
    }

    func testReusedPredictionKeepsItsDiagnostics() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        for minute in 0...20 {
            _ = estimator.add(date: start.addingTimeInterval(Double(minute * 60)),
                              percentage: Double(50 - minute), charging: false, target: 0)
        }
        let count = estimator.diagnostics.validRateCount
        let baseline = estimator.diagnostics.baselineRate
        let prediction = estimator.add(date: start.addingTimeInterval(20 * 60 + 15),
                                       percentage: 30, charging: false, target: 0)
        XCTAssertNotNil(prediction)
        XCTAssertGreaterThan(count, 0)
        XCTAssertEqual(estimator.diagnostics.validRateCount, count)
        XCTAssertEqual(estimator.diagnostics.baselineRate, baseline)
    }

    func testMissingChargeBandIsReported() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        for minute in 0...30 {
            _ = estimator.add(date: start.addingTimeInterval(Double(minute * 60)),
                              percentage: Double(50 + minute), charging: true, target: 95)
        }
        XCTAssertNotNil(estimator.add(date: start.addingTimeInterval(31 * 60),
                                   percentage: 80, charging: true, target: 95))
        XCTAssertEqual(estimator.diagnostics.actualSource, "physicalFallback")
        XCTAssertEqual(estimator.diagnostics.missingChargeBandStartPercent, 80)
    }

    func testNeedsAStableWindowBeforeEstimating() {
        var estimator = BatteryTimeEstimator()
        for index in 0..<15 {
            let result = estimator.add(date: Date(timeIntervalSince1970: Double(index * 60)), percentage: 50 - Double(index), charging: false, target: 0)
            if index < 5 { XCTAssertNil(result) }
        }
        XCTAssertEqual(estimator.add(date: Date(timeIntervalSince1970: 900), percentage: 35, charging: false, target: 0), 30)
    }

    func testChargingUsesChargeLimitAsTarget() {
        var estimator = BatteryTimeEstimator()
        for index in 0..<15 {
            _ = estimator.add(date: Date(timeIntervalSince1970: Double(index * 60)), percentage: 60 + Double(index), charging: true, target: 95)
        }
        // A measured sub-80% reference may fill missing bands with one taper.
        XCTAssertEqual(estimator.add(date: Date(timeIntervalSince1970: 900), percentage: 75,
            charging: true, target: 95), 24)
        XCTAssertEqual(estimator.diagnostics.actualSource, "physicalFallback")
    }

    func testDirectionChangeResetsHistory() {
        var estimator = BatteryTimeEstimator()
        _ = estimator.add(date: Date(timeIntervalSince1970: 0), percentage: 50, charging: false, target: 0)
        _ = estimator.add(date: Date(timeIntervalSince1970: 60), percentage: 49, charging: false, target: 0)
        XCTAssertNil(estimator.add(date: Date(timeIntervalSince1970: 120), percentage: 50, charging: true, target: 100))
    }

    func testRestoreDropsSamplesOlderThanSixtyDays() {
        var estimator = BatteryTimeEstimator()
        let now = Date(timeIntervalSince1970: 70 * 24 * 60 * 60)
        let old = BatteryTimeEstimator.Sample(
            date: Date(timeIntervalSince1970: 0), percentage: 50, charging: false, target: 0
        )
        let recent = BatteryTimeEstimator.Sample(
            date: now.addingTimeInterval(-59 * 24 * 60 * 60), percentage: 49,
            charging: false, target: 0
        )
        estimator.restore([old, recent], now: now)
        XCTAssertEqual(estimator.persistedSamples, [recent])
    }

    func testHistorySurvivesPowerDirectionAndSleepGap() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        for minute in 0...20 {
            _ = estimator.add(date: start.addingTimeInterval(Double(minute * 60)),
                              percentage: 80 - Double(minute), charging: false, target: 0)
        }
        let originalCount = estimator.persistedSamples.count
        _ = estimator.add(date: start.addingTimeInterval(21 * 60),
                          percentage: 60, charging: true, target: 100)
        XCTAssertEqual(estimator.persistedSamples.count, originalCount + 1)
        _ = estimator.add(date: start.addingTimeInterval(10 * 60 * 60),
                          percentage: 90, charging: false, target: 0)
        XCTAssertEqual(estimator.persistedSamples.count, originalCount + 2)
    }

    func testBriefLoadSpikeDoesNotReplaceBaseline() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        for minute in 0...40 {
            _ = estimator.add(date: start.addingTimeInterval(Double(minute * 60)),
                              percentage: 90 - Double(minute) * 0.1,
                              charging: false, target: 0)
        }
        let before = estimator.add(date: start.addingTimeInterval(41 * 60),
                                   percentage: 85.9, charging: false, target: 0)
        let after = estimator.add(date: start.addingTimeInterval(42 * 60),
                                  percentage: 84.9, charging: false, target: 0)
        XCTAssertNotNil(before)
        XCTAssertNotNil(after)
        if let before, let after {
            XCTAssertLessThan(abs(after - before), 10)
        }
    }

    func testFlatCapacityAndCorruptHistoryDoNotProducePrediction() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        estimator.restore([
            .init(date: start, percentage: .nan, charging: false, target: 0),
            .init(date: start, percentage: 50, charging: false, target: 0)
        ], now: start)
        XCTAssertEqual(estimator.persistedSamples.count, 1)
        for minute in 1...20 {
            XCTAssertNil(estimator.add(date: start.addingTimeInterval(Double(minute * 60)),
                                       percentage: 50, charging: false, target: 0))
        }
    }

    func testWholePercentReadingsStillBuildABaseline() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        var result: Int?
        for minute in 0...40 {
            result = estimator.add(date: start.addingTimeInterval(Double(minute * 60)),
                                   percentage: Double(90 - minute / 10),
                                   charging: false, target: 0)
        }
        XCTAssertNotNil(result)
        XCTAssertTrue((700...1100).contains(result ?? 0))
    }

    func testPartialDischargeAndChargeStaySeparateAndNinetyFiveIsNotRemapped() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        for minute in 0...30 {
            _ = estimator.add(date: start.addingTimeInterval(Double(minute * 60)),
                              percentage: Double(80 - minute), charging: false, target: 0)
        }
        _ = estimator.add(date: start.addingTimeInterval(31 * 60), percentage: 50,
                          charging: false, target: nil, connectedToPower: true)
        for minute in 1...40 {
            _ = estimator.add(date: start.addingTimeInterval(Double((31 + minute) * 60)),
                              percentage: Double(50 + minute), charging: true, target: 95)
        }
        XCTAssertNotNil(estimator.add(date: start.addingTimeInterval(72 * 60),
                                   percentage: 90, charging: true, target: 95))
        XCTAssertEqual(estimator.diagnostics.actualSource, "physicalFallback")
        _ = estimator.add(date: start.addingTimeInterval(73 * 60), percentage: 95,
                          charging: false, target: nil, connectedToPower: true)
        let discharge = estimator.add(date: start.addingTimeInterval(74 * 60),
                                      percentage: 95, charging: false, target: 0)
        XCTAssertEqual(discharge, 90) // 95% displayed, about 90 points usable.
        XCTAssertEqual(estimator.persistedSamples.last?.percentage, 95)
    }

    func testBriefPlugInWithoutChargingSampleBreaksDischargeSegment() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = estimator.add(date: start, percentage: 80, charging: false, target: 0)
        _ = estimator.add(date: start.addingTimeInterval(60), percentage: 80,
                          charging: false, target: nil, connectedToPower: true)
        _ = estimator.add(date: start.addingTimeInterval(120), percentage: 79,
                          charging: false, target: 0)
        let samples = estimator.persistedSamples
        XCTAssertNotEqual(samples[0].segment, samples[2].segment)
        XCTAssertEqual(samples[1].mode, .idle)
    }

    func testUnknownLimitCannotBorrowConfirmedNinetyFivePercentHistory() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = estimator.add(date: start, percentage: 50, charging: true, target: 95)
        _ = estimator.add(date: start.addingTimeInterval(60), percentage: 51,
                          charging: true, target: nil)
        XCTAssertNotEqual(estimator.persistedSamples[0].segment,
                          estimator.persistedSamples[1].segment)
        XCTAssertNil(estimator.persistedSamples[1].target)
    }

    func testCalibrationJumpStartsANewSegment() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = estimator.add(date: start, percentage: 80, charging: false, target: 0)
        _ = estimator.add(date: start.addingTimeInterval(60),
                          percentage: 79, charging: false, target: 0)
        _ = estimator.add(date: start.addingTimeInterval(120),
                          percentage: 89, charging: false, target: 0)
        XCTAssertNotEqual(estimator.persistedSamples[1].segment,
                          estimator.persistedSamples[2].segment)
    }

    func testLowBatteryUsesValidSystemEstimateToCalibrateReserve() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        for minute in 0..<20 {
            _ = estimator.add(date: start.addingTimeInterval(Double(minute * 60)),
                              percentage: Double(30 - minute), charging: false, target: 0)
        }
        let result = estimator.add(date: start.addingTimeInterval(20 * 60),
                                   percentage: 10, charging: false, target: 0,
                                   systemMinutes: 8)
        XCTAssertEqual(result, 8)
    }

    func testLegacyHundredPercentChargeTargetIsUnknown() throws {
        let json = #"[{"date":1000,"percentage":60,"charging":true,"target":100}]"#
        let samples = try JSONDecoder().decode([BatteryTimeEstimator.Sample].self,
                                               from: Data(json.utf8))
        XCTAssertNil(samples[0].target)
    }

    func testHistoricalChargeCoveragePredictsKnownLimit() {
        var estimator = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        for minute in 0...45 {
            _ = estimator.add(date: start.addingTimeInterval(Double(minute * 60)),
                              percentage: Double(50 + minute), charging: true, target: 95)
        }
        _ = estimator.add(date: start.addingTimeInterval(46 * 60), percentage: 95,
                          charging: false, target: nil, connectedToPower: true)
        let estimate = estimator.add(date: start.addingTimeInterval(47 * 60),
                                     percentage: 50, charging: true, target: 95)
        XCTAssertNotNil(estimate)
    }

    func testCompletedBandsSurviveSamplePersistenceAndRestore() throws {
        var first = BatteryTimeEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        for minute in 0...45 {
            _ = first.add(date: start.addingTimeInterval(Double(minute * 60)),
                          percentage: Double(50 + minute), charging: true, target: 95)
        }
        let encoded = try JSONEncoder().encode(first.persistedSamples)
        let stored = try JSONDecoder().decode([BatteryTimeEstimator.Sample].self, from: encoded)
        var restored = BatteryTimeEstimator()
        restored.restore(stored, now: start.addingTimeInterval(46 * 60))
        let prediction = restored.add(date: start.addingTimeInterval(47 * 60),
                                      percentage: 50, charging: true, target: 95)
        XCTAssertEqual(prediction, 45)
        XCTAssertEqual(restored.diagnostics.completedBandObservationCount, 9)
        XCTAssertEqual(restored.diagnostics.predictionMethod, "intervalProfile")
    }
}
