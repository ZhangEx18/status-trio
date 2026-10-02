import Foundation

struct BatteryTimeProfileBuilder {
    static func latestCompleteProfile(
        from samples: [BatteryTimeEstimator.Sample],
        direction: BatteryTimeProfile.Direction,
        targetPercent: Int
    ) -> BatteryTimeProfile? {
        completedProfiles(from: samples, direction: direction, targetPercent: targetPercent)
            .max { $0.sessionEnd < $1.sessionEnd }
    }

    static func latestCompleteProfiles(
        from samples: [BatteryTimeEstimator.Sample]
    ) -> BatteryTimeProfileCatalog {
        let chargeProfile = latestCompleteProfile(
            from: samples, direction: .charging,
            targetPercent: BatteryTimeProfile.profiledChargeTargetPercent
        )
        let dischargeProfile = latestCompleteProfile(
            from: samples, direction: .discharging,
            targetPercent: BatteryTimeProfile.profiledDischargeReservePercent
        )
        return BatteryTimeProfileCatalog(profiles: [chargeProfile, dischargeProfile].compactMap { $0 })
    }

    private static func completedProfiles(
        from samples: [BatteryTimeEstimator.Sample],
        direction: BatteryTimeProfile.Direction,
        targetPercent: Int
    ) -> [BatteryTimeProfile] {
        let sessions = sessionSegments(from: samples, direction: direction, targetPercent: targetPercent)
        return sessions.compactMap {
            completedProfile(in: $0, direction: direction, targetPercent: targetPercent)
        }
    }

    private static func sessionSegments(
        from samples: [BatteryTimeEstimator.Sample],
        direction: BatteryTimeProfile.Direction,
        targetPercent: Int
    ) -> [[BatteryTimeEstimator.Sample]] {
        let chronologicalSamples = samples.sorted { $0.date < $1.date }
        var sessions: [[BatteryTimeEstimator.Sample]] = []
        var currentSession: [BatteryTimeEstimator.Sample] = []

        for sample in chronologicalSamples {
            guard isSessionSample(sample, direction: direction, targetPercent: targetPercent) else {
                if !currentSession.isEmpty { sessions.append(currentSession) }
                currentSession = []
                continue
            }
            if !currentSession.isEmpty
                && !canContinue(currentSession, with: sample, direction: direction) {
                sessions.append(currentSession)
                currentSession = []
            }
            currentSession.append(sample)
        }
        if !currentSession.isEmpty { sessions.append(currentSession) }
        return sessions
    }

    private static func isSessionSample(
        _ sample: BatteryTimeEstimator.Sample,
        direction: BatteryTimeProfile.Direction,
        targetPercent: Int
    ) -> Bool {
        isActive(sample, direction: direction, targetPercent: targetPercent)
            || isTransitionSample(sample, direction: direction, targetPercent: targetPercent)
    }

    private static func isActive(
        _ sample: BatteryTimeEstimator.Sample,
        direction: BatteryTimeProfile.Direction,
        targetPercent: Int
    ) -> Bool {
        guard sample.source == .iops || sample.source == .thermal else { return false }
        switch direction {
        case .charging:
            return sample.mode == .charging && sample.target == Double(targetPercent)
        case .discharging:
            return sample.mode == .discharging && sample.target == 0
        }
    }

    private static func isTransitionSample(
        _ sample: BatteryTimeEstimator.Sample,
        direction: BatteryTimeProfile.Direction,
        targetPercent: Int
    ) -> Bool {
        guard sample.source == .iops, sample.mode == .idle, sample.connectedToPower else { return false }
        return direction == .charging || sample.percentage <= Double(targetPercent)
    }

    private static func canContinue(
        _ session: [BatteryTimeEstimator.Sample],
        with sample: BatteryTimeEstimator.Sample,
        direction: BatteryTimeProfile.Direction
    ) -> Bool {
        guard let previous = session.last else { return false }
        let gap = sample.date.timeIntervalSince(previous.date)
        guard gap > 0, gap <= BatteryTimeEstimator.maximumGap else { return false }
        return direction == .charging
            ? sample.percentage >= previous.percentage
            : sample.percentage <= previous.percentage
    }

    private static func completedProfile(
        in session: [BatteryTimeEstimator.Sample],
        direction: BatteryTimeProfile.Direction,
        targetPercent: Int
    ) -> BatteryTimeProfile? {
        guard let startSample = session.first(where: {
            isActive($0, direction: direction, targetPercent: targetPercent)
        }),
        let endpointSample = session.first(where: {
            isSessionSample($0, direction: direction, targetPercent: targetPercent)
                && isAtTarget($0, direction: direction, targetPercent: targetPercent)
        }), endpointSample.date > startSample.date,
        hasExpectedProgress(start: startSample.percentage, end: endpointSample.percentage,
                           direction: direction, targetPercent: targetPercent) else { return nil }

        let trainingSamples = Array(session.prefix { $0.date <= endpointSample.date })
        let profileBands = measuredBands(in: trainingSamples, direction: direction,
                                         targetPercent: targetPercent, date: endpointSample.date)
        guard !profileBands.isEmpty else { return nil }
        return BatteryTimeProfile(direction: direction, targetPercent: targetPercent,
                                  sessionStart: startSample.date, sessionEnd: endpointSample.date,
                                  sessionStartPercent: startSample.percentage,
                                  sessionEndPercent: endpointSample.percentage, bands: profileBands)
    }

