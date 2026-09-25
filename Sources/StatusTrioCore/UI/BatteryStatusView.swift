import SwiftUI

/// The battery summary row. Like the Wi-Fi and Bluetooth rows, the row itself
/// is the affordance: activating it switches the popover to the battery page.
struct BatteryStatusView: View {
    @EnvironmentObject private var localization: Localization
    let battery: BatteryStatus
    let onOpenBatteryDetails: () -> Void
    let onOpenBatterySettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpenBatteryDetails) {
                HStack(spacing: 10) {
                    batteryIcon
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(StatusPresentation.batteryTitle(battery, localization: localization))
                            .font(.headline)
                            .monospacedDigit()
                        Text(StatusPresentation.batterySubtitle(battery, localization: localization))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !battery.isConnectedToPower, !battery.isCharging,
                           let minutes = battery.remainingMinutes, minutes > 0 {
                            Text(localization.format(.commonLabelValue,
                                localization.string(.batteryDetailsRemaining),
                                Duration.seconds(Double(minutes) * 60).formatted(
                                    .units(allowed: [.hours, .minutes], width: .abbreviated)
                                        .locale(localization.resolvedLanguage.locale))))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if showsDetailAffordance {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!showsDetailAffordance)
            .accessibilityLabel(StatusPresentation.batteryTitle(battery, localization: localization))
            .accessibilityValue(StatusPresentation.batterySubtitle(battery, localization: localization))

            if battery.isPresent {
                Button(
                    localization.string(.batteryActionOpenSettings),
                    systemImage: "gearshape",
                    action: onOpenBatterySettings
                )
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(localization.string(.batteryActionOpenSettings))
                .frame(width: 24, height: 24)
            }
        }
    }

    /// A Mac without a battery has no details to open, so the row stays inert
    /// and shows no chevron — the same shape as an unavailable Bluetooth radio.
    var showsDetailAffordance: Bool { battery.isPresent }

    @ViewBuilder
    private var batteryIcon: some View {
        if !battery.isPresent {
            Image(systemName: "battery.slash")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
        } else {
            ZStack {
                HStack(spacing: 1) {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).strokeBorder(.primary, lineWidth: 1.3)
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 0.7)
                                .fill(.primary)
                                .frame(width: geometry.size.width * Double(battery.percentage) / 100)
                        }
                        .padding(2.5)
                    }
                    RoundedRectangle(cornerRadius: 1).fill(.primary).frame(width: 2, height: 5)
                }
                .frame(width: 24, height: 12)
                if battery.isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.primary)
                        .shadow(color: Color(nsColor: .windowBackgroundColor), radius: 1)
                }
            }
            .foregroundStyle(.primary)
        }
    }

}
