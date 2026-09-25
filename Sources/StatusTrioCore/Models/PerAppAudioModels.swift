import Foundation

/// The routing choice for a managed app's audio stream.
enum AudioRoutingMode: String, Codable, CaseIterable, Sendable {
    case followSystemDefault
    case explicit
}

/// Stable process identity used by the Core Audio process list and persisted app state.
struct AudioAppProcessIdentity: Hashable, Codable, Sendable {
    let processID: Int32
    let objectIDs: [UInt32]
}

/// Metadata for an application that exposes an audio process through Core Audio.
/// Icons remain a UI concern so this model stays Codable and Sendable.
struct AudioAppDescriptor: Identifiable, Hashable, Codable, Sendable {
    let processID: Int32
    let processObjectIDs: [UInt32]
    let bundleIdentifier: String?
    let displayName: String
    let isSystemProcess: Bool

    var id: String {
        persistenceIdentifier
    }

    var persistenceIdentifier: String {
        guard let bundleIdentifier,
              !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "pid:\(processID)"
        }
        return bundleIdentifier
    }

    var processIdentity: AudioAppProcessIdentity {
        AudioAppProcessIdentity(processID: processID, objectIDs: processObjectIDs)
    }
}

/// Persisted per-App controls. This is intentionally independent from the global
/// output-volume state in `StatusSnapshot`.
struct PerAppAudioSettings: Codable, Equatable, Sendable {
    static let defaultVolume: Double = 1
    static let maximumVolume: Double = 4

    var volume: Double
    var isMuted: Bool
    var routing: AudioRoutingMode
    var outputDeviceUIDs: [String]

    init(
        volume: Double = Self.defaultVolume,
        isMuted: Bool = false,
        routing: AudioRoutingMode = .followSystemDefault,
        outputDeviceUIDs: [String] = []
    ) {
        self.volume = volume
        self.isMuted = isMuted
        self.routing = routing
        self.outputDeviceUIDs = outputDeviceUIDs
        normalize()
    }

    mutating func normalize() {
        if !volume.isFinite {
            volume = Self.defaultVolume
        }
        volume = min(Self.maximumVolume, max(0, volume))

        var seen = Set<String>()
        outputDeviceUIDs = outputDeviceUIDs.filter { uid in
            guard !uid.isEmpty else { return false }
            return seen.insert(uid).inserted
        }

        if routing == .explicit, outputDeviceUIDs.isEmpty {
            routing = .followSystemDefault
        } else if routing == .followSystemDefault {
            outputDeviceUIDs.removeAll()
        }
    }
}
