import Foundation
import OSLog

struct BatteryTimeProfileStore {
    static let key = "battery.timeEstimator.profiles.v1"

    private static let logger = Logger(subsystem: "com.lingsmbp.StatusTrio",
                                       category: "battery-profile")
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> BatteryTimeProfileCatalog? {
        guard let profileData = defaults.data(forKey: Self.key) else { return nil }
        do {
            return try JSONDecoder().decode(BatteryTimeProfileCatalog.self, from: profileData)
        } catch {
            // Legacy samples remain intact and can regenerate this catalog.
            Self.logger.error("Battery profile catalog could not be decoded: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func save(_ catalog: BatteryTimeProfileCatalog) {
        do {
            defaults.set(try JSONEncoder().encode(catalog), forKey: Self.key)
        } catch {
            Self.logger.error("Battery profile catalog could not be encoded: \(String(describing: error), privacy: .public)")
        }
    }
}
