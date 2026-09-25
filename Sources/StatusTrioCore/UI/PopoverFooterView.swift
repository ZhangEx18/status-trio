import SwiftUI

/// The state-dependent parts of the popover footer, kept as plain data so the
/// settings label can be asserted without rendering a view.
enum PopoverFooterPresentation {
    /// Keep the development codename alongside the settings label.
    static func settingsLabel(title: String, developmentSuffix: String?) -> String {
        guard let developmentSuffix, !developmentSuffix.isEmpty else { return title }
        return "\(title) · \(developmentSuffix)"
    }
}

struct PopoverFooterView: View {
    @EnvironmentObject private var localization: Localization
    let openSettings: () -> Void
    let quit: () -> Void

    private var settingsTitle: String {
        PopoverFooterPresentation.settingsLabel(
            title: localization.string(.menuSettings),
            developmentSuffix: AppMetadata.developmentCodename.map {
                localization.format(.menuSettingsDevelopment, $0)
            }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: openSettings) {
                Label(settingsTitle, systemImage: "gearshape")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)

            Button(action: quit) {
                HStack(spacing: 8) {
                    Text(localization.resolvedLanguage == .simplifiedChinese ? "退出 ⌘Q" : localization.string(.menuQuit))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)

        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
