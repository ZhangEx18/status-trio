import Foundation
import OSLog

/// Appends raw observations for later offline validation of time estimates.
/// One JSON Lines file per UTC day; no hardware IDs or process names are stored.
final class BatteryTelemetryRecorder: @unchecked Sendable {
    struct Observation: Codable {
        let schemaVersion: Int
        let recordedAt: Date
        let percentage: Double
        let currentCapacity: Int
        let maxCapacity: Int
        let connectedToPower: Bool
        let charging: Bool
        let chargeLimit: Int?
        let chargeLimitKnown: Bool
        let systemDischargeMinutes: Int?
        let systemChargeMinutes: Int?
        let voltage: Double?
        let current: Double?
        let batteryWatts: Double?
        let powerUpdatedAt: Date?
        let powerReadAt: Date
        let powerSampleStatus: String
        let powerSampleAgeSeconds: Double?
        let batteryReadingRepeated: Bool
        let powerSampleRepeated: Bool?
        let estimatorMinutes: Int?
        let profileEstimatorMinutes: Int?
        let legacyEstimatorMinutes: Int?
        let selectedEstimatorSource: String?
        let estimatorTargetPercent: Double?
        let estimatorMissingChargeBandStartPercent: Double?
        let displayedMinutes: Int?
        let displayedMinutesSource: String?
        let estimatorMode: String?
        let estimatorDischargeState: String?
        let estimatorValidRateCount: Int?
        let estimatorBaselineRate: Double?
        let estimatorRecentRate: Double?
        let estimatorSelectedRate: Double?
        let estimatorReservePercent: Double?
        let estimatorUsedSystemEstimate: Bool?
        let estimatorChargingThermalThrottled: Bool?
        let chargingRateAnomaly: Bool?
        let chargingRateAnomalyReason: String?
        let estimatorPredictionMethod: String?
        let estimatorRawMinutes: Double?
        let estimatorActualSource: String?
        let estimatorBoundaryReason: String?
        let lowPowerMode: Bool?
        let maximumCapacity: Int?
        let chargingPauseState: Bool?
        let chargingPauseReason: String?
        let estimatorCompletedBandObservationCount: Int
        let estimatorRecentCorrectionFactor: Double?
        let estimatorNextTwoPercentMinutes: Double?
        let estimatorPendingProbeTargetPercent: Double?
        let estimatorPendingProbeBaselineMinutes: Double?
        let estimatorPendingProbePredictedMinutes: Double?
        let estimatorCompletedProbeStartedAt: Date?
        let estimatorCompletedProbeCrossedAt: Date?
        let estimatorCompletedProbeFromPercent: Double?
        let estimatorCompletedProbeTargetPercent: Double?
        let estimatorCompletedProbeBaselineMinutes: Double?
        let estimatorCompletedProbeBaselineErrorRatio: Double?
        let estimatorCompletedProbePredictedMinutes: Double?
        let estimatorCompletedProbeActualMinutes: Double?
        let estimatorCompletedProbePredictionErrorRatio: Double?
    }

    typealias PowerReader = @Sendable (BatteryPowerState, Date) -> BatteryPowerSample?

