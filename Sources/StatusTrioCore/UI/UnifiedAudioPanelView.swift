import SwiftUI

struct UnifiedAudioPanelView: View {
    @ObservedObject var store: SystemStatusStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var appAudioController: PerAppAudioController
    let scrollTargets: PopoverScrollTargets
    let onOpenSoundSettings: () -> Void
    @EnvironmentObject private var localization: Localization
    @State private var tab: AudioPanelTab = .output

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                tabButton(.output, symbol: "speaker.wave.2.fill", title: .volumeOutputTitle)
                tabButton(.input, symbol: "mic.fill", title: .audioInputTitle)
                Spacer()
                if tab == .input {
                    Button(action: onOpenSoundSettings) {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .help(localization.string(.audioInputOpenSettings))
                }
            }
            if tab == .output {
                outputDevices
            } else {
                AudioInputControlsView(
                    status: store.liveInput,
                    onSelect: { store.selectInputDevice($0) },
                    onScalarChange: { store.setInputScalar($0) },
                    onToggleMute: { store.toggleInputMute() },
                    onOpenSoundSettings: onOpenSoundSettings,
                    compact: true
                )
            }
            Divider()
            AppAudioStatusView(controller: appAudioController,
                permission: appAudioController.permission,
                outputDevices: store.liveVolume.outputDevices)
        }
    }

    private func tabButton(_ value: AudioPanelTab, symbol: String, title: LocalizationKey) -> some View {
        Button { tab = value } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tab == value ? Color.primary : Color.secondary)
                .frame(width: 28, height: 28)
                .background(tab == value ? Color.primary.opacity(0.1) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localization.string(title))
        .accessibilityAddTraits(tab == value ? .isSelected : [])
    }

    private var outputDevices: some View {
        VolumeControlsView(settings: settings, scrollTargets: scrollTargets,
            volume: store.liveVolume, isEnabled: store.isVolumeControlAvailable,
            onVolumeChange: { store.setVolume($0) }, onToggleMute: { store.toggleMute() },
            onSelectOutputDevice: { store.selectOutputDevice($0) }, onOpenSoundSettings: onOpenSoundSettings)
    }
}
