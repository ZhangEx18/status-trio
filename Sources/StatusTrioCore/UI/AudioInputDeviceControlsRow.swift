import CoreAudio
import SwiftUI

struct AudioInputDeviceControlsRow: View {
    let device: AudioInputDevice
    let status: AudioInputStatus
    let onScalar: (Double) -> Void
    let onMuted: (Bool) -> Void
    @EnvironmentObject private var localization: Localization
    @State private var draft: Double?
    @State private var isEditing = false

    private var scalar: Double? { device.id == status.defaultDeviceID ? status.scalar : device.scalar }
    private var mute: AudioInputMuteState? { device.id == status.defaultDeviceID ? status.muteState : device.muteState }

    private var displayedScalar: Double? { draft ?? scalar }
    private var isZeroVolume: Bool { displayedScalar.map { ($0 * 100).rounded() == 0 } ?? false }
    private var showsMuted: Bool { mute == .muted || isZeroVolume }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if showsMuted {
                    if isZeroVolume, device.canSetVolume { onScalar(0.5) }
                    if mute == .muted { onMuted(false) }
                } else { onMuted(true) }
            } label: {
                Image(systemName: showsMuted ? "mic.slash" : "mic")
                    .foregroundStyle(showsMuted ? Color.red : Color.secondary)
                    .frame(width: 20, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(isZeroVolume ? !device.canSetVolume : (!device.canSetMute || mute == nil))
            .accessibilityLabel(localization.string(showsMuted ? .audioInputUnmute : .audioInputMute))
            AudioLevelSlider(value: Binding(get: { draft ?? scalar ?? 0 }, set: { value in
                draft = value
                onScalar(value)
                if value > 0, mute == .muted { onMuted(false) }
            }), onEditingChanged: { editing in
                isEditing = editing
                if !editing, !status.isBusy { draft = nil }
            })
            .opacity(showsMuted ? 0.5 : 1)
            .disabled(!device.canSetVolume || scalar == nil)
            .accessibilityLabel(localization.string(.audioInputVolume))
            Text((draft ?? scalar).map { $0.formatted(.percent.precision(.fractionLength(0)).locale(localization.resolvedLanguage.locale)) } ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .onChange(of: status.isBusy) { _, busy in
            if !busy, !isEditing { draft = nil }
        }
        .onChange(of: scalar) { _, _ in
            if !isEditing { draft = nil }
        }
    }
}
