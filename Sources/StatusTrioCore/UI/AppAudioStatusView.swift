import AppKit
import SwiftUI

struct AppAudioStatusView: View {
    @ObservedObject var controller: PerAppAudioController
    @ObservedObject var permission: AudioCapturePermissionController
    @EnvironmentObject private var localization: Localization
    let outputDevices: [AudioOutputDevice]

    init(
        controller: PerAppAudioController,
        permission: AudioCapturePermissionController,
        outputDevices: [AudioOutputDevice] = []
    ) {
        self.controller = controller
        self.permission = permission
        self.outputDevices = outputDevices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localization.string(.settingsPopupOrderAppAudio))
                .font(.headline)

            if controller.apps.isEmpty {
                Text(localization.string(.audioAppNoApps))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.apps) { app in
                    appRow(app)
                }
            }

            if permission.status != .authorized {
                Button(localization.string(.audioAppOpenPermissionSettings)) {
                    if permission.status == .denied {
                        controller.openPermissionSettings()
                    } else {
                        controller.requestPermission()
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            if let error = controller.lastError {
                Label(errorText(for: error), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func appRow(_ app: AudioAppDescriptor) -> some View {
        let appSettings = controller.settings(for: app)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                appIcon(for: app)

                Text(app.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    controller.setMuted(!appSettings.isMuted, for: app)
                } label: {
                    Image(systemName: appSettings.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    localization.string(
                        appSettings.isMuted ? .volumeUnmuted : .volumeMuted
                    )
                    )

                Menu {
                    ForEach(AudioBoostPreset.allCases, id: \.self) { boost in
                        Button {
                            controller.setBoost(boost, for: app)
                        } label: {
                            if boost == appSettings.boost {
                                Label(boostTitle(boost), systemImage: "checkmark")
                            } else {
                                Text(boostTitle(boost))
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.forward")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .help(boostTitle(appSettings.boost))

                routingMenu(for: app)
            }

            Slider(
                value: Binding(
                    get: { controller.level(for: app) },
                    set: { controller.setLevel($0, for: app) }
                ),
                in: 0...1
            )
            .accessibilityLabel(localization.string(.volumeAccessibilityLabel))
            .accessibilityValue("\(Int(controller.level(for: app) * 100))%")
        }
    }

    private func appIcon(for app: AudioAppDescriptor) -> some View {
        let image = app.bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 24, height: 24))
        return Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 24, height: 24)
    }

    @ViewBuilder
    private func routingMenu(for app: AudioAppDescriptor) -> some View {
        Menu {
            Button(localization.string(.volumeOutputTitle)) {
                controller.setRouting(.followSystemDefault, outputDeviceUIDs: [], for: app)
            }
            if !outputDevices.isEmpty {
                Divider()
                ForEach(outputDevices) { device in
                    if let uid = device.uid {
                        Toggle(
                            device.name ?? localization.string(.volumeOutputUnknownDevice),
                            isOn: Binding(
                                get: {
                                    controller.settings(for: app).outputDeviceUIDs.contains(uid)
                                },
                                set: { selected in
                                    updateRouteSelection(
                                        selected: selected,
                                        uid: uid,
                                        for: app
                                    )
                                }
                            )
                        )
                    }
                }
            }
        } label: {
            Image(systemName: "globe")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help(localization.string(.volumeOutputTitle))
    }

    private func updateRouteSelection(
        selected: Bool,
        uid: String,
        for app: AudioAppDescriptor
    ) {
        var selectedUIDs = controller.settings(for: app).outputDeviceUIDs
        if selected {
            if !selectedUIDs.contains(uid) {
                selectedUIDs.append(uid)
            }
        } else {
            selectedUIDs.removeAll { $0 == uid }
        }

        if selectedUIDs.isEmpty {
            controller.setRouting(.followSystemDefault, outputDeviceUIDs: [], for: app)
        } else {
            controller.setRouting(.explicit, outputDeviceUIDs: selectedUIDs, for: app)
        }
    }

    private func boostTitle(_ boost: AudioBoostPreset) -> String {
        switch boost {
        case .normal: "1x"
        case .twoX: "2x"
        case .threeX: "3x"
        case .fourX: "4x"
        }
    }

    private func errorText(for error: PerAppAudioError) -> String {
        switch error {
        case .permissionDenied:
            localization.string(.audioAppPermission)
        case .unsupported, .processUnavailable, .tapCreationFailed,
             .aggregateCreationFailed, .unsupportedFormat,
             .streamUsageConfigurationFailed, .unavailable:
            localization.string(.audioAppUnavailable)
        }
    }
}
