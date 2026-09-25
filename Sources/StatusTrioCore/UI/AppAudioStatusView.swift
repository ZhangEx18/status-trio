import SwiftUI

struct AppAudioStatusView: View {
    @ObservedObject var controller: PerAppAudioController
    @ObservedObject var permission: AudioCapturePermissionController
    @EnvironmentObject private var localization: Localization

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
                Text(app.displayName)
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
            }

            Slider(
                value: Binding(
                    get: { controller.settings(for: app).volume },
                    set: { controller.setVolume($0, for: app) }
                ),
                in: 0...PerAppAudioSettings.maximumVolume
            )
            .accessibilityLabel(localization.string(.volumeAccessibilityLabel))
            .accessibilityValue("\(Int(appSettings.volume * 100))%")
        }
    }

    private func errorText(for error: PerAppAudioError) -> String {
        switch error {
        case .permissionDenied:
            localization.string(.audioAppPermission)
        case .unsupported, .processUnavailable, .unavailable:
            localization.string(.audioAppUnavailable)
        }
    }
}
