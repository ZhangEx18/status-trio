import Foundation

/// Charge-side physics is intentionally independent from discharge samples.
/// A cycle-local reference can be used to fill an unseen band, while learned
/// bands remain robust medians and never absorb a hot-cycle throttle.
struct BatteryChargingModel {
    static func minutes(from start: Double, to target: Double,
                        minutesPerPoint: Double) -> Double? {
        guard minutesPerPoint.isFinite, minutesPerPoint > 0, target > start else {
            return nil
        }
        var position = start
        var total = 0.0
        while position < target {
            let lower = floor(position / 5) * 5
            let next = min(target, lower + 5)
            let distance = next - position
            guard distance > 0 else { break }
            let multiplier: Double
            switch lower {
            case 80..<90: multiplier = 1.20
            case 90..<95: multiplier = 1.45
            case 95..<100: multiplier = 2.00
            default: multiplier = 1.0
            }
            total += minutesPerPoint * distance * multiplier
            position = next
        }
        return total > 0 ? total : nil
    }
}
