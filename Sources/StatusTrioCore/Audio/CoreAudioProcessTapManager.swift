import AudioToolbox
import Foundation

/// Small, allocation-free helpers shared by the real-time IO callback and tests.
enum AudioTapBufferProcessor {
    static func gain(volume: Double, muted: Bool) -> Float {
        guard !muted else { return 0 }
        let normalized = volume.isFinite ? volume : PerAppAudioSettings.defaultVolume
        return Float(min(PerAppAudioSettings.maximumVolume, max(0, normalized)))
    }

    nonisolated static func applyGain(
        _ gain: Float,
        to samples: UnsafeMutableBufferPointer<Float>
    ) {
        guard gain != 1 else { return }
        for index in samples.indices {
            samples[index] *= gain
        }
    }
}

/// Owns one private Process Tap and its private Aggregate Device.
///
/// The mutable gain is intentionally teardown-owned and read from the Core Audio
/// callback without locks or allocations. All lifecycle changes remain on the
/// main actor in `CoreAudioProcessTapManager`.
private final class AudioTapSession: @unchecked Sendable {
    let identity: AudioAppProcessIdentity
    let tapID: AudioObjectID
    let aggregateID: AudioObjectID
    var ioProcID: AudioDeviceIOProcID?
    nonisolated(unsafe) var gain: Float
    nonisolated(unsafe) var volume: Double = PerAppAudioSettings.defaultVolume
    nonisolated(unsafe) var isMuted = false

    init(
        identity: AudioAppProcessIdentity,
        tapID: AudioObjectID,
        aggregateID: AudioObjectID
    ) {
        self.identity = identity
        self.tapID = tapID
        self.aggregateID = aggregateID
        self.gain = 1
    }

    func process(
        inputData: UnsafePointer<AudioBufferList>,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) {
        let inputBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
        let count = min(inputBuffers.count, outputBuffers.count)

        for index in 0..<count {
            let input = inputBuffers[index]
            let output = outputBuffers[index]
            guard let inputData = input.mData,
                  let outputData = output.mData else {
                continue
            }

            let byteCount = min(Int(input.mDataByteSize), Int(output.mDataByteSize))
            guard byteCount > 0 else { continue }
            memcpy(outputData, inputData, byteCount)

            guard byteCount.isMultiple(of: MemoryLayout<Float>.stride) else { continue }
            let samples = outputData.assumingMemoryBound(to: Float.self)
            AudioTapBufferProcessor.applyGain(
                gain,
                to: UnsafeMutableBufferPointer(
                    start: samples,
                    count: byteCount / MemoryLayout<Float>.stride
                )
            )
        }
    }

    func stop() {
        if let ioProcID {
            _ = AudioDeviceStop(aggregateID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        _ = AudioHardwareDestroyAggregateDevice(aggregateID)
        _ = AudioHardwareDestroyProcessTap(tapID)
    }
}

/// First real Process Tap implementation: one App routed to the current default
/// output device. Multi-device routing and crossfade are layered on this stable
/// lifecycle in the next phase.
@MainActor
final class CoreAudioProcessTapManager: ProcessTapManaging {
    private let outputController: CoreAudioOutputController
    private let permission: AudioCapturePermissionController
    private var apps: [String: AudioAppDescriptor] = [:]
    private var sessions: [String: AudioTapSession] = [:]
    private var isStarted = false

    init(
        outputController: CoreAudioOutputController? = nil,
        permission: AudioCapturePermissionController? = nil
    ) {
        self.outputController = outputController ?? CoreAudioOutputController()
        self.permission = permission ?? AudioCapturePermissionController()
    }

    func updateApps(_ apps: [AudioAppDescriptor]) {
        let next = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        let staleIdentifiers = sessions.compactMap { identifier, session in
            guard let app = next[identifier], app.processIdentity == session.identity else {
                return identifier
            }
            return nil
        }
        for identifier in staleIdentifiers {
            sessions[identifier]?.stop()
            sessions.removeValue(forKey: identifier)
        }
        self.apps = next
    }

    func start() {
        isStarted = true
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        for session in sessions.values {
            session.stop()
        }
        sessions.removeAll()
    }

    func setVolume(_ volume: Double, for app: AudioAppDescriptor) throws {
        guard isStarted else { throw PerAppAudioError.unavailable }
        let session = try session(for: app)
        session.volume = volume
        session.gain = AudioTapBufferProcessor.gain(volume: volume, muted: session.isMuted)
    }

    func setMuted(_ isMuted: Bool, for app: AudioAppDescriptor) throws {
        guard isStarted else { throw PerAppAudioError.unavailable }
        let session = try session(for: app)
        session.isMuted = isMuted
        session.gain = AudioTapBufferProcessor.gain(volume: session.volume, muted: isMuted)
    }

    private func session(for app: AudioAppDescriptor) throws -> AudioTapSession {
        if let existing = sessions[app.id] {
            return existing
        }
        guard !app.processObjectIDs.isEmpty else {
            throw PerAppAudioError.processUnavailable
        }
        guard permission.status != .denied else {
            throw PerAppAudioError.permissionDenied
        }
        guard let output = outputController.outputDevices().first(where: { $0.isCurrent }),
              let outputUID = output.uid else {
            throw PerAppAudioError.processUnavailable
        }

        let tapDescription = CATapDescription(
            stereoMixdownOfProcesses: app.processObjectIDs.map { AudioObjectID($0) }
        )
        tapDescription.name = "Status Trio App Audio \(app.persistenceIdentifier)"
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = CATapMuteBehavior.mutedWhenTapped

        var tapID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(tapDescription, &tapID) == noErr else {
            throw PerAppAudioError.unavailable
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Status Trio App Audio \(app.persistenceIdentifier)",
            kAudioAggregateDeviceUIDKey: "com.lingsmbp.StatusTrio.AppAudio.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceClockDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[
                kAudioSubDeviceUIDKey: outputUID,
                kAudioSubDeviceDriftCompensationKey: false
            ]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: false
            ]]
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateID
        ) == noErr else {
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw PerAppAudioError.unavailable
        }

        let session = AudioTapSession(
            identity: app.processIdentity,
            tapID: tapID,
            aggregateID: aggregateID
        )
        var ioProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            aggregateID,
            nil
        ) { [weak session] _, inputData, _, outputData, _ in
            guard let session else { return }
            session.process(inputData: inputData, outputData: outputData)
        }
        guard ioStatus == noErr, let ioProcID else {
            session.stop()
            throw PerAppAudioError.unavailable
        }

        session.ioProcID = ioProcID
        guard AudioDeviceStart(aggregateID, ioProcID) == noErr else {
            session.stop()
            throw PerAppAudioError.unavailable
        }

        sessions[app.id] = session
        return session
    }
}
