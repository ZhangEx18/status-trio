import AppKit
import XCTest
@testable import StatusTrioCore

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    func testShowCreatesReusesAndLocalizesSingleWindow() throws {
        let suiteName = "StatusTrioCoreTests.SettingsWindow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let localization = Localization(defaults: defaults, preferredLanguages: ["en"])
        localization.setPreference(.language(.simplifiedChinese))
        let controller = SettingsWindowController(
            store: SettingsStore(defaults: defaults),
            statusStore: makeStatusStore(),
            localization: localization
        )
        XCTAssertNil(controller.window)

        controller.show()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }

        XCTAssertEqual(window.title, "设置")
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.isVisible)

        localization.setPreference(.language(.german))
        XCTAssertEqual(window.title, "Einstellungen")

        controller.show()
        XCTAssertTrue(controller.window === window)
    }

    private func makeStatusStore() -> SystemStatusStore {
        SystemStatusStore(
            batteryMonitor: NoopBatteryMonitor(),
            wifiMonitor: NoopWiFiMonitor(),
            volumeMonitor: NoopVolumeMonitor()
        )
    }
}

@MainActor
private final class NoopBatteryMonitor: BatteryMonitoring {
    let updates: AsyncStream<BatteryStatus>

    init() {
        (updates, _) = AsyncStream.makeStream()
    }

    func start() {}
    func stop() {}
    func refresh() {}
    func recover() {}
}

@MainActor
private final class NoopWiFiMonitor: WiFiMonitoring {
    let updates: AsyncStream<WiFiStatus>

    init() {
        (updates, _) = AsyncStream.makeStream()
    }

    func start() {}
    func stop() {}
    func refresh() {}
    func recover() {}
    func requestNameAccess() {}
}

@MainActor
private final class NoopVolumeMonitor: VolumeMonitoring {
    let updates: AsyncStream<VolumeStatus>

    init() {
        (updates, _) = AsyncStream.makeStream()
    }

    func start() {}
    func stop() {}
    func refresh() {}
    func recover() {}
}
