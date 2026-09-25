import AppKit
import SwiftUI

struct WiFiNetworkListView: View {
    @ObservedObject var controller: WiFiNetworkController
    @EnvironmentObject private var localization: Localization
    let wifi: WiFiStatus
    let onBack: () -> Void
    let onRequestNameAccess: () -> Void
    let onOpenWiFiSettings: () -> Void
    let onOpenLocationSettings: () -> Void
    let showsDetailsInitially: Bool

    @State private var showsDetails = false

    var body: some View {
        let grouped = WiFiNetworkPresentation.grouped(controller.networks)
        VStack(alignment: .leading, spacing: 12) {
            header
            Toggle(
                localization.string(.wifiPower),
                isOn: Binding(
                    get: { controller.state != .poweredOff && wifi.state != .off },
                    set: { controller.setPower($0) }
                )
            )
            .disabled(controller.state == .noInterface)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    knownNetworksSection(grouped.known)
                    otherNetworksSection(grouped.other)
                    stateMessage(
                        hasVisibleNetworks: !grouped.known.isEmpty || !grouped.other.isEmpty
                    )
                }
            }
            .frame(maxHeight: 330)

            Divider()
            Text(localization.string(.wifiActionSwitchingHint))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(localization.string(.wifiActionOpenSettings), action: onOpenWiFiSettings)
                .buttonStyle(.plain)
                .accessibilityLabel(localization.string(.wifiActionOpenSettings))
        }
        .onAppear {
            controller.activate(nameAccess: wifi.nameAccess)
            showsDetails = showsDetails || showsDetailsInitially
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            NavigationBackRow(
                accessibilityLabel: localization.string(.commonBack),
                title: localization.string(.wifiTitle),
                action: onBack
            )
            Button(action: { controller.refreshNow(nameAccess: wifi.nameAccess) }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(!controller.state.allowsRefresh)
            .accessibilityLabel(localization.string(.wifiRefresh))
        }
    }

    @ViewBuilder
    private func knownNetworksSection(_ networks: [WiFiNetwork]) -> some View {
        if !networks.isEmpty || controller.details.ssid != nil {
            Text(localization.string(.wifiKnownNetworks))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(networks) { network in
                networkRow(network)
            }

            if networks.contains(where: \.isConnected) || controller.details.ssid != nil {
                WiFiDetailsToggleRow(isExpanded: $showsDetails)

                if showsDetails {
                    WiFiDetailsView(details: controller.details)
                }
            }
        }
    }

    @ViewBuilder
    private func otherNetworksSection(_ networks: [WiFiNetwork]) -> some View {
        if !networks.isEmpty {
            Text(localization.string(.wifiOtherNetworks))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(networks) { network in
                networkRow(network)
            }
        }
    }

    @ViewBuilder
    private func stateMessage(hasVisibleNetworks: Bool) -> some View {
        switch controller.state {
        case .scanning:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(localization.string(.wifiScanning))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .ready where !hasVisibleNetworks:
            Text(localization.string(.wifiNoNetworks))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .poweredOff:
            Text(localization.string(.wifiPanelOff))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .noInterface:
            Text(localization.string(.wifiNoInterface))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .permissionDenied:
            Button(localization.string(.wifiPermissionDenied), action: onOpenLocationSettings)
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            Text(localization.string(.wifiScanFailed))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .idle, .ready:
            if wifi.nameAccess == .notDetermined {
                Button(localization.string(.wifiActionRequestNameAccess), action: onRequestNameAccess)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func networkRow(_ network: WiFiNetwork) -> some View {
        Button {
            if WiFiNetworkPresentation.action(for: network) == .openSettings {
                onOpenWiFiSettings()
            }
        } label: {
            HStack(spacing: 10) {
                networkIcon(for: network)

                VStack(alignment: .leading, spacing: 1) {
                    Text(displaySSID(network.ssid))
                        .font(.body.weight(network.isConnected ? .semibold : .medium))
                        .foregroundStyle(network.isConnected ? Color.primary : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if !network.isConnected, let metadata = networkMetadata(for: network) {
                        Text(metadata)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 8)
                if network.security.requiresPassword {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, network.isConnected ? 8 : 0)
            .padding(.vertical, 6)
            .background {
                if network.isConnected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(networkAccessibilityLabel(network))
    }

    @ViewBuilder
    private func networkIcon(for network: WiFiNetwork) -> some View {
        if network.isConnected {
            Image(systemName: "wifi")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.accentColor))
        } else if let rssi = network.rssi {
            Image(systemName: "wifi", variableValue: max(0.25, Double(StatusMappings.wifiBars(rssi: rssi)) / 3.0))
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
        } else {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
        }
    }

    private func networkMetadata(for network: WiFiNetwork) -> String? {
        let band = network.band.map {
            $0.gigahertz.formatted(
                .number.precision(.fractionLength($0 == .twoPointFourGHz ? 1 : 0))
                    .locale(localization.resolvedLanguage.locale)
            )
        }.map { localization.format(.wifiSummaryBand, $0) }
        let signal = network.rssi.map {
            localization.format(.wifiSummarySignal, $0)
        }

        switch (band, signal) {
        case let (band?, signal?):
            return localization.format(.wifiSummaryBandAndSignal, band, signal)
        case let (band?, nil):
            return band
        case let (nil, signal?):
            return signal
        case (nil, nil):
            return nil
        }
    }

    private func displaySSID(_ ssid: String) -> String {
        ssid.isEmpty ? localization.string(.wifiHiddenNetwork) : ssid
    }

    private func networkAccessibilityLabel(_ network: WiFiNetwork) -> String {
        let name = displaySSID(network.ssid)
        let connection = network.isConnected
            ? localization.string(.wifiConnected)
            : localization.string(.wifiNotConnected)
        guard !network.isConnected else { return "\(name), \(connection)" }
        return "\(name), \(connection), \(localization.string(.wifiActionOpenSettings))"
    }
}

private struct WiFiDetailsView: View {
    @EnvironmentObject private var localization: Localization
    let details: WiFiConnectionDetails

    var body: some View {
        VStack(spacing: 5) {
            // The rows live in `LinkDetailPresentation` because the wired panel
            // draws five of the same ones; only the radio rows are this panel's.
            LinkDetailsList(
                rows: LinkDetailPresentation.wirelessRows(
                    details,
                    expanded: showsMore,
                    localization: localization
                )
            )
            Button(showsMore ? localization.string(.wifiDetailsLess) : localization.string(.wifiDetailsMore)) {
                showsMore.toggle()
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 26)
        .font(.caption)
    }

    @State private var showsMore = false
}
