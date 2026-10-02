import Foundation

struct BatteryTimeProfileCatalog: Codable, Equatable, Sendable {
    var profiles: [BatteryTimeProfile]

    init(profiles: [BatteryTimeProfile] = []) {
        self.profiles = profiles
    }

    @discardableResult
    mutating func addIfNewer(_ profile: BatteryTimeProfile, now: Date) -> Bool {
        _ = pruneExpired(now: now)
        if let index = profiles.firstIndex(where: {
            $0.direction == profile.direction && $0.targetPercent == profile.targetPercent
                && $0.sessionStart == profile.sessionStart && $0.sessionEnd == profile.sessionEnd
        }) {
            let existingBands = Set(profiles[index].bands.map(\.lowerPercent))
            let candidateBands = Set(profile.bands.map(\.lowerPercent))
            guard existingBands.isStrictSubset(of: candidateBands) else { return false }
            profiles[index] = profile
            return true
        }
        if let latest = latestSessionEnd(direction: profile.direction,
                                         targetPercent: profile.targetPercent),
           latest >= profile.sessionEnd {
            return false
        }
        add(profile, now: now)
        return true
    }

    mutating func add(_ profile: BatteryTimeProfile, now: Date) {
        _ = pruneExpired(now: now)
        profiles.removeAll {
            $0.direction == profile.direction && $0.targetPercent == profile.targetPercent
                && $0.sessionStart == profile.sessionStart && $0.sessionEnd == profile.sessionEnd
        }
        profiles.append(profile)
        profiles.sort { $0.sessionEnd < $1.sessionEnd }
    }

    @discardableResult
    mutating func pruneExpired(now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-BatteryLongTermBaseline.retentionHorizon)
        let oldCount = profiles.count
        profiles.removeAll { $0.sessionEnd < cutoff }
        return oldCount != profiles.count
    }

    func latestSessionEnd(direction: BatteryTimeProfile.Direction,
                          targetPercent: Int) -> Date? {
        profiles.lazy.filter {
            $0.direction == direction && $0.targetPercent == targetPercent
        }.map(\.sessionEnd).max()
    }

    func hasProfile(direction: BatteryTimeProfile.Direction,
                    targetPercent: Int, now: Date) -> Bool {
        profiles.contains {
            $0.direction == direction && $0.targetPercent == targetPercent
                && $0.sessionEnd <= now
                && now.timeIntervalSince($0.sessionEnd) <= BatteryLongTermBaseline.retentionHorizon
        }
    }

    /// The local curves become active as one model only after both complete targets are fresh.
    func hasBidirectionalProfiles(now: Date) -> Bool {
        hasProfile(direction: .charging,
                   targetPercent: BatteryTimeProfile.profiledChargeTargetPercent, now: now)
            && hasProfile(direction: .discharging,
                          targetPercent: BatteryTimeProfile.profiledDischargeReservePercent, now: now)
    }

    func minutesPerBand(direction: BatteryTimeProfile.Direction,
                        targetPercent: Int, lowerPercent: Int, now: Date) -> Double? {
        let observations = profiles.compactMap { profile -> BatteryLongTermBaseline.Observation? in
            guard profile.direction == direction, profile.targetPercent == targetPercent,
                  profile.sessionEnd <= now,
                  now.timeIntervalSince(profile.sessionEnd) <= BatteryLongTermBaseline.retentionHorizon,
                  let band = profile.bands.first(where: { $0.lowerPercent == lowerPercent }),
                  band.minutes.isFinite, band.minutes > 0 else { return nil }
            return BatteryLongTermBaseline.Observation(value: band.minutes, duration: 1,
                                                       date: profile.sessionEnd)
        }
        return BatteryLongTermBaseline.robustWeightedMedian(observations, now: now)
    }
}
