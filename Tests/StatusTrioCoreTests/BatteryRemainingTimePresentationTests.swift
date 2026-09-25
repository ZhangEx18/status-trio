import XCTest
@testable import StatusTrioCore

final class BatteryRemainingTimePresentationTests: XCTestCase {
    private let battery = BatteryStatus(rawPercentage: 95, isPresent: true, isCharging: false,
        remainingMinutes: 258, isLowPowerMode: false, isConnectedToPower: false)

    func testFreshEstimateReplacesOlderSummaryWithoutInflatingIt() {
        XCTAssertEqual(BatteryRemainingTimePresentation.minutes(battery: battery,
            details: BatteryDetails(remainingMinutes: 351)), 351)
        XCTAssertEqual(BatteryRemainingTimePresentation.minutes(battery: battery,
            details: BatteryDetails(remainingMinutes: 180)), 180)
    }

    func testUnknownFreshEstimateDoesNotReuseStaleSummary() {
        XCTAssertNil(BatteryRemainingTimePresentation.minutes(battery: battery, details: BatteryDetails()))
        XCTAssertEqual(BatteryRemainingTimePresentation.minutes(battery: battery, details: nil), 258)
    }
}
