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
                .foregroundStyle(batterySymbolColor)
        } else {
            ZStack {
                Image(systemName: batteryLevelSymbolName)
                    .font(.system(size: 15, weight: .medium))

                if battery.isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(batterySymbolColor)
        }
    }

    private var batteryLevelSymbolName: String {
        switch StatusMappings.batteryLevelBucket(battery) {
        case .full: return "battery.100"
        case .threeQuarter: return "battery.75"
        case .half: return "battery.50"
        case .quarter: return "battery.25"
        case .empty: return "battery.0"
        }
    }

    private var batterySymbolColor: Color {
        guard battery.isPresent else { return .secondary }
        if battery.isCharging || battery.isConnectedToPower {
            return .green
        }
        if battery.isLowPowerMode {
            return .yellow
        }
        if battery.percentage <= 20 {
            return .red
        }
        return .primary
    }
}
