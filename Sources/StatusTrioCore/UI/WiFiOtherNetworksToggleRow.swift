import SwiftUI

struct WiFiOtherNetworksToggleRow: View {
    @Binding var isExpanded: Bool

    @EnvironmentObject private var localization: Localization

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack {
                Text(localization.string(.wifiOtherNetworks))
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            // The row is the hit target across the whole list width, not just
            // the glyphs it draws.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localization.string(.wifiOtherNetworks))
    }
}
