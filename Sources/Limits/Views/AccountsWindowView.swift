import AppKit
import SwiftUI

private enum AccountsSidebarSelection: Hashable {
    case currentCodexCLI
    case codexAccount(UUID)
    case currentClaudeCode
    case claudeAccount(UUID)

    var rawValue: String {
        switch self {
        case .currentCodexCLI:
            return "current-cli"
        case .codexAccount(let id):
            return "account:\(id.uuidString)"
        case .currentClaudeCode:
            return "current-claude"
        case .claudeAccount(let id):
            return "claude-account:\(id.uuidString)"
        }
    }

    init?(rawValue: String) {
        if rawValue == "current-cli" {
            self = .currentCodexCLI
            return
        }

        if rawValue == "current-claude" {
            self = .currentClaudeCode
            return
        }

        if rawValue.hasPrefix("account:") {
            let value = String(rawValue.dropFirst("account:".count))
            guard let id = UUID(uuidString: value) else {
                return nil
            }
            self = .codexAccount(id)
            return
        }

        guard rawValue.hasPrefix("claude-account:") else {
            return nil
        }

        let value = String(rawValue.dropFirst("claude-account:".count))
        guard let id = UUID(uuidString: value) else {
            return nil
        }
        self = .claudeAccount(id)
    }
}

struct AccountsWindowView: View {
    @ObservedObject var model: AppModel
    @AppStorage("limits.accounts.selection") private var sidebarSelectionRaw = AccountsSidebarSelection.currentCodexCLI.rawValue
    @AppStorage(AccountsSidebarFilter.providerFilterStorageKey) private var sidebarFilterRaw = AccountsSidebarFilter.all.rawValue

    private var overview: AppModel.CurrentCLIOverview {
        model.currentCLIOverview()
    }

    private var sidebarFilter: AccountsSidebarFilter {
        AccountsSidebarFilter(rawValue: sidebarFilterRaw) ?? .all
    }

    private var selectionBinding: Binding<AccountsSidebarSelection?> {
        Binding(
            get: { AccountsSidebarSelection(rawValue: sidebarSelectionRaw) ?? .currentCodexCLI },
            set: { sidebarSelectionRaw = ($0 ?? .currentCodexCLI).rawValue }
        )
    }

    private var sidebarFilterBinding: Binding<AccountsSidebarFilter> {
        Binding(
            get: { sidebarFilter },
            set: { filter in
                sidebarFilterRaw = filter.rawValue
                ensureValidSelection(for: filter)
            }
        )
    }

    private var selectedCodexAccount: StoredAccount? {
        guard case .codexAccount(let id) = detailDestination else {
            return nil
        }
        return model.accounts.first(where: { $0.id == id })
    }

    private var selectedClaudeAccount: ClaudeStoredAccount? {
        guard case .claudeAccount(let id) = detailDestination else {
            return nil
        }
        return model.claudeAccounts.first(where: { $0.id == id })
    }

    private var detailDestination: AccountsDetailDestination {
        AccountsPresentationLogic.detailDestination(
            selectionRaw: sidebarSelectionRaw,
            codexAccountIDs: Set(model.accounts.map(\.id)),
            claudeAccountIDs: Set(model.claudeAccounts.map(\.id))
        )
    }

