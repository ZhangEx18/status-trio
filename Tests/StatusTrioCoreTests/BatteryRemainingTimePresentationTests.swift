import XCTest
@testable import StatusTrioCore

final class BatteryRemainingTimePresentationTests: XCTestCase {
    private let battery = BatteryStatus(rawPercentage: 95, isPresent: true, isCharging: false,
        remainingMinutes: 258, isLowPowerMode: false, isConnectedToPower: false)

    func testModelEstimateTakesPrecedenceOverSystemEstimate() {
        XCTAssertEqual(BatteryRemainingTimePresentation.minutes(battery: battery,
            details: BatteryDetails(remainingMinutes: 351)), 258)
        XCTAssertEqual(BatteryRemainingTimePresentation.minutes(battery: battery,
            details: BatteryDetails(remainingMinutes: 180)), 258)
    }

    func testSystemEstimateIsFallbackOnlyWhenModelEstimateIsUnavailable() {
        let noModelEstimate = BatteryStatus(rawPercentage: 95, isPresent: true, isCharging: false,
            remainingMinutes: nil, isLowPowerMode: false, isConnectedToPower: false)
        XCTAssertEqual(BatteryRemainingTimePresentation.minutes(battery: noModelEstimate,
            details: BatteryDetails(remainingMinutes: 351)), 351)
        XCTAssertNil(BatteryRemainingTimePresentation.minutes(battery: noModelEstimate,
            details: BatteryDetails()))
        XCTAssertEqual(BatteryRemainingTimePresentation.minutes(battery: battery, details: nil), 258)
    }
}
