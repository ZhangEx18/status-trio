import Foundation

/// Shared training boundary policy. Unknown old segment changes are never bridged.
enum BatterySampleContinuity {
    static func canContinue(_ previous: BatteryTimeEstimator.Sample,
                            _ next: BatteryTimeEstimator.Sample) -> Bool {
        let gap = next.date.timeIntervalSince(previous.date)
        let change = next.percentage - previous.percentage
        return gap > 0 && gap <= BatteryTimeEstimator.maximumGap
            && previous.segment == next.segment && next.boundaryReason == nil
            && previous.mode == next.mode && previous.target == next.target
            && previous.mode != .idle && previous.source == .iops && next.source == .iops
            && abs(change) <= BatteryTimeEstimator.maximumSegmentCapacityChange
            && (previous.mode == .charging ? change >= 0 : change <= 0)
    }

    static func canFinishCharge(_ previous: BatteryTimeEstimator.Sample,
                                _ next: BatteryTimeEstimator.Sample, target: Int) -> Bool {
        let gap = next.date.timeIntervalSince(previous.date)
        let change = next.percentage - previous.percentage
        return previous.mode == .charging && previous.target == Double(target)
            && next.mode == .idle && next.connectedToPower
            && next.boundaryReason == .powerTransition
            && previous.source == .iops && next.source == .iops
            && gap > 0 && gap <= BatteryTimeEstimator.maximumGap
            && change >= 0 && change <= BatteryTimeEstimator.maximumSegmentCapacityChange
            && next.percentage >= Double(target)
    }
}
