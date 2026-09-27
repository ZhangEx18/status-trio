import Foundation

/// Asymmetric live-load detector: entering high load needs three consecutive
/// non-overlapping fast intervals, while one recovered interval exits it.
struct BatteryDischargeStateMachine: Sendable {
    enum State: String, Sendable {
        case baseline
        case transient
        case highLoad
        case lowLoad
    }

    static let highLoadEntryRatio = 1.35
    static let highLoadExitRatio = 1.15
    static let requiredFastIntervals = 3
    static let lowLoadEntryRatio = 0.75
    static let lowLoadExitRatio = 0.85
    static let requiredSlowIntervals = 5

    private(set) var state: State = .baseline
    private(set) var consecutiveFastIntervals = 0
    private(set) var consecutiveSlowIntervals = 0

    mutating func reset() {
        state = .baseline
        consecutiveFastIntervals = 0
        consecutiveSlowIntervals = 0
    }

    mutating func update(baseline: Double, recentIntervals: [Double]) {
        guard baseline > 0, let latest = recentIntervals.last else {
            if state != .highLoad { state = .baseline }
            consecutiveFastIntervals = 0
            consecutiveSlowIntervals = 0
            return
        }

        if state == .highLoad, latest <= baseline * Self.highLoadExitRatio {
            state = .baseline
            consecutiveFastIntervals = 0
            consecutiveSlowIntervals = 0
            return
        }
        if state == .lowLoad, latest >= baseline * Self.lowLoadExitRatio {
            state = .baseline
            consecutiveFastIntervals = 0
            consecutiveSlowIntervals = 0
            return
        }

        if latest >= baseline * Self.highLoadEntryRatio {
            consecutiveFastIntervals += 1
        } else {
            consecutiveFastIntervals = 0
        }
        if latest <= baseline * Self.lowLoadEntryRatio {
            consecutiveSlowIntervals += 1
        } else {
            consecutiveSlowIntervals = 0
        }
        let tail = recentIntervals.suffix(Self.requiredFastIntervals)
        let slowTail = recentIntervals.suffix(Self.requiredSlowIntervals)
        if consecutiveFastIntervals >= Self.requiredFastIntervals
            || (tail.count == Self.requiredFastIntervals
                && tail.allSatisfy({ $0 >= baseline * Self.highLoadEntryRatio })) {
            state = .highLoad
            consecutiveFastIntervals = Self.requiredFastIntervals
            consecutiveSlowIntervals = 0
        } else if consecutiveSlowIntervals >= Self.requiredSlowIntervals
            || (slowTail.count == Self.requiredSlowIntervals
                && slowTail.allSatisfy({ $0 <= baseline * Self.lowLoadEntryRatio })) {
            state = .lowLoad
            consecutiveSlowIntervals = Self.requiredSlowIntervals
            consecutiveFastIntervals = 0
        } else if latest > baseline * 1.20 {
            state = .transient
            consecutiveSlowIntervals = 0
        } else if latest < baseline * 0.80 {
            state = .transient
            consecutiveFastIntervals = 0
        } else if state != .highLoad && state != .lowLoad {
            state = .baseline
            consecutiveFastIntervals = 0
            consecutiveSlowIntervals = 0
        }
    }

    func selectedRate(baseline: Double, recent: Double?) -> Double {
        guard let recent, recent.isFinite, recent > 0 else { return baseline }
        switch state {
        case .baseline: return baseline
        case .transient:
            // Blend minutes per percentage point, not rates. A 15 minute
            // sample and a 9 minute baseline must produce 12.6 minutes.
            let baselineMinutes = 1 / baseline
            let recentMinutes = 1 / recent
            return 1 / (baselineMinutes * 0.4 + recentMinutes * 0.6)
        case .highLoad, .lowLoad: return recent
        }
    }

    func weight(forDistance distance: Double, horizon: Double = 10) -> Double {
        let decay = exp(-max(0, distance) / horizon)
        switch state {
        case .baseline: return 0
        case .transient: return 0.4 * decay
        case .highLoad, .lowLoad: return decay
        }
    }
}
