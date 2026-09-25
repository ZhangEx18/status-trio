import AppKit
import AudioToolbox
import Combine

@MainActor
protocol AudioProcessReading: AnyObject {
    func read() -> [AudioAppDescriptor]
}

@MainActor
protocol AudioProcessMonitoring: AnyObject {
    var apps: [AudioAppDescriptor] { get }
    var updates: AsyncStream<[AudioAppDescriptor]> { get }
    func start()
    func stop()
    func refresh()
}

enum AudioProcessListReducer {
    static func livingApps(_ apps: [AudioAppDescriptor], audioProcesses: [AudioAppDescriptor], knownIdentifiers: Set<String> = []) -> [AudioAppDescriptor] {
        normalized(apps.compactMap { app in
            let processes = audioProcesses.filter {
                $0.processID == app.processID || $0.persistenceIdentifier == app.persistenceIdentifier
            }
            guard !processes.isEmpty || knownIdentifiers.contains(app.persistenceIdentifier) else { return nil }
            return AudioAppDescriptor(processID: app.processID,
                processObjectIDs: Array(Set(processes.flatMap(\.processObjectIDs))).sorted(),
                bundleIdentifier: app.bundleIdentifier, displayName: app.displayName,
                isSystemProcess: app.isSystemProcess)
        }).sorted { $0.persistenceIdentifier < $1.persistenceIdentifier }
    }

    static func normalized(_ processes: [AudioAppDescriptor]) -> [AudioAppDescriptor] {
        var merged: [String: AudioAppDescriptor] = [:]
        var order: [String] = []

        for process in processes where !process.isSystemProcess {
            let key = process.persistenceIdentifier
            if let existing = merged[key] {
                let objectIDs = Array(Set(existing.processObjectIDs + process.processObjectIDs)).sorted()
                merged[key] = AudioAppDescriptor(
                    processID: min(existing.processID, process.processID),
                    processObjectIDs: objectIDs,
                    bundleIdentifier: existing.bundleIdentifier ?? process.bundleIdentifier,
                    displayName: existing.displayName == "Unknown Audio App"
                        ? process.displayName
                        : existing.displayName,
                    isSystemProcess: false
                )
            } else {
                merged[key] = process
                order.append(key)
            }
        }

        return order.compactMap { merged[$0] }
    }
}

/// Reads the public Core Audio process object list and joins it with AppKit
/// metadata. The process list is intentionally read on demand; the controller
/// can add property listeners later without changing this value-level reader.
@MainActor
final class CoreAudioProcessReader: AudioProcessReading {
    private var knownIdentifiers: Set<String> = []
    private let ownProcessID = ProcessInfo.processInfo.processIdentifier

    func read() -> [AudioAppDescriptor] {
        let runningApps = Dictionary(
            NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        let processes: [AudioAppDescriptor] = processObjectIDs().compactMap { objectID in
            guard let processID = processID(for: objectID),
                  processID != ownProcessID, isRunning(for: objectID) else {
                return nil
            }

            let processApplication = runningApps[processID] ?? NSRunningApplication(processIdentifier: processID)
            // Helpers inside an app bundle belong to that living application,
            // even when Core Audio reports the helper's own bundle identifier.
            let application = processApplication?.bundleURL.flatMap { helperURL in
                runningApps.values.first { candidate in
                    guard candidate.activationPolicy == .regular, let appURL = candidate.bundleURL else { return false }
                    return helperURL.path.hasPrefix(appURL.path + "/")
                }
            } ?? processApplication
            let bundleIdentifier = application?.bundleIdentifier
                ?? bundleIdentifier(for: objectID)
            let displayName = application?.localizedName
                ?? bundleIdentifier
                ?? "Unknown Audio App"
            return AudioAppDescriptor(
                processID: processID,
                processObjectIDs: [objectID],
                bundleIdentifier: bundleIdentifier,
                displayName: displayName,
                isSystemProcess: Self.isSystemProcess(
                    bundleIdentifier: bundleIdentifier,
                    displayName: displayName
                )
            )
        }
        let apps = runningApps.values.filter {
            !$0.isTerminated && $0.processIdentifier != ownProcessID && $0.activationPolicy == .regular
        }.map { app in
            AudioAppDescriptor(processID: app.processIdentifier, processObjectIDs: [],
                bundleIdentifier: app.bundleIdentifier,
                displayName: app.localizedName ?? app.bundleIdentifier ?? "Unknown Audio App",
                isSystemProcess: false)
        }
        let active = AudioProcessListReducer.livingApps(apps, audioProcesses: processes)
        knownIdentifiers.formIntersection(Set(apps.map(\.persistenceIdentifier)))
        knownIdentifiers.formUnion(active.map(\.persistenceIdentifier))
        return AudioProcessListReducer.livingApps(apps, audioProcesses: processes, knownIdentifiers: knownIdentifiers)
    }

    private func isRunning(for objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
        guard count > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: count)
        let status = result.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                buffer.baseAddress!
            )
        }
        return status == noErr ? result : []
    }

    private func processID(for objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = 0
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )
        return status == noErr && value > 0 ? value : nil
    }

    private func bundleIdentifier(for objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )
        guard status == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }

    static func isSystemProcess(bundleIdentifier: String?, displayName: String) -> Bool {
        let prefixes = [
            "com.apple.audio",
            "com.apple.coreaudio",
            "com.apple.mediaremote",
            "com.apple.controlcenter",
            "com.apple.notificationcenter",
            "com.apple.speech",
            "com.apple.siri"
        ]
        if let bundleIdentifier,
           prefixes.contains(where: bundleIdentifier.hasPrefix) {
            return true
        }

        let systemNames = [
            "coreaudiod",
            "systemsoundserverd",
            "audiomxd",
            "controlcenter",
            "notificationcenter"
        ]
        return systemNames.contains { displayName.lowercased().hasPrefix($0) }
    }
}

@MainActor
final class SystemAudioProcessMonitor: AudioProcessMonitoring {
    let updates: AsyncStream<[AudioAppDescriptor]>
    private let continuation: AsyncStream<[AudioAppDescriptor]>.Continuation
    private let reader: any AudioProcessReading
    private(set) var apps: [AudioAppDescriptor] = []
    private var isStarted = false
    private var isStopped = false
    private var refreshTask: Task<Void, Never>?

    init(reader: (any AudioProcessReading)? = nil) {
        self.reader = reader ?? CoreAudioProcessReader()
        (updates, continuation) = MonitorStream.make(of: [AudioAppDescriptor].self)
    }

    deinit {
        refreshTask?.cancel()
        continuation.finish()
    }

    func start() {
        guard !isStarted, !isStopped else { return }
        isStarted = true
        refresh()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.isStarted, !self.isStopped else { return }
                self.refresh()
            }
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        refreshTask?.cancel()
        refreshTask = nil
        continuation.finish()
    }

    func refresh() {
        guard isStarted, !isStopped else { return }
        let next = AudioProcessListReducer.normalized(reader.read())
        guard next != apps else { return }
        apps = next
        continuation.yield(next)
    }
}
