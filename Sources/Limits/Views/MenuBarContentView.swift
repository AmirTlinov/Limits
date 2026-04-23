import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: AppModel
    let openAccountsWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shortened(model.currentCLISummary()))
                .font(.headline)

            if let active = model.accounts.first(where: { model.isCurrentCLIAccount($0) }) {
                StatusLine(account: active)
            } else {
                Text("No stored CLI match")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.isBusy, let busyMessage = model.busyMessage {
                Text(shortened(busyMessage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if model.accounts.isEmpty {
                Text("No accounts saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.accounts) { account in
                    Button(shortened(account.label)) {
                        Task { await model.activateAccount(account) }
                    }
                    .disabled(model.isBusy)
                }
            }

            Divider()

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

            Button("Validate now") {
                Task { await model.validateAll() }
            }
            .disabled(model.isBusy)

            Button("Manage accounts…") {
                openAccountsWindow()
            }
            .disabled(model.isBusy)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private func shortened(_ text: String) -> String {
        if text.count <= 30 {
            return text
        }
        return String(text.prefix(27)) + "..."
    }
}

private struct StatusLine: View {
    let account: StoredAccount

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(shortText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var shortText: String {
        if let message = account.statusMessage, !message.isEmpty {
            return message
        }
        return account.shortStatusText
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
}

