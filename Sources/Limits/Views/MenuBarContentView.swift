import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ObservedObject var model: AppModel
    let openAccountsWindow: () -> Void

    private var overview: AppModel.CurrentCLIOverview {
        model.currentCLIOverview()
    }

    private var quickSwitchAccounts: [StoredAccount] {
        model.menuPanelAccounts()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CurrentCLIOverviewCard(
                overview: overview,
                source: model.currentCLIState.source,
                updatedAt: model.currentCLIValidatedAt(),
                isBusy: model.isBusy,
                busyMessage: model.busyMessage,
                compact: true
            )

            if !quickSwitchAccounts.isEmpty, #available(macOS 26.0, *), !reduceTransparency {
                GlassEffectContainer(spacing: 6) {
                    ForEach(quickSwitchAccounts) { account in
                        AccountSwitchRow(account: account) {
                            Task { await model.activateAccount(account) }
                        }
                        .disabled(model.isBusy)
                    }
                }
            } else if !quickSwitchAccounts.isEmpty {
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
                    .glassPanelSurface(
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                        interactive: true,
                        fallbackMaterial: .thinMaterial
                    )
            }
            .menuStyle(.borderlessButton)
        }
    }

    @ViewBuilder
    private func panelActionButton(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        if #available(macOS 26.0, *) {
            if primary {
                Button(title, action: action)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 14))
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
            .glassPanelSurface(
                in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                interactive: true,
                fallbackMaterial: .thinMaterial
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
