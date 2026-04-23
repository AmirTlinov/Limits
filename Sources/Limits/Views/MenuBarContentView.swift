import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: AppModel
    let openAccountsWindow: () -> Void

    private var overview: AppModel.CurrentCLIOverview {
        model.currentCLIOverview()
    }

    private var quickSwitchAccounts: [StoredAccount] {
        model.menuPanelAccounts()
    }

    private var currentCompactRows: [RateLimitDisplayRow] {
        compactRows(from: model.currentCLIRateLimitSections())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if #available(macOS 26.0, *), !quickSwitchAccounts.isEmpty {
                GlassEffectContainer(spacing: 6) {
                    CurrentCLIOverviewCard(
                        overview: overview,
                        source: model.currentCLIState.source,
                        compactRows: currentCompactRows,
                        updatedAt: model.currentCLIValidatedAt(),
                        isBusy: model.isBusy,
                        busyMessage: model.busyMessage,
                        compact: true
                    )

                    ForEach(quickSwitchAccounts) { account in
                        AccountSwitchRow(account: account, compactRows: compactRows(from: model.rateLimitSections(for: account))) {
                            Task { await model.activateAccount(account) }
                        }
                        .disabled(model.isBusy)
                    }
                }
            } else {
                CurrentCLIOverviewCard(
                    overview: overview,
                    source: model.currentCLIState.source,
                    compactRows: currentCompactRows,
                    updatedAt: model.currentCLIValidatedAt(),
                    isBusy: model.isBusy,
                    busyMessage: model.busyMessage,
                    compact: true
                )

                if !quickSwitchAccounts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(quickSwitchAccounts) { account in
                            AccountSwitchRow(account: account, compactRows: compactRows(from: model.rateLimitSections(for: account))) {
                                Task { await model.activateAccount(account) }
                            }
                            .disabled(model.isBusy)
                        }
                    }
                }
            }

            footer
        }
        .padding(12)
        .frame(width: 326)
        .onAppear {
            Task { await model.refreshCurrentCLIPanel(forceProbe: false) }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            if model.hasCurrentCLIAuthToImport() {
                panelActionButton("Импортировать", primary: true) {
                    Task { await model.importCurrentCLIAuth() }
                }
                .disabled(model.isBusy)
            } else if model.shouldOfferAddAccountAsPrimaryAction() {
                panelActionButton("Добавить", primary: true) {
                    Task { await model.addAccount() }
                }
                .disabled(model.isBusy)
            }

            Spacer(minLength: 0)

            panelActionButton("Окно…") {
                openAccountsWindow()
            }
            .disabled(model.isBusy)

            Menu {
                Button("Добавить аккаунт") {
                    Task { await model.addAccount() }
                }

                if model.hasCurrentCLIAuthToImport() {
                    Button("Импортировать текущую авторизацию") {
                        Task { await model.importCurrentCLIAuth() }
                    }
                }

                if !model.accounts.isEmpty {
                    Button("Обновить лимиты") {
                        Task { await model.validateAll() }
                    }
                }

                Divider()

                Button("Выход") {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.large)
                    .frame(width: 32, height: 32)
            }
            .menuStyle(.borderlessButton)
        }
    }

    @ViewBuilder
    private func panelActionButton(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        if #available(macOS 26.0, *) {
            if primary {
                Button(title, action: action)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.roundedRectangle(radius: 14))
                    .tint(.accentColor)
            } else {
                Button(title, action: action)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.roundedRectangle(radius: 14))
            }
        } else {
            if primary {
                Button(title, action: action)
                    .buttonStyle(.borderedProminent)
            } else {
                Button(title, action: action)
                    .buttonStyle(.bordered)
            }
        }
    }

    private func compactRows(from sections: [RateLimitDisplaySection]) -> [RateLimitDisplayRow] {
        Array((sections.first?.rows ?? []).prefix(2))
    }
}

private struct AccountSwitchRow: View {
    let account: StoredAccount
    let compactRows: [RateLimitDisplayRow]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)

                    Text(account.label)
                        .lineLimit(1)

                    Spacer(minLength: 8)
                }

                if !compactRows.isEmpty {
                    CompactLimitBarsView(rows: compactRows, dense: true)
                } else {
                    Text(account.lastRateLimit?.compactUsageSummary() ?? account.shortStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .trayPanelSectionChrome(
                in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                interactive: true
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        switch account.status {
        case .ok:
            return .green
        case .limitReached:
            return .orange
        case .needsReauth, .validationFailed:
            return .red
        case .unknown:
            return .gray
        }
    }
}
