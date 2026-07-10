import SwiftUI

struct SettingsView: View {
    let languageDidChange: () -> Void
    @State private var selectedLanguage: String

    init(languageDidChange: @escaping () -> Void) {
        self.languageDidChange = languageDidChange
        _selectedLanguage = State(initialValue: L10n.selectedLanguageOverride ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("settings.title"))
                    .font(.title2.weight(.semibold))
                Text(L10n.tr("settings.subtitle"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("settings.language.title"))
                    .font(.headline)
                Text(L10n.tr("settings.language.description"))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Picker(L10n.tr("settings.language.title"), selection: languageBinding) {
                    Text(L10n.tr("settings.language.system")).tag("")
                    ForEach(L10n.supportedLocalizations, id: \.self) { language in
                        Text(L10n.displayName(for: language)).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 260, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.tr("settings.tray_legend.title"))
                    .font(.headline)
                Text(L10n.tr("settings.tray_legend.description"))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 9) {
                    TrayLegendRow(
                        provider: .codex,
                        color: .blue,
                        sample: "90% 2/8",
                        title: L10n.tr("settings.tray_legend.codex.title"),
                        subtitle: L10n.tr("settings.tray_legend.codex.subtitle")
                    )
                    TrayLegendRow(
                        provider: .claude,
                        color: ProviderAccent.claude,
                        sample: "95% 1/2",
                        title: L10n.tr("settings.tray_legend.claude.title"),
                        subtitle: L10n.tr("settings.tray_legend.claude.subtitle")
                    )
                }
                .padding(14)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 560, height: 420, alignment: .topLeading)
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { selectedLanguage },
            set: { newValue in
                selectedLanguage = newValue
                L10n.setLanguageOverride(newValue.isEmpty ? nil : newValue)
                languageDidChange()
            }
        )
    }
}

private struct TrayLegendRow: View {
    let provider: TrayStatusProvider
    let color: Color
    let sample: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                TrayLegendProviderIcon(provider: provider, color: color)
                    .frame(width: 13, height: 13)
                Text(sample)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.10), in: Capsule())
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct TrayLegendProviderIcon: View {
    let provider: TrayStatusProvider
    let color: Color

    var body: some View {
        if let image = TrayStatusIconAsset.image(for: provider) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(color)
        } else {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color.opacity(0.9))
        }
    }
}
