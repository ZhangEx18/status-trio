import XCTest
@testable import StatusTrioCore

final class AudioPanelTabTests: XCTestCase {
    func testTabsHaveStablePersistenceValuesAndOrder() {
        XCTAssertEqual(AudioPanelTab.allCases, [.output, .input])
        XCTAssertEqual(AudioPanelTab.output.rawValue, "output")
        XCTAssertEqual(AudioPanelTab.input.rawValue, "input")
    }
}
