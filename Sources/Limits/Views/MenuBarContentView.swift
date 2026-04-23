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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CurrentCLIOverviewCard(
                overview: overview,
                source: model.currentCLIState.source,
                isBusy: model.isBusy,
                busyMessage: model.busyMessage,
                compact: true
            )

            if !quickSwitchAccounts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(quickSwitchAccounts) { account in
                        AccountSwitchRow(account: account) {
                            Task { await model.activateAccount(account) }
                        }
                        .disabled(model.isBusy)
                    }
                }
            }

            footer
        }
        .padding(12)
        .frame(width: 320)
        .onAppear {
            Task { await model.refreshCurrentCLIPanel(forceProbe: false) }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            if model.hasCurrentCLIAuthToImport() {
                Button("Импортировать") {
                    Task { await model.importCurrentCLIAuth() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
            } else if model.shouldOfferAddAccountAsPrimaryAction() {
                Button("Добавить") {
                    Task { await model.addAccount() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
            }

            Spacer(minLength: 0)

            Button("Окно…") {
                openAccountsWindow()
            }
            .buttonStyle(.bordered)
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
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
        }
    }
}

private struct AccountSwitchRow: View {
    let account: StoredAccount
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.label)
                        .lineLimit(1)

                    Text(account.lastRateLimit?.compactUsageSummary() ?? account.shortStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(0.14))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
