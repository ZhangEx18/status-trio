import XCTest
@testable import StatusTrioCore

@MainActor
final class AudioProcessMonitorTests: XCTestCase {
    func testSilentAppsAreExcludedUntilTheyHaveAudio() {
        let idle = AudioAppDescriptor(processID: 20, processObjectIDs: [],
            bundleIdentifier: "com.example.Player", displayName: "Player", isSystemProcess: false)
        let audio = AudioAppDescriptor(processID: 21, processObjectIDs: [201],
            bundleIdentifier: idle.bundleIdentifier, displayName: "Player Helper", isSystemProcess: false)
        XCTAssertTrue(AudioProcessListReducer.livingApps([idle], audioProcesses: []).isEmpty)
        XCTAssertEqual(AudioProcessListReducer.livingApps([idle], audioProcesses: [], knownIdentifiers: [idle.id]), [idle])
        let playing = AudioProcessListReducer.livingApps([idle], audioProcesses: [audio])
        XCTAssertEqual(playing.count, 1)
        XCTAssertEqual(playing.first?.processObjectIDs, [201])
        XCTAssertEqual(playing.first?.displayName, "Player")
        XCTAssertTrue(AudioProcessListReducer.livingApps([], audioProcesses: [audio]).isEmpty)
    }

    func testReducerDropsSystemProcessesAndMergesHelpersByBundleID() {
        let processes = [
            AudioAppDescriptor(processID: 10, processObjectIDs: [100], bundleIdentifier: "com.apple.coreaudio", displayName: "coreaudiod", isSystemProcess: true),
            AudioAppDescriptor(processID: 20, processObjectIDs: [200], bundleIdentifier: "com.example.Player", displayName: "Player", isSystemProcess: false),
            AudioAppDescriptor(processID: 21, processObjectIDs: [201], bundleIdentifier: "com.example.Player", displayName: "Player Helper", isSystemProcess: false)
        ]

        let result = AudioProcessListReducer.normalized(processes)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.bundleIdentifier, "com.example.Player")
        XCTAssertEqual(result.first?.processID, 20)
        XCTAssertEqual(result.first?.processObjectIDs, [200, 201])
    }

    func testMonitorPublishesInitialSnapshotAndStopsPublishingAfterStop() async {
        let reader = FakeAudioProcessReader(processes: [
            AudioAppDescriptor(processID: 20, processObjectIDs: [200], bundleIdentifier: "com.example.Player", displayName: "Player", isSystemProcess: false)
        ])
        let monitor = SystemAudioProcessMonitor(reader: reader)
        let updates = monitor.updates

        monitor.start()
        let first = await nextValue(from: updates)
        XCTAssertEqual(first?.map(\.id), ["com.example.Player"])

        monitor.stop()
        reader.processes = [
            AudioAppDescriptor(processID: 21, processObjectIDs: [201], bundleIdentifier: "com.example.Other", displayName: "Other", isSystemProcess: false)
        ]
        monitor.refresh()

        let next = await nextValue(from: updates, timeout: .milliseconds(50))
        XCTAssertNil(next)
    }

    func testPlaybackAndRelaunchEventsRefreshWithoutWaitingForPolling() {
        let reader = FakeAudioProcessReader(processes: [])
        let events = FakeAudioProcessEvents()
        let monitor = SystemAudioProcessMonitor(reader: reader, observer: events)
        monitor.start()
        let app = AudioAppDescriptor(processID: 20, processObjectIDs: [200],
            bundleIdentifier: "com.microsoft.edgemac", displayName: "Microsoft Edge", isSystemProcess: false)
        reader.processes = [app]
        events.emit()
        XCTAssertEqual(monitor.apps, [app])
        reader.processes = []
        events.emit()
        XCTAssertTrue(monitor.apps.isEmpty)
        let relaunched = AudioAppDescriptor(processID: 30, processObjectIDs: [300],
            bundleIdentifier: app.bundleIdentifier, displayName: app.displayName, isSystemProcess: false)
        reader.processes = [relaunched]
        events.emit()
        XCTAssertEqual(monitor.apps, [relaunched])
        monitor.stop()
        XCTAssertTrue(events.stopped)
        reader.processes = []
        events.emit()
        XCTAssertEqual(monitor.apps, [relaunched])
    }

    private func nextValue(
        from stream: AsyncStream<[AudioAppDescriptor]>,
        timeout: Duration = .seconds(1)
    ) async -> [AudioAppDescriptor]? {
        await withTaskGroup(of: [AudioAppDescriptor]?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}

@MainActor
private final class FakeAudioProcessReader: AudioProcessReading {
    var processes: [AudioAppDescriptor]

    init(processes: [AudioAppDescriptor]) {
        self.processes = processes
    }

    func read() -> [AudioAppDescriptor] {
        processes
    }
}

@MainActor
private final class FakeAudioProcessEvents: AudioProcessChangeObserving {
    var callback: (@MainActor () -> Void)?
    var stopped = false
    func start(onChange: @escaping @MainActor () -> Void) { callback = onChange }
    func stop() { stopped = true }
    func emit() { callback?() }
}
