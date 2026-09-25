import SwiftUI

/// The paired-device list shown inside the status panel, under the Bluetooth
/// row. It mirrors the volume output list: the first `limit` devices are always
/// visible and anything beyond them is revealed by an expansion control. Each
/// row is a control: tapping it connects or disconnects that device, and an
/// input device's disconnect is confirmed in place first.
struct BluetoothDeviceList: View {
    @EnvironmentObject private var localization: Localization
    let devices: [BluetoothDevice]
    let batteryLevels: [String: BluetoothBatteryLevel]
    let actionStates: [String: BluetoothDeviceActionState]
    /// The device whose disconnect is waiting for confirmation, by normalized
    /// address. The controller owns it so that closing the panel cancels it even
    /// though the popover keeps this view alive.
    let confirmingAddress: String?
    let options: BluetoothDeviceListOptions
    let onPerformAction: (BluetoothDevice) -> Void
    let onRequestDisconnect: (BluetoothDevice) -> Void
    let onCancelDisconnect: () -> Void

    @State private var isExpanded = false

    /// How tall the rows may grow before they scroll, matching the Wi-Fi list's
    /// own bound so the two lists in the panel stop at the same place.
    static let maximumRowsHeight: CGFloat = 330

    /// How tall one row is: the badge sets its height, because the name is a
    /// single line and never taller. The list can therefore tell whether it needs
    /// a scroll view at all without measuring anything.
    private static let rowSpacing: CGFloat = 2
    private static let rowPitch = BluetoothPanelMetrics.iconColumnWidth + rowSpacing
    private static var rowsThatFit: Int { Int(maximumRowsHeight / rowPitch) }

    var body: some View {
        let model = BluetoothDeviceListModel.make(
            devices: devices,
            order: options.order,
            limit: options.maxVisibleDevices,
            isExpanded: isExpanded,
            options: options
        )

        VStack(spacing: Self.rowSpacing) {
            rows(model.visibleDevices, needsScrolling: model.orderedDevices.count > Self.rowsThatFit)

            // Deliberately outside the scroll region: collapsing a long list must
            // not require scrolling to the bottom first.
            if model.canToggleExpansion {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))

                        Text(
                            localization.string(
                                isExpanded ? .bluetoothListCollapse : .bluetoothListExpand
                            )
                        )
                        .font(.callout)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Use a scroll container for lists whose full contents exceed the panel.
    /// Its identity stays fixed while expansion changes only the visible rows.
    /// Short lists stay in a plain stack so no scroller appears during layout.
    @ViewBuilder
    private func rows(_ visibleDevices: [BluetoothDevice], needsScrolling: Bool) -> some View {
        // Container identity depends on the full list, never on expansion.
        // Existing rows therefore survive both expanding and collapsing.
        if needsScrolling {
            ScrollView { rowStack(visibleDevices) }
                .frame(height: min(Self.maximumRowsHeight, CGFloat(visibleDevices.count) * Self.rowPitch))
        } else {
            rowStack(visibleDevices)
        }
    }

    private func rowStack(_ visibleDevices: [BluetoothDevice]) -> some View {
        VStack(spacing: Self.rowSpacing) {
            ForEach(visibleDevices) { device in
                let address = BluetoothBatteryReader.normalizedAddress(device.id)
                BluetoothDeviceRow(
                    device: device,
                    batteryLevels: batteryLevels,
                    actionState: actionStates[address],
                    isConfirmingDisconnect: confirmingAddress == address
                        && BluetoothDeviceActionPolicy.requiresConfirmation(for: device),
                    onPerformAction: { onPerformAction(device) },
                    onRequestDisconnect: { onRequestDisconnect(device) },
                    onCancelDisconnect: onCancelDisconnect
                )
            }
        }
    }
}
