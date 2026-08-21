import SwiftUI
import LimitsCore
import LimitsShared

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let languageDidChange: () -> Void
    let checkForUpdates: () -> Void
    @State private var selectedLanguage: String
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @State private var confirmsStatisticsClear = false

    init(model: AppModel, languageDidChange: @escaping () -> Void, checkForUpdates: @escaping () -> Void) {
        self.model = model
        self.languageDidChange = languageDidChange
        self.checkForUpdates = checkForUpdates
        _selectedLanguage = State(initialValue: L10n.selectedLanguageOverride ?? "")
    }

    private var catalog: ProviderCatalogSnapshot { model.providerCatalog }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(L10n.tr("settings.title"))
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("settings.general.title"))
                    .font(.headline)

                Toggle(L10n.tr("settings.launch_at_login.title"), isOn: launchAtLoginBinding)
                .disabled(launchAtLogin.state == .unavailable)

                if launchAtLogin.state == .requiresApproval {
                    HStack(spacing: 8) {
                        Text(L10n.tr("settings.launch_at_login.requires_approval"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button(L10n.tr("settings.launch_at_login.open_settings")) {
                            launchAtLogin.openSystemSettings()
                        }
                        .buttonStyle(.link)
                    }
                } else if launchAtLogin.state == .unavailable {
                    Text(L10n.tr("settings.launch_at_login.unavailable"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = launchAtLogin.errorMessage {
                    Text(L10n.tr("settings.launch_at_login.error", errorMessage))
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button(L10n.tr("settings.updates.check"), action: checkForUpdates)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("insights.settings.title"))
                    .font(.headline)
                Text(L10n.tr("insights.settings.description"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button(L10n.tr("insights.settings.reimport")) {
                        Task { await model.reimportCodexHistory() }
                    }
                    .disabled(model.isProviderBusy(.codex) || !model.canMutateDomain)

                    Button(L10n.tr("insights.settings.clear"), role: .destructive) {
                        confirmsStatisticsClear = true
                    }
                    .disabled(model.isProviderBusy(.codex) || !model.canMutateDomain)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("settings.language.title"))
                    .font(.headline)
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
                    ForEach(catalog.trayProviders, id: \.self) { provider in
                        TrayLegendRow(
                            provider: provider,
                            color: provider == .codex ? .blue : ProviderAccent.claude,
                            sample: provider == .codex ? "90% 2/8" : "95% 1/2",
                            title: L10n.tr(provider == .codex ? "settings.tray_legend.codex.title" : "settings.tray_legend.claude.title")
                        )
                    }
                }
                .padding(14)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 560, height: 640, alignment: .topLeading)
        .onAppear {
            launchAtLogin.refresh()
        }
        .confirmationDialog(
            L10n.tr("insights.settings.clear.confirm_title"),
            isPresented: $confirmsStatisticsClear,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("insights.settings.clear"), role: .destructive) {
                Task { await model.clearCodexStatistics() }
            }
            Button(L10n.tr("action.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("insights.settings.clear.confirm_message"))
        }
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

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.state.isRequested },
            set: { launchAtLogin.setEnabled($0) }
        )
    }
}

private struct TrayLegendRow: View {
    let provider: TrayStatusProvider
    let color: Color
    let sample: String
    let title: String

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

            Text(title).font(.callout.weight(.semibold))
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
