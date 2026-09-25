import XCTest
@testable import StatusTrioCore

@MainActor
final class AudioProcessMonitorTests: XCTestCase {
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
