import Foundation

/// Asymmetric live-load detector: entering high load needs two consecutive
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
    static let requiredFastIntervals = 2
    static let lowLoadEntryRatio = 0.75
    static let lowLoadExitRatio = 0.85
    static let requiredSlowIntervals = 3

    private(set) var state: State = .baseline
    private(set) var consecutiveFastIntervals = 0
    private(set) var consecutiveSlowIntervals = 0

    mutating func reset() {
        state = .baseline
        consecutiveFastIntervals = 0
        consecutiveSlowIntervals = 0
        lastConsumed = nil
    }

    struct Interval: Sendable {
        let segment: Int
        let start: Date
        let end: Date
        let rate: Double
    }
    private var lastConsumed: Interval?

    mutating func update(baseline: Double, recentIntervals: [Interval]) {
        guard baseline.isFinite, baseline > 0 else { reset(); return }
        for interval in recentIntervals.sorted(by: { $0.end < $1.end }) {
            guard interval.end > interval.start, interval.rate.isFinite, interval.rate > 0 else { continue }
            if let last = lastConsumed {
                if interval.segment != last.segment { reset() }
                else if interval.start < last.end || interval.end <= last.end { continue }
            }
            lastConsumed = interval
            consume(baseline: baseline, latest: interval.rate)
        }
    }

    private mutating func consume(baseline: Double, latest: Double) {
        if (state == .highLoad && latest <= baseline * Self.highLoadExitRatio)
            || (state == .lowLoad && latest >= baseline * Self.lowLoadExitRatio) {
            state = .baseline
            consecutiveFastIntervals = 0
            consecutiveSlowIntervals = 0
            return
        }
        consecutiveFastIntervals = latest >= baseline * Self.highLoadEntryRatio
            ? consecutiveFastIntervals + 1 : 0
        consecutiveSlowIntervals = latest <= baseline * Self.lowLoadEntryRatio
            ? consecutiveSlowIntervals + 1 : 0
        if consecutiveFastIntervals >= Self.requiredFastIntervals {
            state = .highLoad
            consecutiveFastIntervals = Self.requiredFastIntervals
            consecutiveSlowIntervals = 0
        } else if consecutiveSlowIntervals >= Self.requiredSlowIntervals {
            state = .lowLoad
            consecutiveSlowIntervals = Self.requiredSlowIntervals
            consecutiveFastIntervals = 0
        } else if latest > baseline * 1.20 || latest < baseline * 0.80 {
            if state != .highLoad && state != .lowLoad { state = .transient }
        } else if state != .highLoad && state != .lowLoad {
            state = .baseline
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
