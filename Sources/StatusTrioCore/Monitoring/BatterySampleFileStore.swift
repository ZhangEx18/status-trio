import Foundation
import os

/// Persists the battery time-estimator sample history as a JSON file under
/// Application Support instead of `UserDefaults`.
///
/// Rationale: the sample array grows to `BatteryTimeEstimator.maximumPersistedSamples`
/// (25 000 entries, several MB). Re-encoding and writing the whole blob through
/// cfprefs on every refresh both bloats the plist and blocks the main actor.
/// A plain file keeps the same semantics with cheaper, atomic writes and leaves
/// the plist small.
struct BatterySampleFileStore {
    private static let legacyDefaultsKey = "battery.timeEstimator.samples.v1"
    private static let logger = Logger(subsystem: "com.lingsmbp.StatusTrio",
                                       category: "battery-samples")
    private static let recencyTolerance: TimeInterval = 24 * 60 * 60
    private let fileURL: URL
    private let defaults: UserDefaults?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameters:
    ///   - directory: target directory; created on demand.
    ///   - defaults: when supplied (and non-nil), the legacy
    ///     `battery.timeEstimator.samples.v1` blob is imported once and removed.
    init(directory: URL = BatteryTelemetryRecorder.defaultDirectory
        .deletingLastPathComponent()
        .appendingPathComponent("BatterySamples", isDirectory: true),
         defaults: UserDefaults? = .standard) {
        self.fileURL = directory.appendingPathComponent("estimator-samples.json")
        self.defaults = defaults
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    /// Loads persisted samples: file first, falling back to a one-time import
    /// from the legacy UserDefaults key.
    func load() -> [BatteryTimeEstimator.Sample] {
        let fileSamples = readFileSamples()
        let legacySamples = readLegacySamples()
        guard fileSamples != nil || legacySamples != nil else { return [] }
        let samples = preferredSamples(file: fileSamples, legacy: legacySamples)
        if fileSamples != samples, !persist(samples) {
            // Keep the legacy key until the replacement file is durable.
            return samples
        }
        if legacySamples != nil {
            defaults?.removeObject(forKey: Self.legacyDefaultsKey)
        }
        return samples
    }

    /// Atomically persists the full sample array. Encoding failures are logged
    /// and swallowed: stale persistence only costs a rebuild, not correctness.
    @discardableResult
    func persist(_ samples: [BatteryTimeEstimator.Sample]) -> Bool {
        do {
            let data = try encoder.encode(samples)
            let manager = FileManager.default
            try manager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            let tmpURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent(".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
            try data.write(to: tmpURL, options: .atomic)
            _ = try manager.replaceItemAt(fileURL, withItemAt: tmpURL)
            return true
        }
        catch {
            Self.logger.error("Estimator sample persistence failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Removes the persisted file (used by tests and by opt-out paths).
    func removeAll() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func readFileSamples() -> [BatteryTimeEstimator.Sample]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try decoder.decode([BatteryTimeEstimator.Sample].self, from: data)
                .sorted { $0.date < $1.date }
        } catch {
            Self.logger.error("Estimator sample file could not be decoded: \(error.localizedDescription)")
            return nil
        }
    }

    private func readLegacySamples() -> [BatteryTimeEstimator.Sample]? {
        guard let defaults, let data = defaults.data(forKey: Self.legacyDefaultsKey) else {
            return nil
        }
        do {
            return try decoder.decode([BatteryTimeEstimator.Sample].self, from: data)
                .sorted { $0.date < $1.date }
        } catch {
            Self.logger.error("Legacy estimator samples could not be decoded: \(error.localizedDescription)")
            return nil
        }
    }

    /// A stale file must not erase a newer or larger UserDefaults history.
    /// When both sources describe the same period, the larger history wins;
    /// equal-size histories are merged with the file taking precedence on
    /// duplicate timestamps.
    private func preferredSamples(file: [BatteryTimeEstimator.Sample]?,
                                  legacy: [BatteryTimeEstimator.Sample]?)
        -> [BatteryTimeEstimator.Sample] {
        let file = file ?? []
        let legacy = legacy ?? []
        if file.isEmpty { return bounded(legacy) }
        if legacy.isEmpty { return bounded(file) }
        guard let fileLast = file.last?.date, let legacyLast = legacy.last?.date else {
            return []
        }
        if abs(fileLast.timeIntervalSince(legacyLast)) <= Self.recencyTolerance {
            if file.count != legacy.count {
                return bounded(file.count > legacy.count ? file : legacy)
            }
            return merged(file, legacy)
        }
        return bounded(fileLast > legacyLast ? file : legacy)
    }

    private func merged(_ file: [BatteryTimeEstimator.Sample],
                        _ legacy: [BatteryTimeEstimator.Sample])
        -> [BatteryTimeEstimator.Sample] {
        var byTimestamp: [Int64: BatteryTimeEstimator.Sample] = [:]
        for sample in legacy {
            byTimestamp[Self.timestampKey(sample.date)] = sample
        }
        for sample in file {
            byTimestamp[Self.timestampKey(sample.date)] = sample
        }
        return bounded(byTimestamp.values.sorted { $0.date < $1.date })
    }

    private func bounded(_ samples: [BatteryTimeEstimator.Sample])
        -> [BatteryTimeEstimator.Sample] {
        guard samples.count > BatteryTimeEstimator.maximumPersistedSamples else {
            return samples
        }
        return Array(samples.suffix(BatteryTimeEstimator.maximumPersistedSamples))
    }

    private static func timestampKey(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
