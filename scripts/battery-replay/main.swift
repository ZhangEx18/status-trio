import Foundation

// Standalone harness: compiled with the actual estimator sources, never opens UserDefaults.
func jsonValue(_ value: Any) -> Any? {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
        return mirror.children.first.flatMap { jsonValue($0.value) }
    }
    if let date = value as? Date { return date.timeIntervalSince1970 }
    if let number = value as? Double { return number.isFinite ? number : nil }
    if let number = value as? Int { return number }
    if let flag = value as? Bool { return flag }
    if let string = value as? String { return string }
    return nil
}

var estimator = BatteryTimeEstimator()
var catalog = BatteryTimeProfileCatalog()
var lastCaptureKey: String?
#if CANDIDATE
var lastPartialProfileSegment: Int?
#endif
let input = FileHandle.standardInput
let output = FileHandle.standardOutput
let lines = String(decoding: input.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
for line in lines {
    let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
    let date = Date(timeIntervalSince1970: row["timestamp"] as! Double)
    let percentage = row["percentage"] as! Double
    let charging = row["charging"] as! Bool
    let connected = row["connectedToPower"] as! Bool
    let target = row["target"] as? Double
    let system = row["system"] as? Int
    if row["dirty"] as? Bool == true { estimator.markDirtyInterval() }
    let estimate = estimator.add(date: date, percentage: percentage, charging: charging,
                                 target: target, connectedToPower: connected, systemMinutes: system)
    var result: [String: Any] = ["timestamp": date.timeIntervalSince1970,
                               "profileCount": catalog.profiles.count]
    if let estimate { result["minutes"] = estimate }
    for field in Mirror(reflecting: estimator.diagnostics).children {
        if let key = field.label, let value = jsonValue(field.value) { result[key] = value }
    }
    if let newest = estimator.persistedSamples.last {
        result["segment"] = newest.segment
        let reachedTarget: Bool = switch newest.mode {
        case .charging: newest.target.map { newest.percentage >= $0 } ?? false
        case .discharging: newest.percentage <= 5
        case .idle: false
        }
        let key = "\(newest.mode)-\(String(describing: newest.target))-\(newest.segment)"
        if reachedTarget && key != lastCaptureKey {
            lastCaptureKey = key
            for profile in BatteryTimeProfileBuilder.latestCompleteProfiles(from: estimator.persistedSamples).profiles {
                // Completion must be in the observed past; never seed from future rows.
                precondition(profile.sessionEnd <= date)
                _ = catalog.addIfNewer(profile, now: date)
            }
            estimator.updateProfiles(catalog.hasBidirectionalProfiles(now: date) ? catalog : .init())
        }
        #if CANDIDATE
        if newest.segment != lastPartialProfileSegment {
            if catalog.mergePartialProfiles(
                BatteryTimeProfileBuilder.partialProfiles(from: estimator.persistedSamples),
                now: date
            ) {
                estimator.updateProfiles(
                    catalog.hasBidirectionalProfiles(now: date) ? catalog : .init()
                )
            }
            lastPartialProfileSegment = newest.segment
        }
        #endif
    }
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    output.write(data)
    output.write(Data([10]))
}