    static let retention: TimeInterval = BatteryLongTermBaseline.retentionHorizon
    /// Observations whose fingerprint matches the last written one are skipped
    /// (idle sessions used to append one ~1.1 KB line per refresh interval).
    static let cleanupInterval: TimeInterval = 60 * 60
    static let defaultDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    )[0].appendingPathComponent("StatusTrio/BatteryTelemetry", isDirectory: true)

    private let queue = DispatchQueue(label: "com.lingsmbp.StatusTrio.battery-telemetry",
                                      qos: .utility)
    private let directory: URL
    private let clock: @Sendable () -> Date
    private let powerReader: PowerReader
    private let skipRepeatedObservations: Bool
    private var lastCleanupDay: String?
    private var lastCleanupDate: Date?
    private var lastReading: BatteryReading?
    private var lastPowerUpdatedAt: Date?
    private var lastPowerState: BatteryPowerState?
    private var lastSkipFingerprint: SkipFingerprint?
    private let logger = Logger(subsystem: "com.lingsmbp.StatusTrio", category: "battery-telemetry")

    /// Everything that can change between observations while the raw battery
    /// reading stays identical; if none of it changed, the line adds nothing
    /// for offline validation.
    private struct SkipFingerprint: Equatable {
        var powerUpdatedAt: Date?
        var powerState: BatteryPowerState
        var boundaryReason: String?
        var lowPowerMode: Bool?
        var chargingPauseState: Bool?
        var chargingPauseReason: String?
        var estimatorMinutes: Int?
        var profileEstimatorMinutes: Int?
        var legacyEstimatorMinutes: Int?
        var selectedEstimatorSource: String?
        var actualSource: String?
        var displayedMinutes: Int?
        var estimatorMode: String?
        var estimatorDischargeState: String?
    }

    init(directory: URL = defaultDirectory,
         clock: @escaping @Sendable () -> Date = Date.init,
         skipRepeatedObservations: Bool = true,
         powerReader: @escaping PowerReader = { state, now in
             BatteryDetailsReader().read(state: state, notBefore: nil,
                                         includeSystemPower: false).power
         }) {
        self.directory = directory
        self.clock = clock
        self.skipRepeatedObservations = skipRepeatedObservations
        self.powerReader = powerReader
        queue.async { [self] in
            performCleanupIfNeeded(now: clock())
        }
    }

    func record(_ reading: BatteryReading, at date: Date,
                estimatorMinutes: Int? = nil,
                profileEstimatorMinutes: Int? = nil,
                legacyEstimatorMinutes: Int? = nil,
                selectedEstimatorSource: String? = nil,
                displayedMinutes: Int? = nil,
                estimatorTargetPercent: Double? = nil,
                 diagnostics: BatteryTimeEstimator.Diagnostics = .init(mode: nil),
                 boundaryReason: String? = nil,
                 lowPowerMode: Bool? = nil,
                 chargingPauseState: Bool? = nil,
                 chargingPauseReason: String? = nil) {
        guard reading.isPresent, reading.maxCapacity > 0 else { return }
        queue.async { [self] in
            let state = BatteryPowerState(isPresent: true,
                                          isConnected: reading.isConnectedToPower,
                                          isCharging: reading.isCharging)
            let candidatePower = powerReader(state, date)
            let powerReadAt = clock()
            let power = candidatePower.flatMap { $0.isFresh(at: powerReadAt) ? $0 : nil }
            let powerStatus = candidatePower == nil ? "unavailable"
                : (power == nil ? "stale" : "fresh")
            let displayedMinutesSource: String? = displayedMinutes.map { minutes in
                if diagnostics.actualSource == "systemEstimate" { return "system" }
                if estimatorMinutes == minutes { return "estimator" }
                let systemMinutes = reading.isCharging
                    ? reading.timeToFullChargeMinutes : reading.remainingMinutes
                return systemMinutes == minutes ? "system" : "unknown"
            }
            let fingerprint = SkipFingerprint(
                powerUpdatedAt: power?.updatedAt,
                powerState: state,
                boundaryReason: boundaryReason,
                lowPowerMode: lowPowerMode,
                chargingPauseState: chargingPauseState,
                chargingPauseReason: chargingPauseReason,
                estimatorMinutes: estimatorMinutes,
                profileEstimatorMinutes: profileEstimatorMinutes,
                legacyEstimatorMinutes: legacyEstimatorMinutes,
                selectedEstimatorSource: selectedEstimatorSource,
                actualSource: diagnostics.actualSource,
                displayedMinutes: displayedMinutes,
                estimatorMode: diagnostics.mode,
                estimatorDischargeState: diagnostics.dischargeState
            )
            if skipRepeatedObservations, lastReading == reading,
               let lastFingerprint = lastSkipFingerprint, lastFingerprint == fingerprint {
                // Same reading and same derived values as the last written line;
                // skip the write but keep the cleanup cadence moving.
                performCleanupIfNeeded(now: powerReadAt)
                return
            }
            let observation = Observation(
                schemaVersion: 7,
                recordedAt: date,
                percentage: Double(reading.currentCapacity) / Double(reading.maxCapacity) * 100,
                currentCapacity: reading.currentCapacity,
                maxCapacity: reading.maxCapacity,
                connectedToPower: reading.isConnectedToPower,
                charging: reading.isCharging,
                chargeLimit: reading.chargeLimit,
                chargeLimitKnown: reading.chargeLimitKnown,
                systemDischargeMinutes: reading.remainingMinutes,
                systemChargeMinutes: reading.timeToFullChargeMinutes,
                voltage: power?.volts,
                current: power?.amps,
                batteryWatts: power?.watts,
                powerUpdatedAt: candidatePower?.updatedAt,
                powerReadAt: powerReadAt,
                powerSampleStatus: powerStatus,
                powerSampleAgeSeconds: candidatePower.map {
                    powerReadAt.timeIntervalSince($0.updatedAt)
                },
                batteryReadingRepeated: lastReading == reading,
                powerSampleRepeated: power.map {
                    lastPowerUpdatedAt == $0.updatedAt && lastPowerState == state
                },
                estimatorMinutes: estimatorMinutes,
                profileEstimatorMinutes: profileEstimatorMinutes,
                legacyEstimatorMinutes: legacyEstimatorMinutes,
                selectedEstimatorSource: selectedEstimatorSource,
                estimatorTargetPercent: estimatorTargetPercent,
                estimatorMissingChargeBandStartPercent: diagnostics.missingChargeBandStartPercent,
                displayedMinutes: displayedMinutes,
                displayedMinutesSource: displayedMinutesSource,
                estimatorMode: diagnostics.mode,
                estimatorDischargeState: diagnostics.dischargeState,
                estimatorValidRateCount: diagnostics.validRateCount,
                estimatorBaselineRate: diagnostics.baselineRate,
                estimatorRecentRate: diagnostics.recentRate,
                estimatorSelectedRate: diagnostics.selectedRate,
                estimatorReservePercent: diagnostics.reservePercent,
                estimatorUsedSystemEstimate: diagnostics.usedSystemEstimate,
                estimatorChargingThermalThrottled: diagnostics.chargingThermalThrottled,
                chargingRateAnomaly: diagnostics.chargingRateAnomaly,
                chargingRateAnomalyReason: diagnostics.chargingRateAnomalyReason,
                estimatorPredictionMethod: diagnostics.predictionMethod,
                estimatorRawMinutes: diagnostics.rawETA ?? displayedMinutes.map(Double.init),
                estimatorActualSource: diagnostics.actualSource
                    ?? (displayedMinutesSource == "system" ? "system" : "none"),
                estimatorBoundaryReason: boundaryReason,
                lowPowerMode: lowPowerMode,
                maximumCapacity: reading.maxCapacity,
                chargingPauseState: chargingPauseState,
                chargingPauseReason: chargingPauseReason,
                estimatorCompletedBandObservationCount: diagnostics.completedBandObservationCount,
                estimatorRecentCorrectionFactor: diagnostics.recentCorrectionFactor,
                estimatorNextTwoPercentMinutes: diagnostics.nextTwoPercentMinutes,
                estimatorPendingProbeTargetPercent: diagnostics.pendingProbeTargetPercent,
                estimatorPendingProbeBaselineMinutes: diagnostics.pendingProbeBaselineMinutes,
                estimatorPendingProbePredictedMinutes: diagnostics.pendingProbePredictedMinutes,
                estimatorCompletedProbeStartedAt: diagnostics.completedProbeStartedAt,
                estimatorCompletedProbeCrossedAt: diagnostics.completedProbeCrossedAt,
                estimatorCompletedProbeFromPercent: diagnostics.completedProbeFromPercent,
                estimatorCompletedProbeTargetPercent: diagnostics.completedProbeTargetPercent,
                estimatorCompletedProbeBaselineMinutes: diagnostics.completedProbeBaselineMinutes,
                estimatorCompletedProbeBaselineErrorRatio: diagnostics.completedProbeBaselineErrorRatio,
                estimatorCompletedProbePredictedMinutes: diagnostics.completedProbePredictedMinutes,
                estimatorCompletedProbeActualMinutes: diagnostics.completedProbeActualMinutes,
                estimatorCompletedProbePredictionErrorRatio: diagnostics.completedProbePredictionErrorRatio
            )
            do {
                try append(observation)
                lastReading = reading
                lastSkipFingerprint = fingerprint
                if let power {
                    lastPowerUpdatedAt = power.updatedAt
                    lastPowerState = state
                }
            }
            catch { logger.error("Battery telemetry write failed: \(error.localizedDescription)") }
        }
    }

    /// Used by tests and diagnostic checks; normal recording remains asynchronous.
    func flush() { queue.sync {} }

    private func performCleanupIfNeeded(now: Date, day: String? = nil) {
        let day = day ?? Self.dayName(for: now)
        let cleanupDue = lastCleanupDay != day
            || lastCleanupDate.map { now.timeIntervalSince($0) >= Self.cleanupInterval } ?? true
        guard cleanupDue else { return }
        do {
            try removeExpiredFiles(now: now)
            lastCleanupDay = day
            lastCleanupDate = now
        }
        catch { logger.error("Battery telemetry cleanup failed: \(error.localizedDescription)") }
    }

    private func append(_ observation: Observation) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let day = Self.dayName(for: observation.recordedAt)
        performCleanupIfNeeded(now: observation.recordedAt, day: day)
        let file = directory.appendingPathComponent("\(day).jsonl")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(observation)
        line.append(0x0A)
        if !manager.fileExists(atPath: file.path) {
            guard manager.createFile(atPath: file.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    private func removeExpiredFiles(now: Date) throws {
        let cutoff = now.addingTimeInterval(-Self.retention)
        for file in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) where file.pathExtension == "jsonl" {
            guard let day = Self.date(from: file.deletingPathExtension().lastPathComponent),
                  day.addingTimeInterval(24 * 60 * 60) < cutoff else { continue }
            try FileManager.default.removeItem(at: file)
        }
    }

    private static func dayName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func date(from day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }
}
