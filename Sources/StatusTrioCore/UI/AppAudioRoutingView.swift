import SwiftUI

struct AppAudioRoutingView: View {
    @ObservedObject var controller: PerAppAudioController
    let app: AudioAppDescriptor
    let devices: [AudioOutputDevice]
    @EnvironmentObject private var localization: Localization
    @State private var isPresented = false

    private var value: PerAppAudioSettings { controller.settings(for: app) }

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: value.routing == .followSystemDefault ? "globe" : "hifispeaker.2.fill")
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localization.string(.audioRoutingTitle))
        .popover(isPresented: $isPresented) {
            VStack(spacing: 8) {
                HStack(spacing: 2) {
                    modeButton(false, title: .audioRoutingSingle)
                    modeButton(true, title: .audioRoutingMultiple)
                }
                .padding(3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                Divider()
                Button {
                    if value.usesMultipleDevices {
                        controller.setMultipleDevices(false, for: app)
                    }
                    controller.setRouting(.followSystemDefault, outputDeviceUIDs: [], for: app)
                } label: {
                    HStack {
                        selectionMark(selected: value.routing == .followSystemDefault && !value.usesMultipleDevices)
                        Image(systemName: "globe")
                        VStack(alignment: .leading) {
                            Text(localization.string(.audioRoutingSystem))
                            Text(localization.string(value.usesMultipleDevices ? .audioRoutingSystemUnavailable : .audioRoutingFollowSystem))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Choosing the system route always returns to single-device mode.
                // Keep the row available so a multi-device route can be exited
                // without first selecting another hardware device.
                ForEach(devices) { device in
                    if let uid = device.uid {
                        Button { select(uid) } label: {
                            HStack {
                                selectionMark(selected: value.outputDeviceUIDs.contains(uid))
                                AudioOutputDeviceIconView(device: device)
                                Text(device.name ?? localization.string(.volumeOutputUnknownDevice))
                                Spacer()
                                if device.isCurrent { Image(systemName: "star.fill").foregroundStyle(.secondary) }
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
            .frame(width: 280)
        }
    }

    private func modeButton(_ multiple: Bool, title: LocalizationKey) -> some View {
        Button { controller.setMultipleDevices(multiple, for: app) } label: {
            Label(localization.string(title), systemImage: value.usesMultipleDevices == multiple ? "checkmark.circle.fill" : "circle")
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(value.usesMultipleDevices == multiple ? Color.accentColor.opacity(0.2) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func selectionMark(selected: Bool) -> some View {
        Image(systemName: value.usesMultipleDevices ? (selected ? "checkmark.square.fill" : "square") : "checkmark")
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .opacity(value.usesMultipleDevices || selected ? 1 : 0)
            .frame(width: 18)
    }

    private func select(_ uid: String) {
        var selected = value.outputDeviceUIDs
        if value.usesMultipleDevices {
            if selected.contains(uid) {
                // A route must retain at least one output while in multi mode.
                guard selected.count > 1 else { return }
                selected.removeAll { $0 == uid }
            } else { selected.append(uid) }
        } else { selected = [uid] }
        controller.setRouting(.explicit, outputDeviceUIDs: selected, for: app)
    }
}
