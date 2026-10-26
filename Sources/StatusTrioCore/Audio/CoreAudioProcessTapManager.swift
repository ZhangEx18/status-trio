import AudioToolbox
import Foundation

/// Small, allocation-free helpers shared by the real-time IO callback and tests.
///
/// This type is deliberately nonisolated. It is called from Core Audio's IO
/// thread, which is not a Swift actor executor.
enum AudioTapRealtimeProcessor {
    nonisolated static func gain(volume: Double, muted: Bool) -> Float {
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

/// Compatibility facade for the value-level tests and callers that do not run
/// on the audio thread.
enum AudioTapBufferProcessor {
    static func gain(volume: Double, muted: Bool) -> Float {
        AudioTapRealtimeProcessor.gain(volume: volume, muted: muted)
    }

    nonisolated static func applyGain(
        _ gain: Float,
        to samples: UnsafeMutableBufferPointer<Float>
    ) {
        AudioTapRealtimeProcessor.applyGain(gain, to: samples)
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
    let outputDeviceUIDs: [String]
    var ioProcID: AudioDeviceIOProcID?
    nonisolated(unsafe) var gain: Float
    nonisolated(unsafe) var volume: Double = PerAppAudioSettings.defaultVolume
    nonisolated(unsafe) var isMuted = false

    init(
        identity: AudioAppProcessIdentity,
        tapID: AudioObjectID,
        aggregateID: AudioObjectID,
        outputDeviceUIDs: [String],
        volume: Double,
        isMuted: Bool
    ) {
        self.identity = identity
        self.tapID = tapID
        self.aggregateID = aggregateID
        self.outputDeviceUIDs = outputDeviceUIDs
        self.volume = volume
        self.isMuted = isMuted
        self.gain = AudioTapBufferProcessor.gain(volume: volume, muted: isMuted)
    }

    nonisolated func process(
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
            AudioTapRealtimeProcessor.applyGain(
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

/// C-compatible callback used by the Core Audio IO thread. Keeping this as a
/// file-level function prevents a `@MainActor` closure from being inherited by
/// the realtime callback.
private func audioTapIOProc(
    _ deviceID: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let session = Unmanaged<AudioTapSession>
        .fromOpaque(clientData)
        .takeUnretainedValue()
    session.process(inputData: inputData, outputData: outputData)
    return noErr
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
        let session = try session(for: app, initialVolume: volume, initialMuted: false, outputDeviceUIDs: nil)
        session.volume = volume
        session.gain = AudioTapBufferProcessor.gain(volume: volume, muted: session.isMuted)
    }

    func setMuted(_ isMuted: Bool, for app: AudioAppDescriptor) throws {
        guard isStarted else { throw PerAppAudioError.unavailable }
        let session = try session(for: app, initialVolume: PerAppAudioSettings.defaultVolume, initialMuted: isMuted, outputDeviceUIDs: nil)
        session.isMuted = isMuted
        session.gain = AudioTapBufferProcessor.gain(volume: session.volume, muted: isMuted)
    }

    func setRouting(
        _ routing: AudioRoutingMode,
        outputDeviceUIDs: [String],
        for app: AudioAppDescriptor
    ) throws {
        guard isStarted else { throw PerAppAudioError.unavailable }
        let currentVolume = sessions[app.id]?.volume ?? PerAppAudioSettings.defaultVolume
        let currentMuted = sessions[app.id]?.isMuted ?? false
        sessions[app.id]?.stop()
        sessions.removeValue(forKey: app.id)
        _ = try session(
            for: app,
            initialVolume: currentVolume,
            initialMuted: currentMuted,
            outputDeviceUIDs: routing == .explicit ? outputDeviceUIDs : nil
        )
    }

    private func session(
        for app: AudioAppDescriptor,
        initialVolume: Double,
        initialMuted: Bool,
        outputDeviceUIDs requestedOutputDeviceUIDs: [String]?
    ) throws -> AudioTapSession {
        if let existing = sessions[app.id] {
            return existing
        }
        guard !app.processObjectIDs.isEmpty else {
            throw PerAppAudioError.processUnavailable
        }
        guard permission.status == .authorized else {
            throw PerAppAudioError.permissionDenied
        }
        let outputDevices = outputController.outputDevices()
        let availableUIDs = Set(outputDevices.compactMap(\.uid))
        let selectedUIDs: [String]
        if let requestedOutputDeviceUIDs {
            selectedUIDs = requestedOutputDeviceUIDs.filter { availableUIDs.contains($0) }
        } else if let current = outputDevices.first(where: { $0.isCurrent }),
                  let currentUID = current.uid {
            selectedUIDs = [currentUID]
        } else {
            selectedUIDs = []
        }
        guard !selectedUIDs.isEmpty else {
            throw PerAppAudioError.processUnavailable
        }
        let outputUID = selectedUIDs[0]

        let tapDescription = CATapDescription(
            stereoMixdownOfProcesses: app.processObjectIDs.map { AudioObjectID($0) }
        )
        tapDescription.name = "Status Trio App Audio \(app.persistenceIdentifier)"
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = CATapMuteBehavior.mutedWhenTapped

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard tapStatus == noErr else {
            throw PerAppAudioError.tapCreationFailed(tapStatus)
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Status Trio App Audio \(app.persistenceIdentifier)",
            kAudioAggregateDeviceUIDKey: "com.lingsmbp.StatusTrio.AppAudio.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceClockDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: selectedUIDs.map { uid in
                [
                    kAudioSubDeviceUIDKey: uid,
                    kAudioSubDeviceDriftCompensationKey: selectedUIDs.count > 1
                ]
            },
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: false
            ]]
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateID
        )
        guard aggregateStatus == noErr else {
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw PerAppAudioError.aggregateCreationFailed(aggregateStatus)
        }
        guard supportsFloat32InputFormat(for: aggregateID) else {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw PerAppAudioError.unsupportedFormat
        }

        let session = AudioTapSession(
            identity: app.processIdentity,
            tapID: tapID,
            aggregateID: aggregateID,
            outputDeviceUIDs: selectedUIDs,
            volume: initialVolume,
            isMuted: initialMuted
        )
        var ioProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcID(
            aggregateID,
            audioTapIOProc,
            Unmanaged.passUnretained(session).toOpaque(),
            &ioProcID
        )
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

    private func supportsFloat32InputFormat(for deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &format
        )
        guard status == noErr,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mBitsPerChannel == 32,
              format.mBytesPerFrame == format.mChannelsPerFrame * 4 else {
            return false
        }
        return (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && (format.mFormatFlags & kAudioFormatFlagIsPacked) != 0
    }
}
