import XCTest
@testable import StatusTrioCore

@MainActor
final class AudioCapturePermissionControllerTests: XCTestCase {
    func testRefreshMapsPreflightToAuthorizedOrUnknown() {
        var granted = false
        let controller = AudioCapturePermissionController(
            preflight: { granted },
            requestAccess: { granted },
            openSettings: { true }
        )

        XCTAssertEqual(controller.status, .unknown)

        granted = true
        controller.refresh()

        XCTAssertEqual(controller.status, .authorized)
    }

    func testRequestPublishesDeniedWhenSystemRejectsAccess() {
        let controller = AudioCapturePermissionController(
            preflight: { false },
            requestAccess: { false },
            openSettings: { true }
        )

        XCTAssertFalse(controller.request())
        XCTAssertEqual(controller.status, .denied)
    }

    func testRequestPublishesAuthorizedWhenSystemGrantsAccess() {
        let controller = AudioCapturePermissionController(
            preflight: { false },
            requestAccess: { true },
            openSettings: { true }
        )

        XCTAssertTrue(controller.request())
        XCTAssertEqual(controller.status, .authorized)
    }

    func testOpenSettingsUsesStableScreenRecordingRoute() {
        var didOpen = false
        let controller = AudioCapturePermissionController(
            preflight: { false },
            requestAccess: { false },
            openSettings: {
                didOpen = true
                return true
            }
        )

        XCTAssertTrue(controller.openSystemSettings())
        XCTAssertTrue(didOpen)
        XCTAssertEqual(
            AudioCapturePermissionController.systemSettingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }
}
