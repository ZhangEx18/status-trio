import Foundation

/// Audio services can have a PID but no NSRunningApplication. Resolve their
/// executable location and ancestry against living, user-facing applications.
enum AudioProcessOwnerResolver {
    static func ownerPID(
        processID: Int32,
        processURL: URL?,
        applicationURLs: [Int32: URL],
        parentPID: (Int32) -> Int32?
    ) -> Int32? {
        if applicationURLs[processID] != nil { return processID }
        if let path = processURL?.standardizedFileURL.path,
           let match = applicationURLs.filter({ path.hasPrefix($0.value.standardizedFileURL.path + "/") })
            .max(by: { $0.value.path.count < $1.value.path.count }) {
            return match.key
        }
        var visited: Set<Int32> = []
        var current = processID
        while current > 1, visited.insert(current).inserted {
            if applicationURLs[current] != nil { return current }
            guard let parent = parentPID(current) else { break }
            current = parent
        }
        return nil
    }
}

struct AudioProcessAppHistory {
    private var knownIdentifiers: Set<String> = []

    mutating func update(livingApps: [AudioAppDescriptor], audioProcesses: [AudioAppDescriptor]) -> [AudioAppDescriptor] {
        let active = AudioProcessListReducer.livingApps(livingApps, audioProcesses: audioProcesses)
        knownIdentifiers.formUnion(active.map(\.persistenceIdentifier))
        // Keep discovery history, but only display currently living apps and
        // never carry old HAL object IDs across a pause or process relaunch.
        return AudioProcessListReducer.livingApps(livingApps, audioProcesses: audioProcesses,
            knownIdentifiers: knownIdentifiers)
    }
}
