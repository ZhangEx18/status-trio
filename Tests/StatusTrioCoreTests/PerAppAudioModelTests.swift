import XCTest
@testable import StatusTrioCore

final class PerAppAudioModelTests: XCTestCase {
    func testAudioAppDescriptorUsesBundleIDAsStableIdentity() {
        let app = AudioAppDescriptor(
            processID: 42,
            processObjectIDs: [100, 101],
            bundleIdentifier: "com.example.Player",
            displayName: "Player",
            isSystemProcess: false
        )

        XCTAssertEqual(app.id, "com.example.Player")
        XCTAssertEqual(app.persistenceIdentifier, "com.example.Player")
        XCTAssertEqual(app.processObjectIDs, [100, 101])
    }

    func testAudioAppDescriptorFallsBackToProcessIdentityWithoutBundleID() {
        let app = AudioAppDescriptor(
            processID: 42,
            processObjectIDs: [100],
            bundleIdentifier: nil,
            displayName: "Unknown",
            isSystemProcess: false
        )

        XCTAssertEqual(app.id, "pid:42")
        XCTAssertEqual(app.persistenceIdentifier, "pid:42")
    }

    func testPerAppAudioSettingsClampVolumeAndNormalizeRouting() {
        var settings = PerAppAudioSettings(volume: 8, isMuted: false, routing: .explicit, outputDeviceUIDs: ["", "speaker", "speaker"])

        settings.normalize()

        XCTAssertEqual(settings.volume, 4)
        XCTAssertEqual(settings.routing, .explicit)
        XCTAssertEqual(settings.outputDeviceUIDs, ["speaker"])
    }

    func testFollowDefaultRoutingClearsExplicitDevices() {
        var settings = PerAppAudioSettings(
            volume: 0.5,
            isMuted: true,
            routing: .followSystemDefault,
            outputDeviceUIDs: ["speaker"]
        )

        settings.normalize()

        XCTAssertEqual(settings.routing, .followSystemDefault)
        XCTAssertTrue(settings.outputDeviceUIDs.isEmpty)
    }

    func testProcessIdentityIsHashableAndCodable() throws {
        let identity = AudioAppProcessIdentity(processID: 42, objectIDs: [100, 101])
        let data = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(AudioAppProcessIdentity.self, from: data)

        XCTAssertEqual(decoded, identity)
        XCTAssertEqual(Set([identity]).count, 1)
    }
}
