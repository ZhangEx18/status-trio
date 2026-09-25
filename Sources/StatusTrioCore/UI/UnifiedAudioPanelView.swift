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
            Picker("", selection: $tab) {
                Label(localization.string(.volumeOutputTitle), systemImage: "speaker.wave.2.fill")
                    .tag(AudioPanelTab.output)
                Label(localization.string(.audioInputTitle), systemImage: "mic.fill")
                    .tag(AudioPanelTab.input)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case .output:
                outputPanel
            case .input:
                inputPanel
            }
        }
    }

    private var outputPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            VolumeControlsView(
                settings: settings,
                scrollTargets: scrollTargets,
                volume: store.liveVolume,
                isEnabled: store.isVolumeControlAvailable,
                onVolumeChange: { store.setVolume($0) },
                onToggleMute: { store.toggleMute() },
                onSelectOutputDevice: { store.selectOutputDevice($0) },
                onOpenSoundSettings: onOpenSoundSettings
            )

            Divider()
            AppAudioStatusView(
                controller: appAudioController,
                permission: appAudioController.permission,
                outputDevices: store.liveVolume.outputDevices
            )
        }
    }

    private var inputPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            AudioInputControlsView(
                status: store.liveInput,
                onSelect: { store.selectInputDevice($0) },
                onScalarChange: { store.setInputScalar($0) },
                onToggleMute: { store.toggleInputMute() },
                onOpenSoundSettings: onOpenSoundSettings
            )

            Divider()
            AppAudioStatusView(
                controller: appAudioController,
                permission: appAudioController.permission,
                outputDevices: store.liveVolume.outputDevices
            )
        }
    }
}
