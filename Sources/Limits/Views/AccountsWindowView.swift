import AppKit
import SwiftUI
import LimitsCore
import LimitsShared

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
        model.providerCatalog.normalized(AccountsSidebarFilter(rawValue: sidebarFilterRaw) ?? .all)
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
        model.providerCatalog.contains(.claude)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge: .top, spacing: 0) {
            operationBanners
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await model.addAccount() }
                } label: {
                    Image(systemName: "plus")
                }
                .help(L10n.tr("action.add_account"))
                .disabled(model.isProviderBusy(.codex))

                if model.hasCurrentCLIAuthToImport() {
                    Button {
                        Task { await model.importCurrentCLIAuth() }
                    } label: {
                        Image(systemName: "arrow.down.doc")
                    }
                    .help(L10n.tr("action.import_current_auth"))
                    .disabled(model.isProviderBusy(.codex))
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
        .task {
            await model.refreshForPresentation()
        }
        .onAppear {
            sidebarFilterRaw = sidebarFilter.rawValue
            ensureValidSelection()
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
        .onChange(of: model.providerCatalog) { _, _ in
            let normalized = model.providerCatalog.normalized(sidebarFilter)
            sidebarFilterRaw = normalized.rawValue
            ensureValidSelection(for: normalized)
        }
        .onChange(of: sidebarFilterRaw) { _, _ in
            ensureValidSelection()
        }
        .confirmationDialog(
            L10n.tr("delete.confirm.title", model.pendingCredentialDeletion?.accountName ?? ""),
            isPresented: Binding(
                get: { model.pendingCredentialDeletion != nil },
                set: { if !$0 { model.cancelCredentialDeletion() } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.tr("action.delete"), role: .destructive) {
                Task { await model.confirmCredentialDeletion() }
            }
            Button(L10n.tr("action.cancel"), role: .cancel) {
                model.cancelCredentialDeletion()
            }
        } message: {
            Text(L10n.tr("delete.confirm.message"))
        }
    }

    private var operationBanners: some View {
        VStack(spacing: 0) {
            ForEach(model.providerCatalog.providers, id: \.self) { provider in
                let state = model.providerOperationState(provider)
                if state.phase == .running || state.notice != nil || state.error != nil {
                    ProviderOperationBanner(
                        provider: provider,
                        state: state,
                        cancel: { model.cancelOperation(for: provider) }
                    )
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ProviderFilterPicker(selection: sidebarFilterBinding, catalog: model.providerCatalog)
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
                        ForEach(model.sortedCodexAccountsForSidebar()) { account in
                            SidebarRowView(
                                icon: sidebarIcon(for: account),
                                title: account.label,
                                subtitle: sidebarSubtitle(for: account),
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
                                    model.requestDeleteAccount(account)
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
                                    model.requestDeleteClaudeAccount(account)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollIndicators(.hidden)
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
        .scrollIndicators(.hidden)
        .background(Color.clear)
    }

    private var currentCLITrailingText: String? {
        model.currentCLIDisplaySidebarLimitSummary()?.compactLimitText()
    }

    private var currentClaudeTrailingText: String? {
        model.currentClaudeLiveRateLimitSections()
            .first?
            .rows
            .first
            .map { "\(max(0, 100 - $0.usedPercent))%" }
    }

    private func sidebarTrailing(for account: StoredAccount) -> String? {
        model.sidebarLimitSummary(for: account)?.compactLimitText()
    }

    private func sidebarSubtitle(for account: StoredAccount) -> String? {
        model.sidebarLimitSummary(for: account)?.compactResetText()
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

        guard AccountsPresentationLogic.isVisible(destination: destination, filter: activeFilter, catalog: model.providerCatalog) else {
            sidebarSelectionRaw = sidebarSelection(
                for: AccountsPresentationLogic.defaultDestination(for: activeFilter, catalog: model.providerCatalog)
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

private struct ProviderOperationBanner: View {
    let provider: ProviderKind
    let state: ProviderOperationState
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if state.phase == .running {
                ProgressView().controlSize(.small)
            }
            Text(provider == .codex ? "Codex" : "Claude")
                .font(.caption.weight(.semibold))
            Text(state.progress ?? state.notice ?? state.error ?? "")
                .font(.caption)
                .foregroundStyle(state.error == nil ? Color.secondary : Color.red)
                .lineLimit(2)
            Spacer(minLength: 8)
            if state.canCancel {
                Button(L10n.tr("action.cancel"), action: cancel)
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
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
        model.currentCLIDisplayRateLimitSections()
    }

    private var probeWarningText: String? {
        guard let warning = model.currentCLIProbeWarningText() else {
            return nil
        }

        return warning == overview.note ? nil : warning
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
                        .disabled(model.isProviderBusy(.codex))
                    } else if model.shouldOfferAddAccountAsPrimaryAction() {
                        Button(L10n.tr("action.add_account")) {
                            Task { await model.addAccount() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isProviderBusy(.codex))
                    }

                    Button(L10n.tr("action.refresh_values")) {
                        Task { await model.refreshCurrentValues(forceProbe: true) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isProviderBusy(.codex))
                }
            )

            if let errorMessage = model.providerErrorMessage(.codex) ?? model.errorMessage {
                MinimalSeparator()
                InlineWarningCard(text: errorMessage)
            }

            if let probeWarningText {
                MinimalSeparator()
                InlineWarningCard(text: probeWarningText)
            }

            if sections.isEmpty {
                MinimalSeparator()
                EmptyLimitsCard(
                    title: L10n.tr("limits.empty.title"),
                    subtitle: model.currentLastKnownRateLimitSummary()
                        ?? overview.note
                        ?? L10n.tr("limits.empty.subtitle")
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
        var parts: [String] = []
        if let plan = model.currentChatGPTPlanSummary() {
            parts.append(plan)
        }
        if let period = model.currentChatGPTSubscriptionPeriodText(now: model.presentationNow) {
            parts.append(period)
        }
        if let date = model.currentCLILimitsObservedAt() {
            parts.append(L10n.updatedAt(formatted(date: date)))
        } else if model.isRefreshingCurrentCLIProbe {
            parts.append(L10n.tr("busy.refreshing_live_limits"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private func formatted(date: Date) -> String {
        L10n.localizedDateTime(date)
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
                        .disabled(model.isProviderBusy(.claude))
                    }

                    if model.currentClaudeStatus?.loggedIn == true {
                        Button(L10n.tr("action.refresh")) {
                            Task { await model.refreshCurrentClaudeAccount() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isProviderBusy(.claude))
                    }

                    if model.claudeLiveBridgeInstalled() {
                        Button(L10n.tr("action.disconnect_bridge")) {
                            Task { await model.uninstallClaudeLiveLimitsBridge() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isProviderBusy(.claude))
                    } else if model.currentClaudeStatus?.loggedIn == true {
                        Button(L10n.tr("action.connect_live_limits")) {
                            Task { await model.installClaudeLiveLimitsBridge() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isProviderBusy(.claude))
                    }
                }
            )

            MinimalSeparator()

            if let providerError = model.providerErrorMessage(.claude),
               providerError != model.currentClaudeBridgeError {
                InlineWarningCard(text: providerError)
                MinimalSeparator()
            }

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
        L10n.localizedDateTime(date)
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
                stateBadge: AnyView(AccountStatusBadge(status: account.status, isCurrent: isCurrent, provider: .claude)),
                note: accountNote,
                metaLine: accountMetaLine,
                actions: {
                    if !isCurrent {
                        Button(L10n.tr("action.make_current")) {
                            Task { await model.activateClaudeAccount(account) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isProviderBusy(.claude))
                    } else {
                        Button(L10n.tr("action.refresh")) {
                            Task { await model.refreshCurrentClaudeAccount() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isProviderBusy(.claude))

                        if model.claudeLiveBridgeInstalled() {
                            Button(L10n.tr("action.disconnect_bridge")) {
                                Task { await model.uninstallClaudeLiveLimitsBridge() }
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isProviderBusy(.claude))
                        } else if model.currentClaudeStatus?.loggedIn == true {
                            Button(L10n.tr("action.connect_live_limits")) {
                                Task { await model.installClaudeLiveLimitsBridge() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isProviderBusy(.claude))
                        }
                    }

                    Button(L10n.tr("action.delete"), role: .destructive) {
                        model.requestDeleteClaudeAccount(account)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isProviderBusy(.claude))
                }
            )

            MinimalSeparator()

            if let providerError = model.providerErrorMessage(.claude),
               providerError != model.currentClaudeBridgeError {
                InlineWarningCard(text: providerError)
                MinimalSeparator()
            }

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
        L10n.localizedDateTime(date)
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
                        .disabled(model.isProviderBusy(.codex))
                    }

                    Button(L10n.tr("action.refresh")) {
                        Task { await model.validateAccount(account) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isProviderBusy(.codex))

                    Button(L10n.tr("action.reauthenticate")) {
                        Task { await model.reauthenticateAccount(account) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isProviderBusy(.codex))

                    Button(L10n.tr("action.delete"), role: .destructive) {
                        model.requestDeleteAccount(account)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isProviderBusy(.codex))
                }
            )

            if sections.isEmpty {
                MinimalSeparator()
                EmptyLimitsCard(
                    title: L10n.tr("limits.empty.title"),
                    subtitle: model.storedRateLimitSummary(for: account)
                        ?? accountNote
                        ?? L10n.tr("limits.empty.account.subtitle")
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

        parts.append(model.chatGPTPlanSummary(for: account))

        if let period = model.chatGPTSubscriptionPeriodText(for: account, now: model.presentationNow) {
            parts.append(period)
        }

        if let date = account.lastValidatedAt {
            parts.append(L10n.checkedAt(L10n.localizedDateTime(date)))
        }

        return parts.isEmpty ? nil : parts.joined(separator: "\n")
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
                    .fixedSize(horizontal: false, vertical: true)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedProgress: Double?

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(0, geometry.size.width - 4)
            let progress = visibleProgress
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
        .onAppear {
            updateDisplayedProgress(progress, animated: !reduceMotion)
        }
        .onChange(of: progress) { _, newProgress in
            updateDisplayedProgress(newProgress, animated: !reduceMotion)
        }
    }

    private var visibleProgress: Double {
        displayedProgress ?? (reduceMotion ? clampedProgress(progress) : 0)
    }

    private func updateDisplayedProgress(_ progress: Double, animated: Bool) {
        let progress = clampedProgress(progress)
        guard animated else {
            displayedProgress = progress
            return
        }

        if displayedProgress == nil {
            displayedProgress = 0
        }

        withAnimation(.easeOut(duration: 0.14)) {
            displayedProgress = progress
        }
    }

    private func clampedProgress(_ progress: Double) -> Double {
        min(max(progress, 0), 1)
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
        Text(presentation.text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(presentation.tone.color.opacity(0.16), in: Capsule())
            .foregroundStyle(presentation.tone.color)
    }

    private var presentation: ProviderBadgePresentation {
        ProviderPresentation.claudeBadge(source: model.currentClaudeState.source)
    }
}

private struct AccountStatusBadge: View {
    let status: AccountStatus
    let isCurrent: Bool
    var provider: TrayStatusProvider = .codex

    var body: some View {
        Text(presentation.text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(presentation.tone.color.opacity(0.16), in: Capsule())
            .foregroundStyle(presentation.tone.color)
    }

    private var presentation: ProviderBadgePresentation {
        ProviderPresentation.accountBadge(
            status: status,
            isCurrent: isCurrent,
            provider: provider
        )
    }
}
