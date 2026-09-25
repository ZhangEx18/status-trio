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
                Button(action: onOpenSoundSettings) {
                    Image(systemName: "gearshape.fill")
                }
                .buttonStyle(.plain)
                .help(localization.string(.volumeActionOpenSettings))
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
        VStack(spacing: 8) {
            if store.liveVolume.outputDevices.isEmpty {
                VolumeControlsView(settings: settings, scrollTargets: scrollTargets,
                    volume: store.liveVolume, isEnabled: store.isVolumeControlAvailable,
                    onVolumeChange: { store.setVolume($0) }, onToggleMute: { store.toggleMute() },
                    onSelectOutputDevice: { store.selectOutputDevice($0) }, onOpenSoundSettings: onOpenSoundSettings)
            }
            ForEach(store.liveVolume.outputDevices) { device in
                HStack(spacing: 8) {
                    Button { store.selectOutputDevice(device) } label: {
                        HStack(spacing: 8) {
                            AudioOutputDeviceIconView(device: device, glyphSize: 15)
                                .foregroundStyle(device.isCurrent ? Color.white : Color.secondary)
                                .frame(width: 28, height: 28)
                                .background(device.isCurrent ? Color.accentColor : Color.secondary.opacity(0.12), in: Circle())
                            Text(device.name ?? localization.string(.volumeOutputUnknownDevice))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(device.isCurrent ? localization.string(.volumeOutputCurrent) : "")
                    if device.isCurrent {
                        Button { store.toggleMute() } label: {
                            Image(systemName: store.liveVolume.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        }
                        .buttonStyle(.plain)
                        .disabled(!store.isVolumeControlAvailable)
                        .accessibilityLabel(localization.string(store.liveVolume.isMuted ? .volumeUnmuted : .volumeMuted))
                        Slider(value: Binding(get: { store.liveVolume.scalar ?? 0 },
                            set: { store.setVolume($0) }), in: 0...1)
                            .background(VolumeControlScrollTarget(targets: scrollTargets))
                            .frame(width: 90)
                            .disabled(!store.isVolumeControlAvailable)
                            .accessibilityLabel(localization.string(.volumeAccessibilityLabel))
                        Text((store.liveVolume.scalar ?? 0).formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption.monospacedDigit())
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
    }
}
