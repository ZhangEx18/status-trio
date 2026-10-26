import Foundation

/// The detail collector reads IOPS on each refresh. Once it has a result,
/// unknown means calculating; an older summary value must not hide that state.
enum BatteryRemainingTimePresentation {
    static func minutes(battery: BatteryStatus, details: BatteryDetails?) -> Int? {
        guard battery.isPresent, !battery.isConnectedToPower, !battery.isCharging else { return nil }
        let value: Int?
        if let details { value = details.remainingMinutes }
        else { value = battery.remainingMinutes }
        return value.flatMap { $0 > 0 ? $0 : nil }
    }
}
