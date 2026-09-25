import XCTest
@testable import StatusTrioCore

@MainActor
final class PerAppAudioControllerTests: XCTestCase {
    func testControllerPublishesAppsAndForwardsVolumeChanges() async {
        let monitor = FakeAudioProcessMonitor()
        let taps = RecordingProcessTapManager()
        let store = PerAppAudioSettingsStore(defaults: makeDefaults())
        let controller = PerAppAudioController(
            monitor: monitor,
            tapManager: taps,
            settingsStore: store
        )
        let app = AudioAppDescriptor(
            processID: 42,
            processObjectIDs: [100],
            bundleIdentifier: "com.example.Player",
            displayName: "Player",
            isSystemProcess: false
        )

        controller.start()
        monitor.send([app])
        await Task.yield()
        controller.setVolume(2, for: app)

        XCTAssertEqual(controller.apps, [app])
        XCTAssertEqual(controller.settings(for: app).volume, 2)
        XCTAssertEqual(taps.lastVolume, (app.id, 2))
    }

    func testControllerReportsTapFailureButKeepsPersistedIntent() async {
        let monitor = FakeAudioProcessMonitor()
        let taps = RecordingProcessTapManager()
        taps.error = .unsupported
        let controller = PerAppAudioController(
            monitor: monitor,
            tapManager: taps,
            settingsStore: PerAppAudioSettingsStore(defaults: makeDefaults())
        )
        let app = AudioAppDescriptor(
            processID: 42,
            processObjectIDs: [100],
            bundleIdentifier: "com.example.Player",
            displayName: "Player",
            isSystemProcess: false
        )

        controller.start()
        monitor.send([app])
        await Task.yield()
        controller.setMuted(true, for: app)

        XCTAssertEqual(controller.settings(for: app).isMuted, true)
        XCTAssertEqual(controller.lastError, .unsupported)
    }

    func testSettingsStorePersistsVersionedPerAppValues() {
        let suite = makeDefaults()
        let store = PerAppAudioSettingsStore(defaults: suite)
        store.set(
            PerAppAudioSettings(volume: 3, isMuted: true, routing: .explicit, outputDeviceUIDs: ["uid"]),
            for: "com.example.Player"
        )

        let reloaded = PerAppAudioSettingsStore(defaults: suite)

        XCTAssertEqual(
            reloaded.value(for: "com.example.Player"),
            PerAppAudioSettings(volume: 3, isMuted: true, routing: .explicit, outputDeviceUIDs: ["uid"])
        )
    }

    private func makeDefaults() -> UserDefaults {
        let name = "PerAppAudioControllerTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }
}

@MainActor
private final class FakeAudioProcessMonitor: AudioProcessMonitoring {
    let updates: AsyncStream<[AudioAppDescriptor]>
    private let continuation: AsyncStream<[AudioAppDescriptor]>.Continuation
    private(set) var apps: [AudioAppDescriptor] = []

    init() {
        (updates, continuation) = AsyncStream.makeStream(of: [AudioAppDescriptor].self)
    }

    func start() {}
    func stop() { continuation.finish() }
    func refresh() {}

    func send(_ apps: [AudioAppDescriptor]) {
        self.apps = apps
        continuation.yield(apps)
    }
}

@MainActor
private final class RecordingProcessTapManager: ProcessTapManaging {
    var error: PerAppAudioError?
    var lastVolume: (String, Double)?

    func updateApps(_ apps: [AudioAppDescriptor]) {}
    func start() {}
    func stop() {}

    func setVolume(_ volume: Double, for app: AudioAppDescriptor) throws {
        if let error { throw error }
        lastVolume = (app.id, volume)
    }

    func setMuted(_ isMuted: Bool, for app: AudioAppDescriptor) throws {
        if let error { throw error }
    }

    func setRouting(
        _ routing: AudioRoutingMode,
        outputDeviceUIDs: [String],
        for app: AudioAppDescriptor
    ) throws {
        if let error { throw error }
    }
}
