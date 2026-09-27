import Foundation

/// Robust statistics for the long-lived battery baseline.  The estimator owns
/// the observations; this type owns only retention and weighting policy.
struct BatteryLongTermBaseline {
    struct Observation: Sendable {
        let value: Double
        let duration: TimeInterval
        let date: Date
    }

    static let retentionHorizon: TimeInterval = 60 * 24 * 60 * 60
    static let halfLife: TimeInterval = 14 * 24 * 60 * 60

    static func weightedMedian(_ observations: [Observation], now: Date? = nil) -> Double? {
        guard !observations.isEmpty else { return nil }
        let newest = now ?? observations.map(\.date).max()!
        let sorted = observations.sorted { $0.value < $1.value }
        func weight(_ observation: Observation) -> Double {
            max(0.001, observation.duration)
                * exp(-max(0, newest.timeIntervalSince(observation.date)) / halfLife)
        }
        let total = sorted.reduce(0.0) { $0 + weight($1) }
        var cumulative = 0.0
        for observation in sorted {
            cumulative += weight(observation)
            if cumulative >= total / 2 { return observation.value }
        }
        return sorted.last?.value
    }

    static func robustWeightedMedian(_ observations: [Observation], now: Date? = nil) -> Double? {
        guard let median = weightedMedian(observations, now: now) else { return nil }
        let deviations = observations.map { abs($0.value - median) }.sorted()
        let mad = deviations[deviations.count / 2]
        let tolerance = max(2.0, mad * 4)
        let filtered = observations.filter { abs($0.value - median) <= tolerance }
        return weightedMedian(filtered.isEmpty ? observations : filtered, now: now)
    }
}
