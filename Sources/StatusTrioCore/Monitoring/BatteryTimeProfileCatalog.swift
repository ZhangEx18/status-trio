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
            removePartialProfiles(sameSessionStartAs: profile)
            add(profile, now: now)
            return true
        }
        if let latest = latestCompleteSessionEnd(direction: profile.direction,
                                                 targetPercent: profile.targetPercent),
           latest >= profile.sessionEnd {
            return false
        }
        removePartialProfiles(sameSessionStartAs: profile)
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

    /// Partial sessions refine an existing complete curve without replacing it.
    /// A later extraction of the same session supersedes the shorter one.
    @discardableResult
    mutating func mergePartialProfiles(_ candidates: [BatteryTimeProfile],
                                       now: Date) -> Bool {
        _ = pruneExpired(now: now)
        let cutoff = now.addingTimeInterval(-BatteryLongTermBaseline.retentionHorizon)
        var changed = false
        for candidate in candidates where !candidate.isComplete {
            guard candidate.sessionEnd <= now, candidate.sessionEnd >= cutoff,
                  !candidate.bands.isEmpty else { continue }
            guard let index = profiles.firstIndex(where: {
                $0.direction == candidate.direction
                    && $0.targetPercent == candidate.targetPercent
                    && $0.sessionStart == candidate.sessionStart
            }) else {
                profiles.append(candidate)
                changed = true
                continue
            }
            let existing = profiles[index]
            guard !existing.isComplete else { continue }
            let existingBands = Set(existing.bands.map(\.lowerPercent))
            let candidateBands = Set(candidate.bands.map(\.lowerPercent))
            let extendsSession = candidate.sessionEnd > existing.sessionEnd
            let enrichesSameSession = candidate.sessionEnd == existing.sessionEnd
                && candidateBands.isStrictSuperset(of: existingBands)
            guard extendsSession || enrichesSameSession else { continue }
            profiles[index] = candidate
            changed = true
        }
        if changed { profiles.sort { $0.sessionEnd < $1.sessionEnd } }
        return changed
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

    func latestCompleteSessionEnd(direction: BatteryTimeProfile.Direction,
                                  targetPercent: Int) -> Date? {
        profiles.lazy.filter {
            $0.direction == direction && $0.targetPercent == targetPercent
                && $0.isComplete
        }.map(\.sessionEnd).max()
    }

    func hasProfile(direction: BatteryTimeProfile.Direction,
                    targetPercent: Int, now: Date) -> Bool {
        profiles.contains {
            $0.direction == direction && $0.targetPercent == targetPercent
                && $0.isComplete
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
        let observations = profiles.compactMap { profile -> (BatteryTimeProfile, BatteryLongTermBaseline.Observation)? in
            guard profile.direction == direction, profile.targetPercent == targetPercent,
                  profile.sessionEnd <= now,
                  now.timeIntervalSince(profile.sessionEnd) <= BatteryLongTermBaseline.retentionHorizon,
                  let band = profile.bands.first(where: { $0.lowerPercent == lowerPercent }),
                  band.minutes.isFinite, band.minutes > 0 else { return nil }
            return (profile, BatteryLongTermBaseline.Observation(
                value: band.minutes, duration: 1, date: profile.sessionEnd
            ))
        }
        let completeObservations = observations.filter { $0.0.isComplete }.map(\.1)
        let partialObservations = observations.filter { !$0.0.isComplete }.map(\.1)
        // The 90-95% charging band is the terminal taper. Partial sessions
        // stop before it, and a damaged stored profile must not train it.
        let usablePartialObservations = direction == .charging && lowerPercent >= 90
            ? [] : partialObservations
        let completeMedian = BatteryLongTermBaseline.robustWeightedMedian(
            completeObservations, now: now
        )
        let partialMedian = BatteryLongTermBaseline.robustWeightedMedian(
            usablePartialObservations, now: now
        )
        switch (partialMedian, completeMedian) {
        case (nil, nil):
            return nil
        case (let partial?, nil):
            return partial
        case (nil, let complete?):
            return complete
        case (let partial?, let complete?):
            // Charging power varies more across partial sessions, so require
            // more observations before they move a completed charge curve.
            let priorFloor: Double = direction == .charging ? 10 : 2
            let priorStrength = min(max(Double(completeObservations.count), priorFloor), 10)
            let partialWeight = Double(usablePartialObservations.count)
                / (Double(usablePartialObservations.count) + priorStrength)
            return partial * partialWeight + complete * (1 - partialWeight)
        }
    }

    private mutating func removePartialProfiles(sameSessionStartAs profile: BatteryTimeProfile) {
        profiles.removeAll {
            !$0.isComplete
                && $0.direction == profile.direction
                && $0.targetPercent == profile.targetPercent
                && $0.sessionStart == profile.sessionStart
        }
    }
}
