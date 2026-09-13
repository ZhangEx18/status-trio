import SwiftUI

struct BasicsSettingsPane: View {
    @ObservedObject var localization: Localization
    @ObservedObject private var launchAtLogin: LaunchAtLoginManager

    init(
        localization: Localization,
        launchAtLogin: LaunchAtLoginManager = .shared
    ) {
        self.localization = localization
        self._launchAtLogin = ObservedObject(wrappedValue: launchAtLogin)
    }

    var body: some View {
        PreferencesPane {
            PreferenceRow(
                label: .settingsLanguage,
                description: .settingsLanguageDescription,
                placesControlInline: true
            ) {
                Picker(
                    localization.string(.settingsLanguage),
                    selection: Binding(
                        get: { localization.preference },
                        set: localization.setPreference
                    )
                ) {
                    Text(localization.string(.settingsLanguageFollowSystem))
                        .tag(LanguagePreference.system)

                    ForEach(AppLanguage.allCases) { language in
                        Text(language.nativeName)
                            .tag(LanguagePreference.language(language))
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }

            Divider()

            launchAtLoginSection
        }
    }

    private var launchAtLoginSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PreferenceCheckboxRow(
                label: .settingsLaunchAtLogin,
                description: .settingsLaunchAtLoginDescription,
                isOn: launchAtLogin.isEnabledBinding
            )
            .disabled(!launchAtLogin.isAvailable)

            if launchAtLogin.status == .requiresApproval {
                notice(
                    .settingsLaunchAtLoginRequiresApproval,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange
                )

                Button(localization.string(.settingsLaunchAtLoginOpenLoginItems)) {
                    launchAtLogin.openLoginItemsSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.leading, 18)
            }

            if launchAtLogin.didFailLastOperation {
                notice(
                    .settingsLaunchAtLoginFailure,
                    systemImage: "exclamationmark.octagon.fill",
                    tint: .red
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The user may change the login item in System Settings while we're not
        // looking, so re-read the system state whenever the pane appears.
        .onAppear { launchAtLogin.refresh() }
    }

    private func notice(
        _ key: LocalizationKey,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)

            Text(localization.string(key))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