    private var shouldShowCurrentClaudeSidebarRow: Bool {
        AccountsPresentationLogic.shouldShowCurrentClaude(
            source: model.currentClaudeState.source,
            storedClaudeCount: model.claudeAccounts.count
        )
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.addAccount() }
                } label: {
                    Image(systemName: "plus")
                }
                .help(L10n.tr("action.add_account"))
                .disabled(model.isBusy)

                if model.hasCurrentCLIAuthToImport() {
                    Button {
                        Task { await model.importCurrentCLIAuth() }
                    } label: {
                        Image(systemName: "arrow.down.doc")
                    }
                    .help(L10n.tr("action.import_current_auth"))
                    .disabled(model.isBusy)
                }

                Button {
                    Task { await model.refreshCurrentValues() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(L10n.tr("action.refresh_current_values"))
                .disabled(model.isBusy)
            }
        }
        .background(WindowChromeConfigurator())
        .frame(minWidth: 980, minHeight: 620)
        .onAppear {
            ensureValidSelection()
            Task {
                await model.refreshCurrentCLIPanel(forceProbe: false)
                await model.refreshCurrentClaudeState()
            }
        }
        .onChange(of: model.accounts) { _, _ in
            ensureValidSelection()
        }
        .onChange(of: model.claudeAccounts) { _, _ in
            ensureValidSelection()
        }
        .onChange(of: model.currentClaudeState.source) { _, _ in
            ensureValidSelection()
        }
        .onChange(of: sidebarFilterRaw) { _, _ in
            ensureValidSelection()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ProviderFilterPicker(selection: sidebarFilterBinding)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            List(selection: selectionBinding) {
                Section {
                    if sidebarFilter.includesCodex {
                        SidebarRowView(
                            icon: "person.crop.circle.fill.badge.checkmark",
                            title: "Codex CLI",
                            subtitle: overview.title,
                            trailing: currentCLITrailingText,
                            accent: ProviderAccent.codex
                        )
                        .tag(AccountsSidebarSelection.currentCodexCLI)
                    }

                    if sidebarFilter.includesClaude, shouldShowCurrentClaudeSidebarRow {
                        SidebarRowView(
                            icon: "person.crop.circle.fill.badge.checkmark",
                            title: "Claude Code",
                            subtitle: model.currentClaudeOverview().title,
                            trailing: currentClaudeTrailingText,
                            accent: ProviderAccent.claude
                        )
                        .tag(AccountsSidebarSelection.currentClaudeCode)
                    }
                }

                if sidebarFilter.includesCodex, !model.accounts.isEmpty {
                    Section(L10n.tr("accounts.codex.section")) {
                        ForEach(model.accounts) { account in
                            SidebarRowView(
                                icon: sidebarIcon(for: account),
                                title: account.label,
                                subtitle: nil,
                                trailing: sidebarTrailing(for: account),
                                accent: sidebarAccent(for: account)
                            )
                            .tag(AccountsSidebarSelection.codexAccount(account.id))
                            .contextMenu {
                                if !model.isCurrentCLIAccount(account) {
                                    Button(L10n.tr("action.make_current")) {
                                        Task { await model.activateAccount(account) }
                                    }
                                }

                                Button(L10n.tr("action.refresh_values")) {
                                    Task { await model.validateAccount(account) }
                                }

                                Button(L10n.tr("action.reauthenticate")) {
                                    Task { await model.reauthenticateAccount(account) }
                                }

                                Divider()

                                Button(L10n.tr("action.delete_account"), role: .destructive) {
                                    Task { await model.deleteAccount(account) }
                                }
                            }
                        }
                    }
                }

                if sidebarFilter.includesClaude, !model.claudeAccounts.isEmpty {
                    Section(L10n.tr("accounts.claude.section")) {
                        ForEach(model.claudeAccounts) { account in
                            SidebarRowView(
                                icon: claudeSidebarIcon(for: account),
                                title: account.label,
                                subtitle: nil,
                                trailing: claudeSidebarTrailing(for: account),
                                accent: claudeSidebarAccent(for: account)
                            )
                            .tag(AccountsSidebarSelection.claudeAccount(account.id))
                            .contextMenu {
                                if !model.isCurrentClaudeAccount(account) {
                                    Button(L10n.tr("action.make_current")) {
                                        Task { await model.activateClaudeAccount(account) }
                                    }
                                } else {
                                    Button(L10n.tr("action.refresh")) {
                                        Task { await model.refreshCurrentClaudeAccount() }
                                    }
                                }

                                Divider()

                                Button(L10n.tr("action.delete_account"), role: .destructive) {
                                    Task { await model.deleteClaudeAccount(account) }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
    }

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let selectedCodexAccount {
                    StoredAccountDetailPane(model: model, account: selectedCodexAccount)
                } else if let selectedClaudeAccount {
                    StoredClaudeDetailPane(model: model, account: selectedClaudeAccount)
                } else if detailDestination == .currentClaudeCode {
                    CurrentClaudeDetailPane(model: model)
                } else {
                    CurrentCLIDetailPane(model: model)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.clear)
    }

    private var currentCLITrailingText: String? {
        if let used = model.currentCLIProbe?.rateLimit?.primary?.usedPercent {
            return "\(max(0, 100 - used))%"
        }
        if let used = model.currentCLIReferenceAccount()?.lastRateLimit?.primary?.usedPercent {
            return "\(max(0, 100 - used))%"
        }
        return nil
    }

    private var currentClaudeTrailingText: String? {
        model.currentClaudeLiveRateLimitSections()
            .first?
            .rows
            .first
            .map { "\(max(0, 100 - $0.usedPercent))%" }
    }

    private func sidebarTrailing(for account: StoredAccount) -> String? {
        if let used = account.lastRateLimit?.primary?.usedPercent {
            return "\(max(0, 100 - used))%"
        }
        return nil
    }

    private func sidebarIcon(for account: StoredAccount) -> String {
        model.isCurrentCLIAccount(account) ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle"
    }

    private func sidebarAccent(for account: StoredAccount) -> Color {
        if model.isCurrentCLIAccount(account) {
            return ProviderAccent.codex
        }

        switch account.status {
        case .ok:
            return .secondary
        case .limitReached:
            return .orange
        case .needsReauth, .validationFailed:
            return .red
        case .unknown:
            return .secondary
        }
    }

    private func claudeSidebarTrailing(for account: ClaudeStoredAccount) -> String? {
        guard model.isCurrentClaudeAccount(account) else {
            return nil
        }

        return currentClaudeTrailingText
    }

    private func claudeSidebarIcon(for account: ClaudeStoredAccount) -> String {
        model.isCurrentClaudeAccount(account) ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle"
    }

    private func claudeSidebarAccent(for account: ClaudeStoredAccount) -> Color {
        if model.isCurrentClaudeAccount(account) {
            return ProviderAccent.claude
        }

        switch account.status {
        case .ok:
            return .secondary
        case .limitReached:
            return .orange
        case .needsReauth, .validationFailed:
            return .red
        case .unknown:
            return .secondary
        }
    }

    private func ensureValidSelection(for filter: AccountsSidebarFilter? = nil) {
        let activeFilter = filter ?? sidebarFilter
        let destination = AccountsPresentationLogic.detailDestination(
            selectionRaw: sidebarSelectionRaw,
            codexAccountIDs: Set(model.accounts.map(\.id)),
            claudeAccountIDs: Set(model.claudeAccounts.map(\.id))
        )

        guard AccountsPresentationLogic.isVisible(destination: destination, filter: activeFilter) else {
            sidebarSelectionRaw = sidebarSelection(
                for: AccountsPresentationLogic.defaultDestination(for: activeFilter)
            ).rawValue
            return
        }

        let normalizedSelection = sidebarSelection(for: destination)
        if sidebarSelectionRaw != normalizedSelection.rawValue {
            sidebarSelectionRaw = normalizedSelection.rawValue
        }
    }

    private func sidebarSelection(for destination: AccountsDetailDestination) -> AccountsSidebarSelection {
        switch destination {
        case .currentCodexCLI:
            return .currentCodexCLI
        case .currentClaudeCode:
            return .currentClaudeCode
        case .codexAccount(let id):
            return .codexAccount(id)
        case .claudeAccount(let id):
            return .claudeAccount(id)
        }
    }
}

private struct SidebarRowView: View {
    let icon: String
    let title: String
    let subtitle: String?
    let trailing: String?
    let accent: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(accent)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }
}

private struct CurrentCLIDetailPane: View {
    @ObservedObject var model: AppModel

    private var overview: AppModel.CurrentCLIOverview {
        model.currentCLIOverview()
    }

    private var sections: [RateLimitDisplaySection] {
        model.currentCLIRateLimitSections()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DetailHeroCard(
                title: overview.title,
                subtitle: overview.subtitle,
                stateBadge: AnyView(CLIStateBadge(source: model.currentCLIState.source)),
                note: overview.note,
                metaLine: currentCLIMetaLine,
                actions: {
                    if model.hasCurrentCLIAuthToImport() {
                        Button(L10n.tr("action.import_current_auth")) {
                            Task { await model.importCurrentCLIAuth() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)
                    } else if model.shouldOfferAddAccountAsPrimaryAction() {
                        Button(L10n.tr("action.add_account")) {
                            Task { await model.addAccount() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)
                    }

                    Button(L10n.tr("action.refresh_values")) {
                        Task { await model.refreshCurrentCLIPanel(forceProbe: true) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
                }
            )

            if let errorMessage = model.errorMessage {
                MinimalSeparator()
                InlineWarningCard(text: errorMessage)
            }

            if let probeError = model.currentCLIProbeError {
                MinimalSeparator()
                InlineWarningCard(text: probeError)
            }

            if sections.isEmpty {
                MinimalSeparator()
                EmptyLimitsCard(
                    title: L10n.tr("limits.empty.title"),
                    subtitle: overview.note ?? L10n.tr("limits.empty.subtitle")
                )
            } else {
                MinimalSeparator()
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    LimitSectionCard(section: section, tint: ProviderAccent.codex)

                    if index < sections.count - 1 {
                        MinimalSeparator()
                    }
                }
            }
        }
    }

    private var currentCLIMetaLine: String? {
        if let date = model.currentCLIValidatedAt() {
            return L10n.updatedAt(formatted(date: date))
        }
        if model.isRefreshingCurrentCLIProbe {
            return L10n.tr("busy.refreshing_live_limits")
        }
        return nil
    }

    private func formatted(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct CurrentClaudeDetailPane: View {
    @ObservedObject var model: AppModel

    private var overview: AppModel.CurrentClaudeOverview {
        model.currentClaudeOverview()
    }

    private var liveSections: [RateLimitDisplaySection] {
        model.currentClaudeLiveRateLimitSections()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DetailHeroCard(
                title: overview.title,
                subtitle: overview.subtitle,
                stateBadge: AnyView(ClaudeStateBadge(model: model)),
                note: overview.note,
                metaLine: metaLine,
                actions: {
                    if model.hasCurrentClaudeAuthToImport() {
                        Button(L10n.tr("action.save_account")) {
                            Task { await model.importCurrentClaudeAuth() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)
                    }

                    if model.currentClaudeStatus?.loggedIn == true {
                        Button(L10n.tr("action.refresh")) {
                            Task { await model.refreshCurrentClaudeAccount() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy)
                    }

                    if model.claudeLiveBridgeInstalled() {
                        Button(L10n.tr("action.disconnect_bridge")) {
                            Task { await model.uninstallClaudeLiveLimitsBridge() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy)
                    } else if model.currentClaudeStatus?.loggedIn == true {
                        Button(L10n.tr("action.connect_live_limits")) {
                            Task { await model.installClaudeLiveLimitsBridge() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)
                    }
                }
            )

            MinimalSeparator()

            if let bridgeError = model.currentClaudeBridgeError {
                InlineWarningCard(text: bridgeError)
                MinimalSeparator()
            }

            if liveSections.isEmpty {
                EmptyLimitsCard(
                    title: bridgeCardTitle,
                    subtitle: bridgeCardSubtitle
                )
            } else {
                ForEach(Array(liveSections.enumerated()), id: \.element.id) { index, section in
                    LimitSectionCard(section: section, tint: ProviderAccent.claude)

                    if index < liveSections.count - 1 {
                        MinimalSeparator()
                    }
                }
            }
        }
    }

    private var metaLine: String? {
        var parts: [String] = []

        if let status = model.currentClaudeStatus {
            if let authMethod = status.authMethod {
                parts.append(authMethod)
            }
            if let orgName = status.orgName, !orgName.isEmpty {
                parts.append(orgName)
            }
        }

        if let date = model.claudeValidatedAt() {
            parts.append(L10n.checkedAt(formatted(date: date)))
        }

        if let date = model.claudeLiveBridgeSnapshotUpdatedAt() {
            parts.append(L10n.limitsAt(formatted(date: date)))
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var bridgeCardTitle: String {
        if !model.claudeLiveBridgeInstalled() {
            return L10n.tr("claude.live_off")
        }

        if !model.currentClaudeLiveBridgeStatus.hasSnapshot {
            return L10n.tr("claude.bridge_connected")
        }

        return L10n.tr("claude.no_limits_yet")
    }

    private var bridgeCardSubtitle: String {
        if !model.claudeLiveBridgeInstalled() {
            return L10n.tr("claude.connect_bridge.long")
        }

        if !model.currentClaudeLiveBridgeStatus.hasSnapshot {
            return L10n.tr("claude.wait_for_session.long")
        }

        if model.currentClaudeStatus?.authMethod?.lowercased() == "claude.ai" {
            return L10n.tr("claude.snapshot_empty.long")
        }

        return L10n.tr("claude.no_official_limits.long")
    }

    private func formatted(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct StoredClaudeDetailPane: View {
    @ObservedObject var model: AppModel
    let account: ClaudeStoredAccount

    private var isCurrent: Bool {
        model.isCurrentClaudeAccount(account)
    }

    private var liveSections: [RateLimitDisplaySection] {
        guard isCurrent else { return [] }
        return model.currentClaudeLiveRateLimitSections()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DetailHeroCard(
                title: account.label,
                subtitle: account.email,
                stateBadge: AnyView(AccountStatusBadge(status: account.status, isCurrent: isCurrent, currentAccent: ProviderAccent.claude)),
                note: accountNote,
                metaLine: accountMetaLine,
                actions: {
                    if !isCurrent {
                        Button(L10n.tr("action.make_current")) {
                            Task { await model.activateClaudeAccount(account) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)
                    } else {
                        Button(L10n.tr("action.refresh")) {
                            Task { await model.refreshCurrentClaudeAccount() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy)

                        if model.claudeLiveBridgeInstalled() {
                            Button(L10n.tr("action.disconnect_bridge")) {
                                Task { await model.uninstallClaudeLiveLimitsBridge() }
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isBusy)
                        } else if model.currentClaudeStatus?.loggedIn == true {
                            Button(L10n.tr("action.connect_live_limits")) {
                                Task { await model.installClaudeLiveLimitsBridge() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isBusy)
                        }
                    }

                    Button(L10n.tr("action.delete"), role: .destructive) {
                        Task { await model.deleteClaudeAccount(account) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
                }
            )

            MinimalSeparator()

            if isCurrent, let bridgeError = model.currentClaudeBridgeError {
                InlineWarningCard(text: bridgeError)
                MinimalSeparator()
            }

            if liveSections.isEmpty {
                EmptyLimitsCard(
                    title: emptyStateTitle,
                    subtitle: emptyStateSubtitle
                )
            } else {
                ForEach(Array(liveSections.enumerated()), id: \.element.id) { index, section in
                    LimitSectionCard(section: section, tint: ProviderAccent.claude)

                    if index < liveSections.count - 1 {
                        MinimalSeparator()
                    }
                }
            }
        }
    }

    private var accountNote: String? {
        if isCurrent {
            return model.currentClaudeOverview().note
        }
        return account.statusMessage ?? L10n.tr("claude.live_current_only")
    }

    private var accountMetaLine: String? {
        var parts: [String] = []

        if isCurrent {
            parts.append(L10n.tr("claude.current"))

            if let status = model.currentClaudeStatus {
                if let authMethod = status.authMethod {
                    parts.append(authMethod)
                }
                if let orgName = status.orgName, !orgName.isEmpty {
                    parts.append(orgName)
                }
            }
        }

        let plan = model.localizedClaudePlan(account.subscriptionType)
        if plan != L10n.tr("plan.claude.subscription") {
            parts.append(plan)
        }

        if let date = model.claudeValidatedAt(for: account) {
            parts.append(L10n.checkedAt(formatted(date: date)))
        }

        if isCurrent, let date = model.claudeLiveBridgeSnapshotUpdatedAt() {
            parts.append(L10n.limitsAt(formatted(date: date)))
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var emptyStateTitle: String {
        if !isCurrent {
            return L10n.tr("claude.live_available_current")
        }

        if !model.claudeLiveBridgeInstalled() {
            return L10n.tr("claude.live_off")
        }

        if !model.currentClaudeLiveBridgeStatus.hasSnapshot {
            return L10n.tr("claude.bridge_connected")
        }

        return L10n.tr("claude.no_limits_yet")
    }

    private var emptyStateSubtitle: String {
        if !isCurrent {
            return L10n.tr("claude.make_current_for_snapshot")
        }

        if !model.claudeLiveBridgeInstalled() {
            return L10n.tr("claude.connect_bridge.short")
        }

        if !model.currentClaudeLiveBridgeStatus.hasSnapshot {
            return L10n.tr("claude.wait_for_session.short")
        }

        if model.currentClaudeStatus?.authMethod?.lowercased() == "claude.ai" {
            return L10n.tr("claude.snapshot_empty.short")
        }

        return L10n.tr("claude.no_official_limits.short")
    }

    private func formatted(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct StoredAccountDetailPane: View {
    @ObservedObject var model: AppModel
    let account: StoredAccount

    private var sections: [RateLimitDisplaySection] {
        model.rateLimitSections(for: account)
    }

    private var isCurrent: Bool {
        model.isCurrentCLIAccount(account)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DetailHeroCard(
                title: account.label,
                subtitle: account.email,
                stateBadge: AnyView(AccountStatusBadge(status: account.status, isCurrent: isCurrent)),
                note: accountNote,
                metaLine: accountMetaLine,
                actions: {
                    if !isCurrent {
                        Button(L10n.tr("action.make_current")) {
                            Task { await model.activateAccount(account) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)
                    }

                    Button(L10n.tr("action.refresh")) {
                        Task { await model.validateAccount(account) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)

                    Button(L10n.tr("action.reauthenticate")) {
                        Task { await model.reauthenticateAccount(account) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)

                    Button(L10n.tr("action.delete"), role: .destructive) {
                        Task { await model.deleteAccount(account) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
                }
            )

            if sections.isEmpty {
                MinimalSeparator()
                EmptyLimitsCard(
                    title: L10n.tr("limits.empty.title"),
                    subtitle: L10n.tr("limits.empty.account.subtitle")
                )
            } else {
                MinimalSeparator()
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    LimitSectionCard(section: section, tint: ProviderAccent.codex)

                    if index < sections.count - 1 {
                        MinimalSeparator()
                    }
                }
            }
        }
    }

    private var accountNote: String? {
        if isCurrent, model.currentCLIProbe != nil {
            return L10n.tr("cli.live_limits_loaded")
        }
        return account.statusMessage
    }

    private var accountMetaLine: String? {
        var parts: [String] = []

        if isCurrent {
            parts.append(L10n.tr("account.current") + " CLI")
        }

        parts.append(model.localizedPlan(account.planType))

        if let date = account.lastValidatedAt {
            let formatter = DateFormatter()
            formatter.locale = L10n.locale
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            parts.append(L10n.checkedAt(formatter.string(from: date)))
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct DetailHeroCard<Actions: View>: View {
    let title: String
    let subtitle: String?
    let stateBadge: AnyView
    let note: String?
    let metaLine: String?
    let actions: Actions

    init(
        title: String,
        subtitle: String?,
        stateBadge: AnyView,
        note: String?,
        metaLine: String?,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.stateBadge = stateBadge
        self.note = note
        self.metaLine = metaLine
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.largeTitle.weight(.semibold))
                        .lineLimit(2)

                    if let subtitle {
                        Text(subtitle)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 12)
                stateBadge
            }

            if let metaLine {
                Text(metaLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                actions
            }
        }
    }
}

private struct LimitSectionCard: View {
    let section: RateLimitDisplaySection
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(section.title)
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 14) {
                ForEach(section.rows) { row in
                    LimitProgressRowView(row: row, tint: tint)
                }
            }
        }
    }
}

private struct LimitProgressRowView: View {
    let row: RateLimitDisplayRow
    let tint: Color

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow(alignment: .center) {
                Text(row.title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(width: 160, alignment: .leading)

                LimitProgressBar(progress: row.remainingProgressValue, tint: resolvedTint)
                    .frame(maxWidth: .infinity)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(L10n.percentRemaining(row.remainingPercent))
                        .font(.headline)
                        .monospacedDigit()

                    if let resetText = row.resetText {
                        Text(resetText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 190, alignment: .trailing)
            }
        }
    }

    private var resolvedTint: Color {
        row.remainingPercent <= 9 ? .red : tint
    }
}

private struct LimitProgressBar: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(0, geometry.size.width - 4)
            let fillWidth = progress == 0 ? 0 : max(10, availableWidth * progress)

            ZStack(alignment: .leading) {
                MinimalProgressTrack(fillOpacity: 0.075, strokeOpacity: 0.18)

                Capsule()
                    .fill(tint.gradient)
                    .padding(2)
                    .frame(width: fillWidth)
            }
        }
        .frame(height: 12)
    }
}

private struct EmptyLimitsCard: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
    }
}

private struct InlineWarningCard: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.red)
            .padding(.vertical, 2)
    }
}

private struct ClaudeStateBadge: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch model.currentClaudeState.source {
        case .stored:
            return L10n.tr("account.current")
        case .external:
            return L10n.tr("account.external")
        case .loggedOut:
            return L10n.tr("account.no_login")
        case .notInstalled:
            return L10n.tr("account.not_installed")
        case .unreadable:
            return L10n.tr("account.error")
        }
    }

    private var color: Color {
        switch model.currentClaudeState.source {
        case .stored:
            return ProviderAccent.claude
        case .external:
            return ProviderAccent.claude
        case .loggedOut, .unreadable:
            return .red
        case .notInstalled:
            return .secondary
        }
    }
}

private struct AccountStatusBadge: View {
    let status: AccountStatus
    let isCurrent: Bool
    var currentAccent: Color = ProviderAccent.codex

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        if isCurrent {
            return L10n.tr("account.current")
        }
        return switch status {
        case .ok: L10n.tr("account.ready")
        case .limitReached: L10n.tr("account.limit")
        case .needsReauth: L10n.tr("account.needs_login")
        case .validationFailed: L10n.tr("account.error")
        case .unknown: L10n.tr("account.unknown")
        }
    }

    private var color: Color {
        if isCurrent {
            return currentAccent
        }
        return switch status {
        case .ok: .green
        case .limitReached: .orange
        case .needsReauth, .validationFailed: .red
        case .unknown: .secondary
        }
    }
}
