import AudioToolbox
import Combine
import Foundation

/// Errors that keep a per-App tap from being applied without stopping the rest
/// of Status Trio's system-audio controls.
enum PerAppAudioError: Error, Equatable, Sendable {
    case permissionDenied
    case unsupported
    case processUnavailable
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case unsupportedFormat
    case streamUsageConfigurationFailed(OSStatus)
    case unavailable
}

@MainActor
protocol ProcessTapManaging: AnyObject {
    func updateApps(_ apps: [AudioAppDescriptor])
    func start()
    func stop()
    func setVolume(_ volume: Double, for app: AudioAppDescriptor) throws
    func setMuted(_ isMuted: Bool, for app: AudioAppDescriptor) throws
    func setRouting(
        _ routing: AudioRoutingMode,
        outputDeviceUIDs: [String],
        for app: AudioAppDescriptor
    ) throws
}

/// Temporary boundary for the first vertical slice. The real Core Audio tap
/// engine will replace this implementation once the process model and settings
/// contract are proven by tests.
@MainActor
final class UnsupportedProcessTapManager: ProcessTapManaging {
    func updateApps(_ apps: [AudioAppDescriptor]) {}
    func start() {}
    func stop() {}

    func setVolume(_ volume: Double, for app: AudioAppDescriptor) throws {
        throw PerAppAudioError.unsupported
    }

    func setMuted(_ isMuted: Bool, for app: AudioAppDescriptor) throws {
        throw PerAppAudioError.unsupported
    }

    func setRouting(
        _ routing: AudioRoutingMode,
        outputDeviceUIDs: [String],
        for app: AudioAppDescriptor
    ) throws {
        throw PerAppAudioError.unsupported
    }
}

@MainActor
final class PerAppAudioSettingsStore {
    static let defaultsKey = "perAppAudioSettings.v1"

    private let defaults: UserDefaults
    private(set) var values: [String: PerAppAudioSettings]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: PerAppAudioSettings].self, from: data) {
            var normalized = decoded
            for key in normalized.keys {
                normalized[key]?.normalize()
            }
            self.values = normalized
        } else {
            self.values = [:]
        }
    }

    func value(for identifier: String) -> PerAppAudioSettings {
        values[identifier] ?? PerAppAudioSettings()
    }

    func set(_ value: PerAppAudioSettings, for identifier: String) {
        var normalized = value
        normalized.normalize()
        values[identifier] = normalized
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

@MainActor
final class PerAppAudioController: ObservableObject {
    @Published private(set) var apps: [AudioAppDescriptor] = []
    @Published private(set) var lastError: PerAppAudioError?

    private let monitor: any AudioProcessMonitoring
    private let tapManager: any ProcessTapManaging
    private let settingsStore: PerAppAudioSettingsStore
    let permission: AudioCapturePermissionController
    private var updatesTask: Task<Void, Never>?
    private var isStarted = false

    init(
        monitor: (any AudioProcessMonitoring)? = nil,
        tapManager: (any ProcessTapManaging)? = nil,
        settingsStore: PerAppAudioSettingsStore? = nil,
        permission: AudioCapturePermissionController? = nil
    ) {
        self.monitor = monitor ?? SystemAudioProcessMonitor()
        self.tapManager = tapManager ?? UnsupportedProcessTapManager()
        self.settingsStore = settingsStore ?? PerAppAudioSettingsStore()
        self.permission = permission ?? AudioCapturePermissionController()
    }

    deinit {
        updatesTask?.cancel()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        tapManager.start()
        monitor.start()
        let updates = monitor.updates
        updatesTask = Task { @MainActor [weak self] in
            for await apps in updates {
                guard let self else { return }
                self.apps = apps
                self.tapManager.updateApps(apps)
                for app in apps {
                    let settings = self.settings(for: app)
                    if settings.routing == .explicit {
                        self.apply {
                            try self.tapManager.setRouting(
                                settings.routing,
                                outputDeviceUIDs: settings.outputDeviceUIDs,
                                for: app
                            )
                        }
                    }
                    if settings.volume != PerAppAudioSettings.defaultVolume {
                        self.apply {
                            try self.tapManager.setVolume(settings.volume, for: app)
                        }
                    }
                    if settings.isMuted {
                        self.apply {
                            try self.tapManager.setMuted(true, for: app)
                        }
                    }
                }
            }
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        updatesTask?.cancel()
        updatesTask = nil
        monitor.stop()
        tapManager.stop()
        apps = []
    }

    func refresh() {
        monitor.refresh()
    }

    @discardableResult
    func requestPermission() -> Bool {
        permission.request()
    }

    @discardableResult
    func openPermissionSettings() -> Bool {
        permission.openSystemSettings()
    }

    func settings(for app: AudioAppDescriptor) -> PerAppAudioSettings {
        settingsStore.value(for: app.persistenceIdentifier)
    }

    func setVolume(_ volume: Double, for app: AudioAppDescriptor) {
        var settings = settings(for: app)
        settings.volume = volume
        settings.normalize()
        settingsStore.set(settings, for: app.persistenceIdentifier)
        apply {
            try tapManager.setVolume(settings.volume, for: app)
        }
    }

    func setMuted(_ isMuted: Bool, for app: AudioAppDescriptor) {
        var settings = settings(for: app)
        settings.isMuted = isMuted
        settingsStore.set(settings, for: app.persistenceIdentifier)
        apply {
            try tapManager.setMuted(isMuted, for: app)
        }
    }

    func setRouting(
        _ routing: AudioRoutingMode,
        outputDeviceUIDs: [String],
        for app: AudioAppDescriptor
    ) {
        var settings = settings(for: app)
        settings.routing = routing
        settings.outputDeviceUIDs = outputDeviceUIDs
        settings.normalize()
        settingsStore.set(settings, for: app.persistenceIdentifier)
        apply {
            try tapManager.setRouting(
                settings.routing,
                outputDeviceUIDs: settings.outputDeviceUIDs,
                for: app
            )
        }
    }

    private func apply(_ operation: () throws -> Void) {
        do {
            try operation()
            lastError = nil
        } catch let error as PerAppAudioError {
            lastError = error
        } catch {
            lastError = .unavailable
        }
    }
}
