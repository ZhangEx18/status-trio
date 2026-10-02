import Foundation

/// Prefer the app's time estimator; use the on-demand system reading only when
/// the estimator has no result.
enum BatteryRemainingTimePresentation {
    static func minutes(battery: BatteryStatus, details: BatteryDetails?) -> Int? {
        guard battery.isPresent, !battery.isConnectedToPower, !battery.isCharging else { return nil }
        if let estimate = battery.remainingMinutes, estimate > 0 { return estimate }
        return details?.remainingMinutes.flatMap { $0 > 0 ? $0 : nil }
    }
}
