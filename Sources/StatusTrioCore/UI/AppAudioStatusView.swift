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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(controller.apps) { app in
                            appRow(app)
                        }
                    }
                }
                .frame(maxHeight: 240)
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
                    .help(app.displayName)
                    .accessibilityLabel(app.displayName)

                Button {
                    controller.setMuted(!appSettings.isMuted, for: app)
                } label: {
                    Image(systemName: appSettings.isMuted ? "speaker.slash" : "speaker.wave.2.fill")
                        .foregroundStyle(appSettings.isMuted ? Color.red : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    localization.string(
                        appSettings.isMuted ? .volumeUnmuted : .volumeMuted
                    )
                    )

                AudioLevelSlider(value: Binding(get: { controller.level(for: app) },
                    set: { controller.setLevel($0, for: app) }))
                    .accessibilityLabel(localization.string(.volumeAccessibilityLabel))
                Text(controller.level(for: app).formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                    .frame(width: 32, alignment: .trailing)

                Button { controller.setBoost(appSettings.boost.next, for: app) } label: {
                    VStack(spacing: -2) {
                        ForEach((0..<3).reversed(), id: \.self) { index in
                            Image(systemName: "chevron.compact.up")
                                .font(.system(size: 12, weight: .heavy))
                                .foregroundStyle(index < Int(appSettings.boost.multiplier) - 1
                                    ? Color.accentColor : Color.primary.opacity(0.18))
                        }
                    }
                    .frame(width: 22, height: 28)
                    .contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .help(boostTitle(appSettings.boost))
                    .accessibilityLabel(boostTitle(appSettings.boost))

                routingMenu(for: app)
            }


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

    private func routingMenu(for app: AudioAppDescriptor) -> some View {
        AppAudioRoutingView(controller: controller, app: app, devices: outputDevices)
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
