import Foundation
import CoreFoundation

let domain = "com.lingsmbp.StatusTrio" as CFString
let keys = ["battery.timeEstimator.samples.v1", "battery.timeEstimator.profiles.v1"]
let arguments = CommandLine.arguments
guard arguments.count == 3 else { fatalError("usage: preferences export|restore file.plist") }
guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
    fatalError("preference synchronization failed")
}
if arguments[1] == "export" {
    let values = CFPreferencesCopyMultiple(nil, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
    let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
    try data.write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
} else if arguments[1] == "restore" {
    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    let values = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: Any]
    for key in keys {
        CFPreferencesSetValue(key as CFString, values[key] as CFPropertyList?, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
    guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
        fatalError("preference write failed")
    }
} else { fatalError("unknown operation") }
