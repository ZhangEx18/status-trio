import Foundation

struct BatteryTimeProfile: Codable, Equatable, Sendable {
    static let profiledChargeTargetPercent = 95
    static let profiledDischargeReservePercent = 5

    enum Direction: String, Codable, Hashable, Sendable {
        case charging
        case discharging
    }

    struct Band: Codable, Equatable, Sendable {
        let lowerPercent: Int
        let minutes: Double
    }

    let direction: Direction
    let targetPercent: Int
    let sessionStart: Date
    let sessionEnd: Date
    let sessionStartPercent: Double
    let sessionEndPercent: Double
    let bands: [Band]
}
