import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: AppModel
    let openAccountsWindow: () -> Void

    private var codexOverview: AppModel.CurrentCLIOverview {
        model.currentCLIOverview()
    }

    private var claudeOverview: AppModel.CurrentClaudeOverview {
        model.currentClaudeOverview()
    }

    private var currentCodexRows: [RateLimitDisplayRow] {
        compactRows(from: model.currentCLIRateLimitSections())
    }

    private var currentClaudeRows: [RateLimitDisplayRow] {
        compactRows(from: model.currentClaudeLiveRateLimitSections())
    }

    private var storedCodexAccounts: [StoredAccount] {
        model.accounts.filter { !model.isCurrentCLIAccount($0) }
    }

    private var storedClaudeAccounts: [ClaudeStoredAccount] {
        model.claudeAccounts.filter { !model.isCurrentClaudeAccount($0) }
    }

    private var shouldShowClaudeRow: Bool {
        AccountsPresentationLogic.shouldShowCurrentClaude(
            source: model.currentClaudeState.source,
            storedClaudeCount: model.claudeAccounts.count
        )
    }

    private var hasStoredRows: Bool {
        !storedCodexAccounts.isEmpty || !storedClaudeAccounts.isEmpty
    }

    private var shouldScrollStoredRows: Bool {
        AccountsPresentationLogic.needsStoredAccountsScroll(
            storedCodexCount: storedCodexAccounts.count,
            storedClaudeCount: storedClaudeAccounts.count
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                TrayAccountRow(
                    symbolName: "terminal",
                    title: codexOverview.title,
                    subtitle: codexOverview.subtitle,
                    compactRows: currentCodexRows,
                    detailText: codexCurrentDetailText,
                    metaText: updatedAtText(for: model.currentCLIValidatedAt()),
                    accent: codexAccent,
                    badgeText: codexBadgeText,
                    badgeColor: codexAccent,
                    interactive: false,
                    action: nil
                )

                if shouldShowClaudeRow {
                    TrayAccountRow(
                        symbolName: "text.bubble",
                        title: claudeOverview.title,
                        subtitle: claudeOverview.subtitle,
                        compactRows: currentClaudeRows,
                        detailText: claudeCurrentDetailText,
                        metaText: updatedAtText(for: model.claudeLiveBridgeSnapshotUpdatedAt() ?? model.claudeValidatedAt()),
                        accent: claudeAccent,
                        badgeText: claudeBadgeText,
                        badgeColor: claudeAccent,
                        interactive: false,
                        action: nil
                    )
                }
            }

            if hasStoredRows {
                MinimalSeparator()
                    .padding(.vertical, 2)

                Group {
                    if shouldScrollStoredRows {
                        ScrollView(.vertical, showsIndicators: false) {
                            storedAccountRows
                        }
                        .frame(maxHeight: 240)
                    } else {
                        storedAccountRows
                    }
                }
            }

            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(width: 326)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            Task {
                await model.refreshCurrentCLIPanel(forceProbe: false)
                await model.refreshCurrentClaudeState()
            }
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

                if model.hasCurrentClaudeAuthToImport() {
                    Button("Импортировать текущий Claude Code") {
                        Task { await model.importCurrentClaudeAuth() }
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

    private var codexCurrentDetailText: String? {
        if currentCodexRows.isEmpty, let limits = codexOverview.limits {
            return limits
        }

        switch model.currentCLIState.source {
        case .missing, .unreadable:
            return codexOverview.note
        case .stored, .external:
            return nil
        }
    }

    private var claudeCurrentDetailText: String? {
        guard currentClaudeRows.isEmpty else {
            return nil
        }

        switch model.currentClaudeState.source {
        case .loggedOut, .notInstalled, .unreadable:
            return claudeOverview.note
        case .stored, .external:
            return model.currentClaudeBridgeError
        }
    }

    private var codexBadgeText: String {
        switch model.currentCLIState.source {
        case .stored, .external:
            return "Текущий"
        case .missing:
            return "Нет входа"
        case .unreadable:
            return "Ошибка"
        }
    }

    private var claudeBadgeText: String {
        switch model.currentClaudeState.source {
        case .stored, .external:
            return "Текущий"
        case .loggedOut:
            return "Нет входа"
        case .notInstalled:
            return "Нет CLI"
        case .unreadable:
            return "Ошибка"
        }
    }

    private var codexAccent: Color {
        switch model.currentCLIState.source {
        case .stored, .external:
            return .blue
        case .missing:
            return .secondary
        case .unreadable:
            return .red
        }
    }

    private var claudeAccent: Color {
        switch model.currentClaudeState.source {
        case .stored, .external:
            return .purple
        case .loggedOut, .unreadable:
            return .red
        case .notInstalled:
            return .secondary
        }
    }

    private func statusColor(for status: AccountStatus, isCurrent: Bool, providerAccent: Color) -> Color {
        if isCurrent {
            return providerAccent
        }

        switch status {
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

    private func storedCodexSubtitle(for account: StoredAccount) -> String? {
        if account.label.caseInsensitiveCompare(account.email) != .orderedSame {
            return account.email
        }

        if account.planType.caseInsensitiveCompare("unknown") != .orderedSame {
            return model.localizedPlan(account.planType)
        }

        return nil
    }

    private func storedCodexDetail(for account: StoredAccount) -> String? {
        if compactRows(from: model.rateLimitSections(for: account)).isEmpty {
            return account.lastRateLimit?.compactUsageSummary() ?? account.shortStatusText
        }
        return nil
    }

    private func storedClaudeSubtitle(for account: ClaudeStoredAccount) -> String? {
        if account.label.caseInsensitiveCompare(account.email) != .orderedSame {
            return account.email
        }

        let plan = model.localizedClaudePlan(account.subscriptionType)
        return plan == "Подписка Claude" ? nil : plan
    }

    private func updatedAtText(for date: Date?) -> String? {
        guard let date else { return nil }
        return "Обновлено \(Self.updatedAtFormatter.string(from: date))"
    }

    private static let updatedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    @ViewBuilder
    private var storedAccountRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(storedCodexAccounts) { account in
                TrayAccountRow(
                    symbolName: "terminal",
                    title: account.label,
                    subtitle: storedCodexSubtitle(for: account),
                    compactRows: compactRows(from: model.rateLimitSections(for: account)),
                    detailText: storedCodexDetail(for: account),
                    metaText: nil,
                    accent: statusColor(for: account.status, isCurrent: false, providerAccent: .blue),
                    badgeText: nil,
                    badgeColor: .secondary,
                    interactive: true
                ) {
                    Task { await model.activateAccount(account) }
                }
                .disabled(model.isBusy)
            }

            ForEach(storedClaudeAccounts) { account in
                TrayAccountRow(
                    symbolName: "text.bubble",
                    title: account.label,
                    subtitle: storedClaudeSubtitle(for: account),
                    compactRows: [],
                    detailText: account.shortStatusText,
                    metaText: nil,
                    accent: statusColor(for: account.status, isCurrent: false, providerAccent: .purple),
                    badgeText: nil,
                    badgeColor: .secondary,
                    interactive: true
                ) {
                    Task { await model.activateClaudeAccount(account) }
                }
                .disabled(model.isBusy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TrayAccountRow: View {
    let symbolName: String
    let title: String
    let subtitle: String?
    let compactRows: [RateLimitDisplayRow]
    let detailText: String?
    let metaText: String?
    let accent: Color
    let badgeText: String?
    let badgeColor: Color
    let interactive: Bool
    let action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .lineLimit(1)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let badgeText, !badgeText.isEmpty {
                    Text(badgeText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(badgeColor.opacity(0.14), in: Capsule())
                }
            }

            if !compactRows.isEmpty {
                CompactLimitBarsView(rows: compactRows, dense: true)
            } else if let detailText, !detailText.isEmpty {
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let metaText, !metaText.isEmpty {
                HStack {
                    Spacer(minLength: 0)

                    Text(metaText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundChrome)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var backgroundChrome: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        if interactive {
            Color.clear
                .trayPanelSectionChrome(in: shape, interactive: true)
        } else {
            Color.clear
                .overlay {
                    shape.stroke(.primary.opacity(0.10), lineWidth: 1)
                }
        }
    }
}
