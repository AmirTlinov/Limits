import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: AppModel
    let openAccountsWindow: () -> Void

    @AppStorage("limits.tray.codex.expanded") private var codexExpanded = true
    @AppStorage("limits.tray.claude.expanded") private var claudeExpanded = true
    @AppStorage("limits.tray.provider.filter") private var providerFilterRaw = AccountsSidebarFilter.all.rawValue

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

    private var codexAccountCount: Int {
        (currentCodexCountsAsAccount ? 1 : 0) + storedCodexAccounts.count
    }

    private var claudeAccountCount: Int {
        (currentClaudeCountsAsAccount ? 1 : 0) + storedClaudeAccounts.count
    }

    private var currentCodexCountsAsAccount: Bool {
        switch model.currentCLIState.source {
        case .stored, .external:
            return true
        case .missing, .unreadable:
            return false
        }
    }

    private var currentClaudeCountsAsAccount: Bool {
        switch model.currentClaudeState.source {
        case .stored, .external:
            return true
        case .loggedOut, .notInstalled, .unreadable:
            return false
        }
    }

    private var shouldShowClaudeRow: Bool {
        AccountsPresentationLogic.shouldShowCurrentClaude(
            source: model.currentClaudeState.source,
            storedClaudeCount: model.claudeAccounts.count
        )
    }

    private var shouldShowClaudeSection: Bool {
        shouldShowClaudeRow || !storedClaudeAccounts.isEmpty
    }

    private var providerFilter: AccountsSidebarFilter {
        AccountsSidebarFilter(rawValue: providerFilterRaw) ?? .all
    }

    private var providerFilterBinding: Binding<AccountsSidebarFilter> {
        Binding(
            get: { providerFilter },
            set: { providerFilterRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProviderFilterPicker(selection: providerFilterBinding)
                .padding(.bottom, 2)

            if providerFilter.includesCodex {
                codexSection
            }

            if providerFilter.includesCodex, providerFilter.includesClaude, shouldShowClaudeSection {
                MinimalSeparator()
                    .opacity(0.38)
                    .padding(.horizontal, 2)
            }

            if providerFilter.includesClaude, shouldShowClaudeSection {
                claudeSection
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

    private var codexSection: some View {
        TrayProviderSection(
            title: "Codex CLI",
            countText: categoryCountText(codexAccountCount),
            accent: ProviderAccent.codex,
            isExpanded: $codexExpanded
        ) {
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
                    style: .current,
                    action: nil
                )

                ForEach(storedCodexAccounts) { account in
                    TrayAccountRow(
                        symbolName: "terminal",
                        title: account.label,
                        subtitle: storedCodexSubtitle(for: account),
                        compactRows: compactRows(from: model.rateLimitSections(for: account)),
                        detailText: storedCodexDetail(for: account),
                        metaText: nil,
                        accent: statusColor(for: account.status, isCurrent: false, providerAccent: ProviderAccent.codex),
                        badgeText: nil,
                        badgeColor: .secondary,
                        interactive: true,
                        style: .stored
                    ) {
                        Task { await model.activateAccount(account) }
                    }
                    .disabled(model.isBusy)
                }
            }
        }
    }

    private var claudeSection: some View {
        TrayProviderSection(
            title: "Claude Code",
            countText: categoryCountText(claudeAccountCount),
            accent: ProviderAccent.claude,
            isExpanded: $claudeExpanded
        ) {
            VStack(alignment: .leading, spacing: 8) {
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
                        style: .current,
                        action: nil
                    )
                }

                ForEach(storedClaudeAccounts) { account in
                    TrayAccountRow(
                        symbolName: "text.bubble",
                        title: account.label,
                        subtitle: storedClaudeSubtitle(for: account),
                        compactRows: [],
                        detailText: account.shortStatusText,
                        metaText: nil,
                        accent: statusColor(for: account.status, isCurrent: false, providerAccent: ProviderAccent.claude),
                        badgeText: nil,
                        badgeColor: .secondary,
                        interactive: true,
                        style: .stored
                    ) {
                        Task { await model.activateClaudeAccount(account) }
                    }
                    .disabled(model.isBusy)
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            if model.shouldOfferAddAccountAsPrimaryAction() {
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
                    Button("Обновить значения") {
                        Task { await model.validateAll() }
                    }
                }

                Divider()

                Button("Показать всё") {
                    codexExpanded = true
                    claudeExpanded = true
                }

                Button("Свернуть всё") {
                    codexExpanded = false
                    claudeExpanded = false
                }

                Divider()

                Button("Выход") {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
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
                    .controlSize(.regular)
            } else {
                Button(title, action: action)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.roundedRectangle(radius: 14))
                    .controlSize(.regular)
            }
        } else {
            if primary {
                Button(title, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            } else {
                Button(title, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }
        }
    }

    private func compactRows(from sections: [RateLimitDisplaySection]) -> [RateLimitDisplayRow] {
        Array((sections.first?.rows ?? []).prefix(2))
    }

    private func categoryCountText(_ count: Int) -> String {
        switch count {
        case 1:
            return "1 аккаунт"
        case 2...4:
            return "\(count) аккаунта"
        default:
            return "\(count) аккаунтов"
        }
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
            return ProviderAccent.codex
        case .missing:
            return .secondary
        case .unreadable:
            return .red
        }
    }

    private var claudeAccent: Color {
        switch model.currentClaudeState.source {
        case .stored, .external:
            return ProviderAccent.claude
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

}

private struct TrayProviderSection<Content: View>: View {
    let title: String
    let countText: String
    let accent: Color
    @Binding var isExpanded: Bool
    let content: Content

    init(
        title: String,
        countText: String,
        accent: Color,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.countText = countText
        self.accent = accent
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(accent.opacity(0.72))
                        .frame(width: 6, height: 6)

                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.4)

                    Spacer(minLength: 8)

                    Text(countText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum TrayAccountRowStyle {
    case current
    case stored

    var cornerRadius: CGFloat {
        switch self {
        case .current: 18
        case .stored: 16
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .current: 12
        case .stored: 10
        }
    }

    var titleWeight: Font.Weight {
        switch self {
        case .current: .semibold
        case .stored: .medium
        }
    }

    var fillOpacity: Double {
        switch self {
        case .current: 0.075
        case .stored: 0.038
        }
    }

    var strokeOpacity: Double {
        switch self {
        case .current: 0.075
        case .stored: 0.030
        }
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
    let style: TrayAccountRowStyle
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
        VStack(alignment: .leading, spacing: style == .current ? 8 : 7) {
            HStack(spacing: 10) {
                Image(systemName: symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent.opacity(style == .current ? 0.95 : 0.80))
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(style.titleWeight))
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
                        .foregroundStyle(badgeColor.opacity(0.88))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(badgeColor.opacity(0.095), in: Capsule())
                }
            }

            if !compactRows.isEmpty {
                CompactLimitBarsView(rows: compactRows, dense: true, tint: accent)
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
        .padding(.vertical, style.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundChrome)
        .contentShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var backgroundChrome: some View {
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)

        Color.white.opacity(style.fillOpacity)
            .overlay {
                shape.stroke(.primary.opacity(style.strokeOpacity), lineWidth: 1)
            }
    }
}