    private static func hasExpectedProgress(
        start: Double,
        end: Double,
        direction: BatteryTimeProfile.Direction,
        targetPercent: Int
    ) -> Bool {
        direction == .charging
            ? start < Double(targetPercent) && end >= Double(targetPercent)
            : start > Double(targetPercent) && end <= Double(targetPercent)
    }

    private static func isAtTarget(
        _ sample: BatteryTimeEstimator.Sample,
        direction: BatteryTimeProfile.Direction,
        targetPercent: Int
    ) -> Bool {
        direction == .charging
            ? sample.percentage >= Double(targetPercent)
            : sample.percentage <= Double(targetPercent)
    }

    private static func measuredBands(
        in samples: [BatteryTimeEstimator.Sample],
        direction: BatteryTimeProfile.Direction,
        targetPercent: Int,
        date: Date
    ) -> [BatteryTimeProfile.Band] {
        let estimator = BatteryTimeEstimator(samples: samples)
        let mode: BatteryTimeEstimator.Mode = direction == .charging ? .charging : .discharging
        let sampleTarget = direction == .charging ? Double(targetPercent) : 0
        let observations = estimator.completedBands(mode: mode, target: sampleTarget,
            segmentPolicy: .verifiedContinuousSamples)
        var groupedObservations = Dictionary(grouping: observations, by: \.lowerPercent)
        let terminalBand = targetPercent - 5
        if direction == .charging,
           targetPercent == BatteryTimeProfile.profiledChargeTargetPercent,
           groupedObservations[terminalBand, default: []].isEmpty,
           let terminalObservation = terminalChargeBand(in: samples, targetPercent: targetPercent) {
            groupedObservations[terminalBand, default: []].append(terminalObservation)
        }
        return groupedObservations.keys.sorted().compactMap { lowerPercent in
            measuredBand(lowerPercent, from: groupedObservations[lowerPercent] ?? [], at: date)
        }
    }

    private static func terminalChargeBand(
        in samples: [BatteryTimeEstimator.Sample],
        targetPercent: Int
    ) -> BatteryTimeEstimator.BandObservation? {
        guard samples.count >= 3,
              let terminal = samples.last,
              terminal.mode == .idle,
              terminal.connectedToPower,
              terminal.source == .iops,
              terminal.percentage >= Double(targetPercent) else { return nil }

        func isActiveCharge(_ sample: BatteryTimeEstimator.Sample) -> Bool {
            sample.mode == .charging && sample.target == Double(targetPercent)
                && sample.connectedToPower && sample.source == .iops
        }

        let lowerPercent = targetPercent - 5
        var crossing: (nextIndex: Int, date: Date)?
        for index in 0..<(samples.count - 2) {
            let previous = samples[index]
            let next = samples[index + 1]
            guard isActiveCharge(previous), isActiveCharge(next) else { continue }
            let gap = next.date.timeIntervalSince(previous.date)
            let change = next.percentage - previous.percentage
            guard gap > 0, gap <= BatteryTimeEstimator.maximumGap,
                  change >= 0, change <= BatteryTimeEstimator.maximumSegmentCapacityChange,
                  previous.percentage <= Double(lowerPercent),
                  next.percentage >= Double(lowerPercent), change > 0 else { continue }
            let fraction = (Double(lowerPercent) - previous.percentage) / change
            crossing = (index + 1, previous.date.addingTimeInterval(gap * fraction))
        }

        guard let crossing else { return nil }
        var previous = samples[crossing.nextIndex]
        guard isActiveCharge(previous) else { return nil }
        for index in (crossing.nextIndex + 1)..<samples.count {
            let current = samples[index]
            let isTerminal = index == samples.count - 1
            guard current.source == .iops, current.connectedToPower,
                  isTerminal ? current.mode == .idle : isActiveCharge(current) else { return nil }
            let gap = current.date.timeIntervalSince(previous.date)
            let change = current.percentage - previous.percentage
            guard gap > 0, gap <= BatteryTimeEstimator.maximumGap,
                  change >= 0, change <= BatteryTimeEstimator.maximumSegmentCapacityChange else {
                return nil
            }
            previous = current
        }

        let activeBeforeTerminal = samples[samples.count - 2]
        let terminalGap = terminal.date.timeIntervalSince(activeBeforeTerminal.date)
        let terminalChange = terminal.percentage - activeBeforeTerminal.percentage
        guard terminalGap > 0, terminalChange > 0,
              activeBeforeTerminal.percentage < Double(targetPercent) else { return nil }
        let targetFraction = min(1, (Double(targetPercent) - activeBeforeTerminal.percentage) / terminalChange)
        let targetDate = activeBeforeTerminal.date.addingTimeInterval(terminalGap * targetFraction)
        let minutes = targetDate.timeIntervalSince(crossing.date) / 60
        guard (2.5...500).contains(minutes) else { return nil }
        return BatteryTimeEstimator.BandObservation(lowerPercent: lowerPercent,
            minutes: minutes, date: targetDate, segment: terminal.segment)
    }

    private static func measuredBand(
        _ lowerPercent: Int,
        from observations: [BatteryTimeEstimator.BandObservation],
        at date: Date
    ) -> BatteryTimeProfile.Band? {
        let weightedObservations = observations.map {
            BatteryLongTermBaseline.Observation(value: $0.minutes, duration: 1, date: $0.date)
        }
        guard let minutes = BatteryLongTermBaseline.robustWeightedMedian(weightedObservations, now: date) else {
            return nil
        }
        return BatteryTimeProfile.Band(lowerPercent: lowerPercent, minutes: minutes)
    }
}
