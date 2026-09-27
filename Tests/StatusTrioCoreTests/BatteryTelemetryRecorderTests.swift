import Foundation
import XCTest
@testable import StatusTrioCore

final class BatteryTelemetryRecorderTests: XCTestCase {
    func testRecordsCapacityAndPowerToDailyJSONLines() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryTelemetryRecorderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recorder = BatteryTelemetryRecorder(directory: directory, clock: { now }, powerReader: { _, _ in
            BatteryPowerSample(volts: 12, amps: -1.5, updatedAt: now)
        })
        recorder.record(BatteryReading(currentCapacity: 72, maxCapacity: 100,
                                       isCharging: false, remainingMinutes: 210,
                                       isConnectedToPower: false, isPresent: true),
                        at: now, displayedMinutes: 210)
        recorder.flush()
        let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let data = try Data(contentsOf: files[0])
        let lines = data.split(separator: 0x0A)
        XCTAssertEqual(lines.count, 1)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let observation = try decoder.decode(BatteryTelemetryRecorder.Observation.self,
                                             from: Data(lines[0]))
        XCTAssertEqual(observation.percentage, 72)
        XCTAssertEqual(observation.batteryWatts, -18)
        XCTAssertEqual(observation.systemDischargeMinutes, 210)
        XCTAssertEqual(observation.schemaVersion, 5)
        XCTAssertEqual(observation.displayedMinutes, 210)
        XCTAssertEqual(observation.displayedMinutesSource, "system")
        XCTAssertNotNil(observation.powerReadAt)
        XCTAssertEqual(observation.powerSampleStatus, "fresh")
        XCTAssertEqual(observation.powerSampleAgeSeconds, 0)
        XCTAssertFalse(observation.batteryReadingRepeated)
        XCTAssertEqual(observation.powerSampleRepeated, false)
    }

    func testRecordsEstimatorDiagnostics() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryTelemetryRecorderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recorder = BatteryTelemetryRecorder(directory: directory, powerReader: { _, _ in nil })
        var diagnostics = BatteryTimeEstimator.Diagnostics(
            mode: "discharging", validRateCount: 8,
            baselineRate: 0.2, recentRate: 0.24,
            selectedRate: 0.216, reservePercent: 5,
            usedSystemEstimate: false
        )
        diagnostics.completedBandObservationCount = 4
        diagnostics.predictionMethod = "intervalProfile"
        diagnostics.nextTwoPercentMinutes = 12
        diagnostics.pendingProbeTargetPercent = 38
        diagnostics.pendingProbeBaselineMinutes = 10
        diagnostics.pendingProbePredictedMinutes = 12
        diagnostics.completedProbeStartedAt = now.addingTimeInterval(-15 * 60)
        diagnostics.completedProbeCrossedAt = now.addingTimeInterval(-12 * 60)
        diagnostics.completedProbeFromPercent = 40
        diagnostics.completedProbeTargetPercent = 36
        diagnostics.completedProbeBaselineMinutes = 10
        diagnostics.completedProbeBaselineErrorRatio = 1.5
        diagnostics.completedProbePredictedMinutes = 12
        diagnostics.completedProbeActualMinutes = 15
        diagnostics.completedProbePredictionErrorRatio = 1.25
        recorder.record(
            BatteryReading(currentCapacity: 40, maxCapacity: 100, isCharging: false,
                           isConnectedToPower: false, isPresent: true),
            at: now,
            estimatorMinutes: 52,
            displayedMinutes: 52,
            estimatorTargetPercent: 0,
            diagnostics: diagnostics
        )
        recorder.flush()
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil).first)
        let line = try XCTUnwrap(Data(contentsOf: file).split(separator: 0x0A).first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let observation = try decoder.decode(BatteryTelemetryRecorder.Observation.self,
                                             from: Data(line))
        XCTAssertEqual(observation.estimatorMinutes, 52)
        XCTAssertEqual(observation.displayedMinutes, 52)
        XCTAssertEqual(observation.displayedMinutesSource, "estimator")
        XCTAssertEqual(observation.estimatorTargetPercent, 0)
        XCTAssertEqual(observation.estimatorMode, "discharging")
        XCTAssertEqual(observation.estimatorValidRateCount, 8)
        XCTAssertEqual(observation.estimatorSelectedRate ?? 0, 0.216, accuracy: 0.0001)
        XCTAssertEqual(observation.estimatorPredictionMethod, "intervalProfile")
        XCTAssertEqual(observation.estimatorCompletedBandObservationCount, 4)
        XCTAssertEqual(observation.estimatorNextTwoPercentMinutes, 12)
        XCTAssertEqual(observation.estimatorPendingProbeTargetPercent, 38)
        XCTAssertEqual(observation.estimatorPendingProbeBaselineMinutes, 10)
        XCTAssertEqual(observation.estimatorPendingProbePredictedMinutes, 12)
        XCTAssertEqual(observation.estimatorCompletedProbeFromPercent, 40)
        XCTAssertEqual(observation.estimatorCompletedProbeTargetPercent, 36)
        XCTAssertEqual(observation.estimatorCompletedProbeBaselineMinutes, 10)
        XCTAssertEqual(observation.estimatorCompletedProbeBaselineErrorRatio, 1.5)
        XCTAssertEqual(observation.estimatorCompletedProbePredictedMinutes, 12)
        XCTAssertEqual(observation.estimatorCompletedProbeActualMinutes, 15)
        XCTAssertEqual(observation.estimatorCompletedProbePredictionErrorRatio, 1.25)
    }

    func testChargingFallbackRecordsItsTargetAndDisplayedSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryTelemetryRecorderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = BatteryTelemetryRecorder(directory: directory, powerReader: { _, _ in nil })
        recorder.record(BatteryReading(currentCapacity: 80, maxCapacity: 100,
                                       isCharging: true, timeToFullChargeMinutes: 60,
                                       chargeLimit: 95, chargeLimitKnown: true,
                                       isConnectedToPower: true, isPresent: true),
                        at: Date(timeIntervalSince1970: 1_700_000_000),
                        displayedMinutes: 60, estimatorTargetPercent: 95)
        recorder.flush()
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil).first)
        let line = try XCTUnwrap(Data(contentsOf: file).split(separator: 0x0A).first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let observation = try decoder.decode(BatteryTelemetryRecorder.Observation.self,
                                             from: Data(line))
        XCTAssertEqual(observation.systemChargeMinutes, 60)
        XCTAssertEqual(observation.displayedMinutes, 60)
        XCTAssertEqual(observation.displayedMinutesSource, "system")
        XCTAssertEqual(observation.estimatorTargetPercent, 95)
    }

    func testRepeatedSamplesAreMarkedAndStalePowerIsExcluded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryTelemetryRecorderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recorder = BatteryTelemetryRecorder(directory: directory, clock: { now }, powerReader: { _, _ in
            BatteryPowerSample(volts: 12, amps: -1, updatedAt: now)
        })
        let reading = BatteryReading(currentCapacity: 80, maxCapacity: 100,
                                     isCharging: true, isConnectedToPower: true, isPresent: true)
        recorder.record(reading, at: now)
        recorder.record(reading, at: now.addingTimeInterval(15))
        recorder.flush()
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil).first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let observations = try Data(contentsOf: file).split(separator: 0x0A).map {
            try decoder.decode(BatteryTelemetryRecorder.Observation.self, from: Data($0))
        }
        XCTAssertEqual(observations.count, 2)
        XCTAssertFalse(observations[0].batteryReadingRepeated)
        XCTAssertEqual(observations[0].powerSampleRepeated, false)
        XCTAssertTrue(observations[1].batteryReadingRepeated)
        XCTAssertEqual(observations[1].powerSampleRepeated, true)

        let staleDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryTelemetryRecorderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staleDirectory) }
        let staleRecorder = BatteryTelemetryRecorder(directory: staleDirectory, clock: { now }, powerReader: { _, _ in
            BatteryPowerSample(volts: 12, amps: -1, updatedAt: now.addingTimeInterval(-120))
        })
        staleRecorder.record(reading, at: now)
        staleRecorder.flush()
        let staleFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: staleDirectory, includingPropertiesForKeys: nil).first)
        let staleLine = try XCTUnwrap(Data(contentsOf: staleFile).split(separator: 0x0A).first)
        let stale = try decoder.decode(BatteryTelemetryRecorder.Observation.self,
                                       from: Data(staleLine))
        XCTAssertEqual(stale.powerSampleStatus, "stale")
        XCTAssertEqual(stale.powerSampleAgeSeconds, 120)
        XCTAssertNil(stale.batteryWatts)
        XCTAssertNil(stale.powerSampleRepeated)
    }

    func testRemovesExpiredDailyFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryTelemetryRecorderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("2020-01-01.jsonl")
        try Data().write(to: old)
        let recorder = BatteryTelemetryRecorder(directory: directory, powerReader: { _, _ in nil })
        recorder.record(BatteryReading(currentCapacity: 50, maxCapacity: 100,
                                       isCharging: false, isConnectedToPower: false,
                                       isPresent: true), at: Date(timeIntervalSince1970: 1_700_000_000))
        recorder.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }
}
