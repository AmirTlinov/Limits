import AppKit
import SwiftUI

struct AccountsWindowView: View {
    @ObservedObject var model: AppModel

    private var overview: AppModel.CurrentCLIOverview {
        model.currentCLIOverview()
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                List {
                    ForEach(model.accounts) { account in
                        AccountRowView(
                            account: account,
                            isCurrentCLIAccount: model.isCurrentCLIAccount(account),
                            isBusy: model.isBusy,
                            onActivate: { Task { await model.activateAccount(account) } },
                            onReauthenticate: { Task { await model.reauthenticateAccount(account) } },
                            onValidate: { Task { await model.validateAccount(account) } },
                            onDelete: { Task { await model.deleteAccount(account) } }
                        )
                    }
                }
                .listStyle(.inset)
            }
            .padding()
            .frame(minWidth: 760, minHeight: 460)
            .navigationTitle("Codex auth switcher")
        }
        .onAppear {
            Task { await model.refreshCurrentCLIPanel(forceProbe: false) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            CurrentCLIOverviewCard(
                overview: overview,
                source: model.currentCLIState.source,
                isBusy: model.isBusy,
                busyMessage: model.busyMessage,
                compact: false
            )

            HStack(spacing: 10) {
                Button("Add account") {
                    Task { await model.addAccount() }
                }
                .disabled(model.isBusy)

                if model.hasCurrentCLIAuthToImport() {
                    Button("Import current CLI auth") {
                        Task { await model.importCurrentCLIAuth() }
                    }
                    .disabled(model.isBusy)
                }

                Button("Validate all") {
                    Task { await model.validateAll() }
                }
                .disabled(model.isBusy)

                if model.isBusy, let busyMessage = model.busyMessage {
                    Text(busyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("This card reads the global ~/.codex/auth.json and refreshes live limits when possible.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AccountRowView: View {
    let account: StoredAccount
    let isCurrentCLIAccount: Bool
    let isBusy: Bool
    let onActivate: () -> Void
    let onReauthenticate: () -> Void
    let onValidate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(account.label)
                            .font(.headline)

                        if isCurrentCLIAccount {
                            Text("CLI active")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.15), in: Capsule())
                        }
                    }

                    Text(account.email)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                statusBadge
            }

            HStack(spacing: 16) {
                LabeledValue(label: "Plan", value: account.planType)
                LabeledValue(label: "Account ID", value: account.accountId ?? "—")
                LabeledValue(label: "Last check", value: formatted(date: account.lastValidatedAt))
                LabeledValue(label: "Limits", value: limitSummary)
            }

            if let statusMessage = account.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Make active for CLI", action: onActivate)
                    .disabled(isBusy)
                Button("Re-authenticate", action: onReauthenticate)
                    .disabled(isBusy)
                Button("Validate", action: onValidate)
                    .disabled(isBusy)
                Button("Delete", role: .destructive, action: onDelete)
                    .disabled(isBusy)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 6)
    }

    private var limitSummary: String {
        guard let limit = account.lastRateLimit else {
            return "—"
        }
        return limit.panelSummary() ?? "Known"
    }

    private var statusBadge: some View {
        Text(account.shortStatusText)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
    }

    private var color: Color {
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

    private func formatted(date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(1)
        }
    }
}
