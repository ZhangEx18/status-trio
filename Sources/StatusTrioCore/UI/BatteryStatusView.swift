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
                // Use the native symbol's silhouette, with continuous capacity
                // inside its body rather than rounding to five SF Symbol levels.
                Image(systemName: "battery.0percent")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 25, height: 13)
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1)
                        .frame(width: 18 * CGFloat(battery.percentage) / 100, height: 7)
                    Spacer(minLength: 0)
                }
                .frame(width: 18, height: 7)
                .offset(x: -1)
                if battery.isCharging {
                    // Knock out a border around the bolt so it stays legible
                    // over both the filled and empty portions in either theme.
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 12, weight: .bold))
                        .scaleEffect(1.3)
                        .blendMode(.destinationOut)
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundStyle(.primary)
            .compositingGroup()
        }
    }

}
