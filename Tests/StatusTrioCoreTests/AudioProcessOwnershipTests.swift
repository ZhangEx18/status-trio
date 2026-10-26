import XCTest
@testable import StatusTrioCore

final class AudioProcessOwnershipTests: XCTestCase {
    func testUnregisteredEdgeAudioHelperResolvesThroughParentProcess() {
        let parents: [Int32: Int32] = [6495: 15022, 15022: 1]
        XCTAssertEqual(AudioProcessOwnerResolver.ownerPID(processID: 6495, processURL: nil,
            applicationURLs: [15022: URL(fileURLWithPath: "/Applications/Microsoft Edge.app")],
            parentPID: { parents[$0] }), 15022)
    }

    func testExecutablePathResolvesHelperWithoutAppKitMetadata() {
        XCTAssertEqual(AudioProcessOwnerResolver.ownerPID(processID: 90,
            processURL: URL(fileURLWithPath: "/Applications/Microsoft Edge.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"),
            applicationURLs: [20: URL(fileURLWithPath: "/Applications/Microsoft Edge.app")],
            parentPID: { _ in nil }), 20)
    }

    func testUnrelatedPrefixesAndParentCyclesDoNotMatchAnApp() {
        XCTAssertNil(AudioProcessOwnerResolver.ownerPID(processID: 90,
            processURL: URL(fileURLWithPath: "/Applications/Player.app.other/Helper"),
            applicationURLs: [20: URL(fileURLWithPath: "/Applications/Player.app")],
            parentPID: { $0 == 90 ? 91 : 90 }))
    }

    func testPlayedAppDisappearsOnExitAndReturnsWithFreshProcessOnRelaunch() {
        var history = AudioProcessAppHistory()
        let original = app(pid: 20)
        let audio = app(pid: 20, objects: [201])
        XCTAssertTrue(history.update(livingApps: [original], audioProcesses: []).isEmpty)
        XCTAssertEqual(history.update(livingApps: [original], audioProcesses: [audio]), [audio])
        XCTAssertTrue(history.update(livingApps: [], audioProcesses: []).isEmpty)
        let relaunched = app(pid: 30)
        XCTAssertEqual(history.update(livingApps: [relaunched], audioProcesses: []), [relaunched])
        let newAudio = app(pid: 30, objects: [301])
        XCTAssertEqual(history.update(livingApps: [relaunched], audioProcesses: [newAudio]), [newAudio])
        XCTAssertTrue(history.update(livingApps: [], audioProcesses: [audio]).isEmpty)
    }

    private func app(pid: Int32, objects: [UInt32] = []) -> AudioAppDescriptor {
        AudioAppDescriptor(processID: pid, processObjectIDs: objects,
            bundleIdentifier: "tv.danmaku.bili", displayName: "哔哩哔哩", isSystemProcess: false)
    }
}
