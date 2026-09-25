import SwiftUI

struct VolumeControlsView: View {
    @EnvironmentObject private var localization: Localization
    @ObservedObject var settings: SettingsStore
    let scrollTargets: PopoverScrollTargets
    let volume: VolumeStatus
    let isEnabled: Bool
    let onVolumeChange: (Double) -> Void
    let onToggleMute: () -> Void
    let onSelectOutputDevice: (AudioOutputDevice) -> Void
    let onOpenSoundSettings: () -> Void

    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var draftVolume = 0.0
    @State private var isAdjusting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VolumeOutputSummaryView(volume: volume)

                Button(
                    localization.string(.volumeActionOpenSettings),
                    systemImage: "gearshape",
                    action: onOpenSoundSettings
                )
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(localization.string(.volumeActionOpenSettings))
                .accessibilityLabel(localization.string(.volumeActionOpenSettings))
                .frame(width: 24, height: 24)
            }

            HStack(spacing: 10) {
                Button(action: onToggleMute) {
                    Image(systemName: volumeSymbolName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(volume.isMuted ? Color.red : Color.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .help(volume.isMuted ? localization.string(.volumeUnmuted) : localization.string(.volumeMuted))
                .accessibilityLabel(volume.isMuted ? localization.string(.volumeUnmuted) : localization.string(.volumeMuted))

                Slider(
                    value: Binding(get: { draftVolume }, set: { value in
                        draftVolume = value
                        updateVolume(value)
                    }),
                    in: 0...1,
                    onEditingChanged: { handleVolumeEditing($0) }
                )
                .tint(volume.isMuted ? Color.secondary : Color.accentColor)
                .disabled(!isEnabled)
                .accessibilityLabel(localization.string(.volumeAccessibilityLabel))
                .accessibilityValue(percentageText)
                .padding(.horizontal, 2)
                // Only the control row is a scroll target; the output device
                // list below stays a normal list.
                .background(VolumeControlScrollTarget(targets: scrollTargets))

                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            if volume.outputDevices.count > 1 {
                Divider()
                    .padding(.top, 2)

                OutputDeviceList(
                    settings: settings,
                    devices: volume.outputDevices,
                    onSelect: onSelectOutputDevice
                )
            }
        }
        .onDisappear { if isAdjusting { onEditingChanged(false) } }
        .onAppear(perform: { synchronizeVolume() })
        .onChange(of: volume.scalar) { _, _ in
            guard !isAdjusting else { return }
            synchronizeVolume()
        }
    }

    private var volumeSymbolName: String {
        if volume.isMuted {
            return "speaker.slash"
        }
        return "speaker.fill"
    }

    private var percentageText: String {
        guard draftVolume.isFinite else { return "—" }
        return min(1, max(0, draftVolume)).formatted(
            .percent.precision(.fractionLength(0))
                .locale(localization.resolvedLanguage.locale)
        )
    }

    private func handleVolumeEditing(_ isEditing: Bool) {
        isAdjusting = isEditing
        onEditingChanged(isEditing)
    }

    private func updateVolume(_ newValue: Double) {
        let scalar = volume.scalar ?? -1
        guard scalar.isFinite,
              abs(newValue - min(1, max(0, scalar))) >= 0.0005 else {
            return
        }
        onVolumeChange(newValue)
    }

    private func synchronizeVolume() {
        guard let scalar = volume.scalar, scalar.isFinite else {
            draftVolume = 0
            return
        }
        draftVolume = min(1, max(0, scalar))
    }
}
