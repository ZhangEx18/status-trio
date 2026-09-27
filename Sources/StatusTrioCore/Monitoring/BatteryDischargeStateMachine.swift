import Foundation

/// Asymmetric live-load detector: entering high load needs three consecutive
/// non-overlapping fast intervals, while one recovered interval exits it.
struct BatteryDischargeStateMachine: Sendable {
    enum State: String, Sendable {
        case baseline
        case transient
        case highLoad
    }

    static let highLoadEntryRatio = 1.35
    static let highLoadExitRatio = 1.15
    static let requiredFastIntervals = 3

    private(set) var state: State = .baseline
    private(set) var consecutiveFastIntervals = 0

    mutating func reset() {
        state = .baseline
        consecutiveFastIntervals = 0
    }

    mutating func update(baseline: Double, recentIntervals: [Double]) {
        guard baseline > 0, let latest = recentIntervals.last else {
            if state != .highLoad { state = .baseline }
            consecutiveFastIntervals = 0
            return
        }

        if state == .highLoad, latest <= baseline * Self.highLoadExitRatio {
            state = .baseline
            consecutiveFastIntervals = 0
            return
        }

        if latest >= baseline * Self.highLoadEntryRatio {
            consecutiveFastIntervals += 1
        } else {
            consecutiveFastIntervals = 0
        }
        let tail = recentIntervals.suffix(Self.requiredFastIntervals)
        if consecutiveFastIntervals >= Self.requiredFastIntervals
            || (tail.count == Self.requiredFastIntervals
                && tail.allSatisfy({ $0 >= baseline * Self.highLoadEntryRatio })) {
            state = .highLoad
            consecutiveFastIntervals = Self.requiredFastIntervals
        } else if latest > baseline * 1.20 {
            state = state == .highLoad ? .highLoad : .transient
        } else if state != .highLoad {
            state = .baseline
            consecutiveFastIntervals = 0
        }
    }

    func selectedRate(baseline: Double, recent: Double?) -> Double {
        guard let recent, recent.isFinite, recent > 0 else { return baseline }
        switch state {
        case .baseline: return baseline
        case .transient: return baseline * 0.6 + recent * 0.4
        case .highLoad: return recent
        }
    }

    func weight(forDistance distance: Double, horizon: Double = 10) -> Double {
        let decay = exp(-max(0, distance) / horizon)
        switch state {
        case .baseline: return 0
        case .transient: return 0.4 * decay
        case .highLoad: return decay
        }
    }
}
