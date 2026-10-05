import Foundation

struct WiFiNetworkSetupCommand: Equatable, Sendable {
    let arguments: [String]

    static func listPreferredNetworks(interface: String) -> Self {
        Self(arguments: ["-listpreferredwirelessnetworks", interface])
    }
}

enum WiFiPreferredNetworkOutputParser {
    static func parse(_ output: String) -> Set<String> {
        var lines = output.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        )
        guard !lines.isEmpty else { return [] }
        lines.removeFirst()

        return Set(lines.compactMap { rawLine in
            var line = String(rawLine)
            if line.hasSuffix("\r") {
                line.removeLast()
            }
            while line.first == "\t" {
                line.removeFirst()
            }
            return line.isEmpty ? nil : line
        })
    }
}

protocol WiFiKnownNetworkProviding: Sendable {
    func preferredNetworkSSIDs(interface: String) -> Set<String>
}

/// Reads the system's preferred-network names without accessing their stored
/// passwords. The process runs on the CoreWLAN worker's serial queue, so a
/// wedged run must be killed at a deadline: a read that never returned would
/// keep that queue pinned and the Wi-Fi list stuck in `.scanning` for the rest
/// of the session.
final class NetworksetupWiFiKnownNetworkProvider: WiFiKnownNetworkProviding, @unchecked Sendable {
    private static let executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
    /// Far above the tool's normal latency, so only a genuinely wedged run
    /// pays it.
    private static let readTimeout = Duration.seconds(5)

    func preferredNetworkSSIDs(interface: String) -> Set<String> {
        guard let outputData = BoundedProcessRun.run(
            executableURL: Self.executableURL,
            arguments: WiFiNetworkSetupCommand
                .listPreferredNetworks(interface: interface)
                .arguments,
            timeout: Self.readTimeout
        ) else {
            return []
        }
        return WiFiPreferredNetworkOutputParser.parse(
            String(data: outputData, encoding: .utf8) ?? ""
        )
    }
}
