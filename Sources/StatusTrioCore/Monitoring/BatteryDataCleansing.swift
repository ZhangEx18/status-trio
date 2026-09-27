import Foundation

/// The small, deterministic boundary between IOPS readings and the models.
/// Keeping this classification separate prevents UI rounding, sleep gaps and
/// external-power holds from becoming training samples.
struct BatteryDataCleaner {
    enum Mode: String, Sendable {
        case charging
        case discharging
        case mixedPower
        case unavailable
    }

    struct CleanReading: Equatable, Sendable {
        let percentage: Double
        let mode: Mode
        let isBoundary: Bool
    }

    static func percentage(currentCapacity: Int, maxCapacity: Int) -> Double? {
        guard currentCapacity >= 0 else { return nil }
        // A few virtualized/test power sources omit MaxCapacity.  Preserve
        // their already-normalized value as a last-resort display fallback;
        // real IOPS samples still take the exact capacity ratio below.
        guard maxCapacity > 0 else {
            return (0...100).contains(currentCapacity) ? Double(currentCapacity) : nil
        }
        guard currentCapacity <= maxCapacity else { return nil }
        let value = Double(currentCapacity) / Double(maxCapacity) * 100
        return value.isFinite ? min(100, max(0, value)) : nil
    }

    /// Connected-but-not-charging is intentionally a separate mode. It covers
    /// both optimized-charge holds and battery bypass/mixed-power operation;
    /// neither interval is allowed into the pure discharge baseline.
    static func mode(connectedToPower: Bool, charging: Bool, isPresent: Bool) -> Mode {
        guard isPresent else { return .unavailable }
        if charging { return .charging }
        return connectedToPower ? .mixedPower : .discharging
    }

    static func clean(currentCapacity: Int, maxCapacity: Int,
                      connectedToPower: Bool, charging: Bool,
                      isPresent: Bool, startsBoundary: Bool = false) -> CleanReading? {
        guard let percentage = percentage(currentCapacity: currentCapacity,
                                           maxCapacity: maxCapacity) else { return nil }
        return CleanReading(
            percentage: percentage,
            mode: mode(connectedToPower: connectedToPower,
                       charging: charging,
                       isPresent: isPresent),
            isBoundary: startsBoundary
        )
    }
}
