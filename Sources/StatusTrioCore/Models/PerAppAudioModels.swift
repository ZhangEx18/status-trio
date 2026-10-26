import Foundation

/// The routing choice for a managed app's audio stream.
enum AudioRoutingMode: String, Codable, CaseIterable, Sendable {
    case followSystemDefault
    case explicit
}

enum AudioBoostPreset: String, Codable, CaseIterable, Sendable {
    case normal
    case twoX
    case threeX
    case fourX

    var next: Self {
        switch self {
        case .normal: .twoX
        case .twoX: .threeX
        case .threeX: .fourX
        case .fourX: .normal
        }
    }

    var multiplier: Double {
        switch self {
        case .normal: 1
        case .twoX: 2
        case .threeX: 3
        case .fourX: 4
        }
    }
}

/// Stable process identity used by the Core Audio process list and persisted app state.
struct AudioAppProcessIdentity: Hashable, Codable, Sendable {
    let processID: Int32
    let objectIDs: [UInt32]
}

/// Metadata for a living application. Audio process IDs can be empty while idle.
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
    /// The normalized slider value introduced with the FineTune-style Boost UI.
    /// `nil` keeps decoding compatible with the original v1 payload.
    var level: Double?
    var boost: AudioBoostPreset
    var isMuted: Bool
    var usesMultipleDevices: Bool = false
    var routing: AudioRoutingMode
    var outputDeviceUIDs: [String]

    init(
        volume: Double = Self.defaultVolume,
        level: Double? = nil,
        boost: AudioBoostPreset = .normal,
        isMuted: Bool = false,
        routing: AudioRoutingMode = .followSystemDefault,
        outputDeviceUIDs: [String] = []
    ) {
        self.volume = volume
        self.level = level
        self.boost = boost
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
        if let level {
            self.level = min(1, max(0, level.isFinite ? level : 1))
        }

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

    var normalizedLevel: Double {
        if let level {
            return min(1, max(0, level))
        }
        return min(1, max(0, volume / boost.multiplier))
    }

    enum CodingKeys: String, CodingKey {
        case volume, level, boost, isMuted, routing, outputDeviceUIDs, usesMultipleDevices
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        volume = try values.decodeIfPresent(Double.self, forKey: .volume) ?? Self.defaultVolume
        level = try values.decodeIfPresent(Double.self, forKey: .level)
        boost = try values.decodeIfPresent(AudioBoostPreset.self, forKey: .boost) ?? .normal
        isMuted = try values.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        routing = try values.decodeIfPresent(AudioRoutingMode.self, forKey: .routing) ?? .followSystemDefault
        outputDeviceUIDs = try values.decodeIfPresent([String].self, forKey: .outputDeviceUIDs) ?? []
        usesMultipleDevices = try values.decodeIfPresent(Bool.self, forKey: .usesMultipleDevices) ?? (outputDeviceUIDs.count > 1)
        normalize()
    }
}
