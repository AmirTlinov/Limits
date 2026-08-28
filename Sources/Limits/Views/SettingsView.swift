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
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.tr("settings.title"))
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 14)

            Form {
                Section {
                    Toggle(L10n.tr("settings.launch_at_login.title"), isOn: launchAtLoginBinding)
                        .disabled(launchAtLogin.state == .unavailable)

                    if launchAtLogin.state == .requiresApproval {
                        HStack(spacing: 8) {
                            Text(L10n.tr("settings.launch_at_login.requires_approval"))
                                .foregroundStyle(.orange)
                            Spacer(minLength: 12)
                            Button(L10n.tr("settings.launch_at_login.open_settings")) {
                                launchAtLogin.openSystemSettings()
                            }
                        }
                        .font(.caption)
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
                } header: {
                    Text(L10n.tr("settings.general.title"))
                }

                Section {
                    SettingsMaintenanceAction(
                        title: L10n.tr("insights.settings.reimport"),
                        detail: L10n.tr("insights.settings.reimport.detail"),
                        isDisabled: model.isProviderBusy(.codex) || !model.canMutateDomain
                    ) {
                        Task { await model.reimportCodexHistory() }
                    }

                    SettingsMaintenanceAction(
                        title: L10n.tr("insights.settings.clear"),
                        detail: L10n.tr("insights.settings.clear.detail"),
                        role: .destructive,
                        isDisabled: model.isProviderBusy(.codex) || !model.canMutateDomain
                    ) {
                        confirmsStatisticsClear = true
                    }
                } header: {
                    Text(L10n.tr("insights.settings.title"))
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("insights.settings.privacy.detail"))
                        if let privacyURL = URL(string: "https://github.com/AmirTlinov/Limits/blob/main/PRIVACY.md") {
                            Link(L10n.tr("insights.settings.privacy.link"), destination: privacyURL)
                        }
                    }
                }

                Section {
                    Picker(L10n.tr("settings.language.title"), selection: languageBinding) {
                        Text(L10n.tr("settings.language.system")).tag("")
                        ForEach(L10n.supportedLocalizations, id: \.self) { language in
                            Text(L10n.displayName(for: language)).tag(language)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 260, alignment: .leading)
                } header: {
                    Text(L10n.tr("settings.language.title"))
                }

                Section {
                    ForEach(catalog.trayProviders, id: \.self) { provider in
                        TrayLegendRow(
                            provider: provider,
                            color: provider == .codex ? .blue : ProviderAccent.claude,
                            sample: provider == .codex ? "90% 2/8" : "95% 1/2",
                            title: L10n.tr(provider == .codex ? "settings.tray_legend.codex.title" : "settings.tray_legend.claude.title")
                        )
                    }
                } header: {
                    Text(L10n.tr("settings.tray_legend.title"))
                } footer: {
                    Text(L10n.tr("settings.tray_legend.description"))
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 560)
        .frame(minHeight: 680, alignment: .topLeading)
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

private struct SettingsMaintenanceAction: View {
    let title: String
    let detail: String
    var role: ButtonRole?
    let isDisabled: Bool
    let action: () -> Void

    init(
        title: String,
        detail: String,
        role: ButtonRole? = nil,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.role = role
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(title, role: role, action: action)
                .disabled(isDisabled)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
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
