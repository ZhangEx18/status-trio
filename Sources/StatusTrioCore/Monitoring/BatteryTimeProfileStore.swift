import Foundation
import OSLog

struct BatteryTimeProfileStore {
    static let key = "battery.timeEstimator.profiles.v1"
    static let modelKey = "battery.timeEstimator.profiles.v2"

    struct Model: Codable {
        let version: Int
        let rebuiltAt: Date
        let sourceSampleCount: Int
        let legacyProfileCount: Int
        let catalog: BatteryTimeProfileCatalog
    }

    private static let logger = Logger(subsystem: "com.lingsmbp.StatusTrio",
                                       category: "battery-profile")
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> BatteryTimeProfileCatalog? {
        guard let profileData = defaults.data(forKey: Self.modelKey) else { return nil }
        do {
            let model = try JSONDecoder().decode(Model.self, from: profileData)
            guard model.version == 2, Self.isValid(model.catalog) else { return nil }
            return model.catalog
        } catch {
            // Legacy samples remain intact and can regenerate this catalog.
            Self.logger.error("Battery profile catalog could not be decoded: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func save(_ catalog: BatteryTimeProfileCatalog) {
        do {
            try persist(catalog, now: Date(), sourceSampleCount: 0, legacyProfileCount: 0)
        } catch {
            Self.logger.error("Battery profile catalog could not be encoded: \(String(describing: error), privacy: .public)")
        }
    }

    func loadOrRebuild(samples: [BatteryTimeEstimator.Sample], now: Date) throws -> BatteryTimeProfileCatalog {
        if var catalog = load() {
            if catalog.pruneExpired(now: now) {
                try persist(catalog, now: now, sourceSampleCount: samples.count, legacyProfileCount: 0)
            }
            return catalog
        }
        var estimator = BatteryTimeEstimator()
        estimator.restore(samples, now: now)
        var catalog = BatteryTimeProfileBuilder.completeProfiles(from: estimator.persistedSamples)
        _ = catalog.pruneExpired(now: now)
        catalog.profiles.removeAll { $0.sessionEnd > now }
        let legacy = defaults.data(forKey: Self.key).flatMap {
            try? JSONDecoder().decode(BatteryTimeProfileCatalog.self, from: $0)
        }
        try persist(catalog, now: now, sourceSampleCount: estimator.persistedSamples.count,
                    legacyProfileCount: legacy?.profiles.count ?? 0)
        return catalog
    }

    private func persist(_ catalog: BatteryTimeProfileCatalog, now: Date,
                         sourceSampleCount: Int, legacyProfileCount: Int) throws {
        guard Self.isValid(catalog) else { throw CocoaError(.coderInvalidValue) }
        let model = Model(version: 2, rebuiltAt: now, sourceSampleCount: sourceSampleCount,
                          legacyProfileCount: legacyProfileCount, catalog: catalog)
        let bytes = try JSONEncoder().encode(model)
        _ = try JSONDecoder().decode(Model.self, from: bytes)
        defaults.set(bytes, forKey: Self.modelKey)
        guard defaults.data(forKey: Self.modelKey) == bytes else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func isValid(_ catalog: BatteryTimeProfileCatalog) -> Bool {
        catalog.profiles.allSatisfy { profile in
            profile.sessionStart <= profile.sessionEnd
                && (0...100).contains(profile.sessionStartPercent)
                && (0...100).contains(profile.sessionEndPercent)
                && (0...100).contains(profile.targetPercent)
                && Set(profile.bands.map(\.lowerPercent)).count == profile.bands.count
                && profile.bands.allSatisfy {
                    (0..<100).contains($0.lowerPercent) && $0.lowerPercent.isMultiple(of: 5)
                        && $0.minutes.isFinite && $0.minutes > 0
                }
        }
    }
}
