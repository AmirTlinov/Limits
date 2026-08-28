import AppKit
import Charts
import SwiftUI
import LimitsCore
import LimitsShared

private enum AccountsSidebarSelection: Hashable {
    case codexOverview
    case codexAccount(UUID)
    case currentClaudeCode
    case claudeAccount(UUID)

    var rawValue: String {
        switch self {
        case .codexOverview:
            return "codex-overview"
        case .codexAccount(let id):
            return "account:\(id.uuidString)"
        case .currentClaudeCode:
            return "current-claude"
        case .claudeAccount(let id):
            return "claude-account:\(id.uuidString)"
        }
    }

    init?(rawValue: String) {
        if rawValue == "codex-overview" {
            self = .codexOverview
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
    @AppStorage("limits.accounts.selection") private var sidebarSelectionRaw = AccountsSidebarSelection.codexOverview.rawValue
    @AppStorage(AccountsSidebarFilter.providerFilterStorageKey) private var sidebarFilterRaw = AccountsSidebarFilter.all.rawValue

    private var sidebarFilter: AccountsSidebarFilter {
        model.providerCatalog.normalized(AccountsSidebarFilter(rawValue: sidebarFilterRaw) ?? .all)
    }

    private var selectionBinding: Binding<AccountsSidebarSelection?> {
        Binding(
            get: { AccountsSidebarSelection(rawValue: sidebarSelectionRaw) ?? .codexOverview },
            set: { sidebarSelectionRaw = ($0 ?? .codexOverview).rawValue }
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
                .disabled(model.isProviderBusy(.codex) || !model.canMutateDomain)

                if model.hasCurrentCLIAuthToImport() {
                    Button {
                        Task { await model.importCurrentCLIAuth() }
                    } label: {
                        Image(systemName: "arrow.down.doc")
                    }
                    .help(L10n.tr("action.import_current_auth"))
                    .disabled(model.isProviderBusy(.codex) || !model.canMutateDomain)
                }

            }
        }
        .background(WindowChromeConfigurator())
        .frame(minWidth: 980, minHeight: 620)
        .task {
            await model.refreshForPresentation()
        }
        .onAppear {
            sidebarFilterRaw = sidebarFilter.rawValue
            if model.persistedStateLoaded { ensureValidSelection() }
            model.selectCodexAccountForUsageRefresh(selectedCodexAccount?.id)
        }
        .onChange(of: model.persistedStateLoaded) { _, loaded in
            if loaded { ensureValidSelection() }
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
        .onChange(of: sidebarSelectionRaw) { _, _ in
            model.selectCodexAccountForUsageRefresh(selectedCodexAccount?.id)
            Task { await model.refreshForPresentation() }
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
                            icon: "chart.xyaxis.line",
                            title: L10n.tr("insights.overview.title"),
                            subtitle: nil,
                            trailing: overviewCreditsText,
                            accent: ProviderAccent.codex
                        )
                        .tag(AccountsSidebarSelection.codexOverview)
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
                                let canMakeCurrent = !model.isCurrentCLIAccount(account)
                                let canReauthenticate = model.codexAccountIssue(for: account)?.recommendedAction == .reauthenticate

                                if canMakeCurrent {
                                    Button(L10n.tr("action.make_current")) {
                                        Task { await model.activateAccount(account) }
                                    }
                                    .disabled(!model.canMutateDomain)
                                }

                                if canReauthenticate {
                                    Button(L10n.tr("action.reauthenticate")) {
                                        Task { await model.reauthenticateAccount(account) }
                                    }
                                    .disabled(!model.canMutateDomain)
                                }

                                if canMakeCurrent || canReauthenticate {
                                    Divider()
                                }

                                Button(L10n.tr("action.delete_account"), role: .destructive) {
                                    model.requestDeleteAccount(account)
                                }
                                .disabled(!model.canMutateDomain)
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
                                    .disabled(!model.canMutateDomain)
                                    Divider()
                                }

                                Button(L10n.tr("action.delete_account"), role: .destructive) {
                                    model.requestDeleteClaudeAccount(account)
                                }
                                .disabled(!model.canMutateDomain)
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
                    CodexOverviewPane(model: model)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .contentShape(Rectangle())
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .accessibilityIdentifier("accounts.detail.scroll")
        .background(Color.clear)
    }

    private var overviewCreditsText: String? {
        model.codexInsights.totals.credits.map { L10n.localizedDecimal($0, maximumFractionDigits: 1) }
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
        if model.codexAccountIsSpendBlocked(account) { return .orange }

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
        guard model.persistedStateLoaded else { return }
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
        case .codexOverview:
            return .codexOverview
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

private struct CodexOverviewPane: View {
    @ObservedObject var model: AppModel
    @State private var isCustomPeriodPresented = false
    @State private var customPeriodStart = Date(timeIntervalSince1970: 0)
    @State private var customPeriodEnd = Date(timeIntervalSince1970: 0)

    private var snapshot: CodexInsightsSnapshot { model.codexInsights }
    private var today: Date {
        CodexUsageWindow.utcCalendar.startOfDay(for: model.presentationNow)
    }
    private var hasModelUsage: Bool {
        snapshot.models.contains { $0.totals.usage.totalTokens > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                Text(L10n.tr("insights.overview.title"))
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityIdentifier("codex.insights.overview")
                Spacer(minLength: 12)
                Menu {
                    ForEach(CodexUsagePeriod.allCases, id: \.self) { period in
                        Button {
                            if period == .custom {
                                presentCustomPeriodEditor()
                            } else {
                                model.selectCodexUsagePeriod(period)
                            }
                        } label: {
                            if period == model.codexUsagePeriod {
                                Label(
                                    CodexInsightsTextPresentation.periodTitle(period),
                                    systemImage: "checkmark"
                                )
                            } else {
                                Text(CodexInsightsTextPresentation.periodTitle(period))
                            }
                        }
                    }
                } label: {
                    Text(CodexInsightsTextPresentation.periodTitle(model.codexUsagePeriod))
                        .font(.callout.weight(.medium))
                        .frame(minWidth: 76)
                }
                .menuStyle(.borderlessButton)
                .focusable(false)
                .fixedSize()
                .accessibilityIdentifier("codex.insights.period")
                .accessibilityValue(CodexInsightsTextPresentation.periodTitle(model.codexUsagePeriod))
                .popover(
                    isPresented: $isCustomPeriodPresented,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .top
                ) {
                    customPeriodEditor
                }
            }

            if let change = snapshot.priceChange {
                PriceChangeNotice(change: change, dismiss: model.dismissCodexPriceChange)
            }

            if snapshot.accounts.isEmpty {
                ContentUnavailableView(
                    L10n.tr("insights.empty.title"),
                    systemImage: "chart.xyaxis.line",
                    description: Text(L10n.tr("insights.empty.message"))
                )
                .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                TokenActivityCalendar(
                    daily: snapshot.daily,
                    window: snapshot.window,
                    now: model.presentationNow
                )
                OverviewMetricStrip(snapshot: snapshot)
                if hasModelUsage {
                    ModelUsageStrip(models: snapshot.models)
                }
                UsageTrendChart(daily: snapshot.daily, window: snapshot.window, now: model.presentationNow)
                    .frame(height: 176)
                if let work = snapshot.work {
                    WorkUsageBreakdown(insights: work)
                }
            }

            if let unattributed = snapshot.unattributed {
                UnattributedInsightsSummary(insights: unattributed)
            }
        }
    }

    private var customPeriodEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("insights.period.custom"))
                .font(.headline)

            DatePicker(
                L10n.tr("insights.period.custom.start"),
                selection: $customPeriodStart,
                in: Date.distantPast...today,
                displayedComponents: .date
            )
            .accessibilityIdentifier("codex.insights.period.custom.start")
            .onChange(of: customPeriodStart) {
                if customPeriodEnd < customPeriodStart {
                    customPeriodEnd = customPeriodStart
                }
            }

            DatePicker(
                L10n.tr("insights.period.custom.end"),
                selection: $customPeriodEnd,
                in: customPeriodStart...today,
                displayedComponents: .date
            )
            .accessibilityIdentifier("codex.insights.period.custom.end")

            HStack {
                Spacer()
                Button(L10n.tr("action.cancel")) {
                    isCustomPeriodPresented = false
                }
                Button(L10n.tr("action.apply")) {
                    let window = CodexUsageWindow.inclusiveUTCDays(
                        from: customPeriodStart,
                        through: customPeriodEnd
                    )
                    model.selectCustomCodexUsageWindow(window)
                    isCustomPeriodPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("codex.insights.period.custom.apply")
            }
        }
        .padding(16)
        .frame(width: 300)
        .environment(\.calendar, CodexUsageWindow.utcCalendar)
        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
        .accessibilityIdentifier("codex.insights.period.custom.editor")
    }

    private func presentCustomPeriodEditor() {
        let window = model.currentCustomCodexUsageWindow
        customPeriodStart = min(window.firstUTCDay, today)
        customPeriodEnd = min(window.lastIncludedUTCDay, today)
        isCustomPeriodPresented = true
    }
}

private struct PriceChangeNotice: View {
    let change: OpenAIPriceChange
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.arrow.down")
                .foregroundStyle(ProviderAccent.codex)
            Text(
                L10n.tr(
                    "insights.price_change.message",
                    L10n.tr(
                        "insights.price_change.subject",
                        CodexInsightsTextPresentation.modelTitle(change.modelID),
                        CodexInsightsTextPresentation.priceMetricTitle(change.metric)
                    ),
                    CodexInsightsTextPresentation.priceValue(change.previousValue, metric: change.metric),
                    CodexInsightsTextPresentation.priceValue(change.currentValue, metric: change.metric),
                    L10n.localizedDecimal(change.maximumPercentChange, maximumFractionDigits: 1)
                )
            )
            .font(.callout)
            .lineLimit(2)
            .accessibilityIdentifier("codex.insights.price-change")
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help(L10n.tr("action.dismiss"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(ProviderAccent.codex.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct OverviewMetricStrip: View {
    let snapshot: CodexInsightsSnapshot

    var body: some View {
        AnalyticsMetricStrip(
            metrics: [
                AnalyticsMetric(
                    identifier: "codex.insights.metric.tokens",
                    title: L10n.tr("insights.metric.tokens"),
                    value: CodexInsightsTextPresentation.compactTokens(snapshot.totals.usage.totalTokens),
                    detail: coverageText
                ),
                AnalyticsMetric(
                    identifier: "codex.insights.metric.credits",
                    title: L10n.tr("insights.metric.credits"),
                    value: snapshot.totals.credits.map { L10n.localizedDecimal($0, maximumFractionDigits: 1) } ?? "—",
                    detail: nil
                ),
                AnalyticsMetric(
                    identifier: "codex.insights.metric.api-equivalent",
                    title: L10n.tr("insights.metric.api_equivalent"),
                    value: snapshot.totals.apiEquivalentUSD.map { L10n.localizedCurrencyUSD($0) } ?? "—",
                    detail: nil
                ),
                AnalyticsMetric(
                    identifier: "codex.insights.metric.subscriptions",
                    title: L10n.tr("insights.metric.subscriptions"),
                    value: snapshot.totalMonthlySubscriptionUSD.map { L10n.localizedCurrencyUSD($0, maximumFractionDigits: 0) } ?? "—",
                    detail: snapshot.effectiveSubscriptionUSDPerMillionTokens.map {
                        L10n.tr("insights.metric.effective_per_million", L10n.localizedCurrencyUSD($0))
                    } ?? L10n.tr("insights.metric.effective.collecting")
                ),
            ]
        )
    }

    private var coverageText: String {
        guard let coverage = snapshot.coverage,
              let percent = coverage.fraction else { return L10n.tr("insights.coverage.unavailable") }
        if coverage.hasInconsistentTotals {
            return L10n.tr(
                "insights.coverage.inconsistent",
                CodexInsightsTextPresentation.compactTokens(coverage.observedTokens),
                CodexInsightsTextPresentation.compactTokens(coverage.serverTokens)
            )
        }
        return L10n.tr("insights.coverage.percent", Int((percent * 100).rounded()))
    }
}

private struct AnalyticsMetric: Identifiable {
    let identifier: String
    let title: String
    let value: String
    let detail: String?

    var id: String { identifier }
}

private struct AnalyticsMetricStrip: View {
    let metrics: [AnalyticsMetric]

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(metrics) { metric in
                AnalyticsMetricColumn(metric: metric)
                    .overlay(alignment: .trailing) {
                        Divider()
                            .frame(height: 50)
                            .offset(x: 7)
                            .opacity(metric.id == metrics.last?.id ? 0 : 1)
                    }
            }
        }
    }
}

private struct AnalyticsMetricColumn: View {
    let metric: AnalyticsMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(metric.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(metric.value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let detail = metric.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(metric.identifier)
    }
}

private struct ModelUsageStrip: View {
    let models: [CodexModelUsage]

    private var buckets: [ModelUsageBucket] { ModelUsageBucket.make(from: models) }
    private var totalKnownCredits: Decimal { buckets.compactMap(\.credits).reduce(0, +) }
    private var totalTokens: Int64 { buckets.reduce(0) { $0 + $1.usage.totalTokens } }
    private var unknownTokens: Int64 { buckets.filter { $0.credits == nil }.reduce(0) { $0 + $1.usage.totalTokens } }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { proxy in
                let availableWidth = max(0, proxy.size.width - CGFloat(max(0, buckets.count - 1)) * 2)
                HStack(spacing: 2) {
                    ForEach(buckets) { bucket in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(bucket.color)
                            .frame(width: max(3, availableWidth * fraction(for: bucket)))
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(height: 8)

            HStack(spacing: 16) {
                ForEach(buckets) { bucket in
                    HStack(spacing: 6) {
                        Circle().fill(bucket.color).frame(width: 7, height: 7)
                        Text(bucket.title).font(.caption.weight(.semibold))
                        Text(bucket.creditShareText(of: totalKnownCredits))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Text(CodexInsightsTextPresentation.compactTokens(bucket.usage.totalTokens))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityIdentifier("codex.insights.models")
    }

    private func fraction(for bucket: ModelUsageBucket) -> Double {
        guard totalTokens > 0 else { return 0 }
        guard totalKnownCredits > 0 else {
            return Double(bucket.usage.totalTokens) / Double(totalTokens)
        }
        let unknownFraction = Double(unknownTokens) / Double(totalTokens)
        if let credits = bucket.credits {
            let creditShare = NSDecimalNumber(decimal: credits / totalKnownCredits).doubleValue
            return (1 - unknownFraction) * creditShare
        }
        guard unknownTokens > 0 else { return 0 }
        return unknownFraction * Double(bucket.usage.totalTokens) / Double(unknownTokens)
    }
}

private struct ModelUsageBucket: Identifiable {
    enum Kind: String, CaseIterable { case sol, terra, luna, other }
    let kind: Kind
    let usage: CodexTokenUsage
    let credits: Decimal?

    var id: String { kind.rawValue }
    var title: String {
        switch kind {
        case .sol: "Sol"
        case .terra: "Terra"
        case .luna: "Luna"
        case .other: L10n.tr("insights.model.other")
        }
    }
    var color: Color {
        switch kind {
        case .sol: ProviderAccent.codex
        case .terra: ProviderAccent.codex.opacity(0.72)
        case .luna: ProviderAccent.codex.opacity(0.45)
        case .other: Color.secondary.opacity(0.42)
        }
    }
    func creditShareText(of total: Decimal) -> String {
        guard let credits, total > 0 else { return "—" }
        let percent = credits / total * 100
        return "\(L10n.localizedDecimal(percent, maximumFractionDigits: 0))%"
    }

    static func make(from models: [CodexModelUsage]) -> [Self] {
        Dictionary(grouping: models) { model -> Kind in
            let id = model.modelID.lowercased()
            if id.contains("sol") || id == "gpt-5.6" { return .sol }
            if id.contains("terra") { return .terra }
            if id.contains("luna") { return .luna }
            return .other
        }
        .map { kind, models in
            let usage = models.reduce(CodexTokenUsage.zero) { $0 + $1.totals.usage }
            let credits = models.allSatisfy { $0.totals.credits != nil }
                ? models.compactMap { $0.totals.credits }.reduce(0, +)
                : nil
            return Self(kind: kind, usage: usage, credits: credits)
        }
        .sorted { Kind.allCases.firstIndex(of: $0.kind)! < Kind.allCases.firstIndex(of: $1.kind)! }
    }
}

private struct UnattributedInsightsSummary: View {
    let insights: CodexUnattributedInsights

    var body: some View {
        VStack(spacing: 10) {
            MinimalSeparator()

            HStack(alignment: .firstTextBaseline, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("insights.unattributed.title"))
                        .font(.callout.weight(.semibold))
                    Text(L10n.tr("insights.unattributed.context", modelNames))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(
                        L10n.tr(
                            "insights.unattributed.tokens",
                            CodexInsightsTextPresentation.compactTokens(insights.totals.usage.totalTokens)
                        )
                    )
                    .font(.callout.weight(.semibold))

                    Text(L10n.tr("insights.unattributed.estimates", credits, apiEquivalent))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("codex.insights.unattributed")
    }

    private var modelNames: String {
        insights.models.prefix(4)
            .map { CodexInsightsTextPresentation.modelTitle($0.modelID) }
            .formatted(.list(type: .and).locale(L10n.locale))
    }

    private var credits: String {
        insights.totals.credits.map {
            L10n.localizedDecimal($0, maximumFractionDigits: 1)
        } ?? "—"
    }

    private var apiEquivalent: String {
        insights.totals.apiEquivalentUSD.map {
            L10n.localizedCurrencyUSD($0)
        } ?? "—"
    }
}

private struct CurrentClaudeDetailPane: View {
    @ObservedObject var model: AppModel

    private var overview: AppModel.CurrentClaudeOverview {
        model.currentClaudeOverview()
    }

    private var referenceAccount: ClaudeStoredAccount? {
        model.currentClaudeReferenceAccount()
    }

    private var email: String? {
        model.currentClaudeStatus?.email ?? referenceAccount?.email
    }

    private var liveSections: [RateLimitDisplaySection] {
        model.currentClaudeLiveRateLimitSections()
    }

    private var identity: AccountIdentityPresentation {
        AccountIdentityPresentation(label: overview.title, email: email)
    }

    private var showsPrimaryAction: Bool {
        model.hasCurrentClaudeAuthToImport()
            || model.claudeLiveBridgeInstalled()
            || model.currentClaudeStatus?.loggedIn == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AccountDetailLayout(
                title: identity.title,
                subtitle: identity.subtitle,
                note: overview.note,
                metaLine: metaLine,
                renameTitle: model.canMutateDomain ? referenceAccount.map { account in
                    { (title: String) -> Void in
                        Task<Void, Never> {
                            await model.renameAccount(account, to: title)
                        }
                    }
                } : nil,
                subtitleIsCopyable: identity.subtitle != nil,
                showsActions: showsPrimaryAction,
                headerAccessory: {
                    ProviderStatusBadge(
                        presentation: ProviderPresentation.claudeBadge(source: model.currentClaudeState.source)
                    )
                },
                details: {
                    EmptyView()
                },
                actions: {
                    if model.hasCurrentClaudeAuthToImport() {
                        Button(L10n.tr("action.save_account")) {
                            Task { await model.importCurrentClaudeAuth() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isProviderBusy(.claude) || !model.canMutateDomain)
                    }

                    if model.claudeLiveBridgeInstalled() {
                        Button(L10n.tr("action.disconnect_bridge")) {
                            Task { await model.uninstallClaudeLiveLimitsBridge() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isProviderBusy(.claude) || !model.canMutateDomain)
                    } else if model.currentClaudeStatus?.loggedIn == true {
                        Button(L10n.tr("action.connect_live_limits")) {
                            Task { await model.installClaudeLiveLimitsBridge() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isProviderBusy(.claude) || !model.canMutateDomain)
                    }
                }
            )

            MinimalSeparator()
            ClaudeLimitsSummary(
                providerError: model.providerErrorMessage(.claude) == model.currentClaudeBridgeError
                    ? nil
                    : model.providerErrorMessage(.claude),
                bridgeError: model.currentClaudeBridgeError,
                sections: liveSections,
                emptyTitle: bridgeCardTitle,
                emptySubtitle: bridgeCardSubtitle
            )
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

    private var identity: AccountIdentityPresentation {
        AccountIdentityPresentation(label: account.label, email: account.email)
    }

    private var showsPrimaryAction: Bool {
        if !isCurrent { return true }
        return model.claudeLiveBridgeInstalled() || model.currentClaudeStatus?.loggedIn == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AccountDetailLayout(
                title: identity.title,
                subtitle: identity.subtitle,
                note: accountNote,
                metaLine: accountMetaLine,
                renameTitle: model.canMutateDomain ? { title in
                    Task { await model.renameAccount(account, to: title) }
                } : nil,
                subtitleIsCopyable: identity.subtitle != nil,
                showsActions: showsPrimaryAction,
                headerAccessory: {
                    AccountHeaderAccessory(
                        presentation: ProviderPresentation.accountBadge(
                            status: account.status,
                            isCurrent: isCurrent,
                            provider: .claude
                        ),
                        canDelete: model.canMutateDomain && !model.isProviderBusy(.claude),
                        delete: { model.requestDeleteClaudeAccount(account) }
                    )
                },
                details: {
                    EmptyView()
                },
                actions: {
                    if !isCurrent {
                        Button(L10n.tr("action.make_current")) {
                            Task { await model.activateClaudeAccount(account) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isProviderBusy(.claude) || !model.canMutateDomain)
                    } else {
                        if model.claudeLiveBridgeInstalled() {
                            Button(L10n.tr("action.disconnect_bridge")) {
                                Task { await model.uninstallClaudeLiveLimitsBridge() }
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.isProviderBusy(.claude) || !model.canMutateDomain)
                        } else if model.currentClaudeStatus?.loggedIn == true {
                            Button(L10n.tr("action.connect_live_limits")) {
                                Task { await model.installClaudeLiveLimitsBridge() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isProviderBusy(.claude) || !model.canMutateDomain)
                        }
                    }

                }
            )

            MinimalSeparator()
            ClaudeLimitsSummary(
                providerError: model.providerErrorMessage(.claude) == model.currentClaudeBridgeError
                    ? nil
                    : model.providerErrorMessage(.claude),
                bridgeError: isCurrent ? model.currentClaudeBridgeError : nil,
                sections: liveSections,
                emptyTitle: emptyStateTitle,
                emptySubtitle: emptyStateSubtitle
            )
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

private struct ClaudeLimitsSummary: View {
    let providerError: String?
    let bridgeError: String?
    let sections: [RateLimitDisplaySection]
    let emptyTitle: String
    let emptySubtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let providerError {
                InlineStatusMessage(text: providerError)
                MinimalSeparator()
            }

            if let bridgeError {
                InlineStatusMessage(text: bridgeError)
                MinimalSeparator()
            }

            if sections.isEmpty {
                EmptyLimitsSummary(title: emptyTitle, subtitle: emptySubtitle)
            } else {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    LimitSection(section: section, tint: ProviderAccent.claude)

                    if index < sections.count - 1 {
                        MinimalSeparator()
                    }
                }
            }
        }
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

    private var plan: ChatGPTPlanPresentation {
        model.chatGPTPlanPresentation(for: account)
    }

    private var subscriptionCycle: ChatGPTSubscriptionCyclePresentation? {
        model.chatGPTSubscriptionCycle(for: account, now: model.presentationNow)
    }

    private var accountIssue: CodexAccountIssuePresentation? {
        model.codexAccountIssue(for: account)
    }

    private var insights: CodexAccountInsights? {
        model.codexInsights(for: account)
    }

    private var identity: AccountIdentityPresentation {
        AccountIdentityPresentation(label: account.label, email: account.email)
    }

    private var canMakeCurrent: Bool {
        !isCurrent && accountIssue?.recommendedAction != .reauthenticate
    }

    var body: some View {
        AccountDetailLayout(
            title: identity.title,
            subtitle: identity.subtitle,
            note: nil,
            metaLine: nil,
            renameTitle: model.canMutateDomain ? { title in
                Task { await model.renameAccount(account, to: title) }
            } : nil,
            subtitleIsCopyable: identity.subtitle != nil,
            showsActions: canMakeCurrent,
            headerAccessory: {
                AccountHeaderAccessory(
                    presentation: ProviderPresentation.accountBadge(
                        status: account.status,
                        isCurrent: isCurrent,
                        provider: .codex
                    ),
                    canDelete: model.canMutateDomain && !model.isProviderBusy(.codex),
                    delete: { model.requestDeleteAccount(account) }
                )
            },
            details: {
                ChatGPTAccountPanel(plan: plan, cycle: subscriptionCycle) {
                    StoredAccountSummary(
                        sections: sections,
                        emptyLimitsSummary: accountIssue == nil
                            ? model.storedRateLimitSummary(for: account)
                                ?? L10n.tr("limits.empty.account.subtitle")
                            : nil,
                        issue: accountIssue,
                        insights: insights,
                        now: model.presentationNow,
                        reauthenticate: accountIssue?.recommendedAction == .reauthenticate
                            ? { Task { await model.reauthenticateAccount(account) } }
                            : nil,
                        canReauthenticate: model.canMutateDomain && !model.isProviderBusy(.codex)
                    )
                }
            },
            actions: {
                if canMakeCurrent {
                    Button(L10n.tr("action.make_current")) {
                        Task { await model.activateAccount(account) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isProviderBusy(.codex) || !model.canMutateDomain)
                }

            }
        )
    }
}

private struct StoredAccountSummary: View {
    let sections: [RateLimitDisplaySection]
    let emptyLimitsSummary: String?
    let issue: CodexAccountIssuePresentation?
    let insights: CodexAccountInsights?
    let now: Date
    let reauthenticate: (() -> Void)?
    let canReauthenticate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let issue {
                MinimalSeparator()
                CodexAccountIssueSummary(
                    issue: issue,
                    reauthenticate: reauthenticate,
                    canReauthenticate: canReauthenticate
                )
            }

            if sections.isEmpty {
                if let emptyLimitsSummary {
                    MinimalSeparator()
                    EmptyLimitsSummary(
                        title: L10n.tr("limits.empty.title"),
                        subtitle: emptyLimitsSummary
                    )
                }
            } else {
                MinimalSeparator()
                AccountLimitsGrid(sections: sections, tint: ProviderAccent.codex)
            }

            if let insights {
                MinimalSeparator()
                AccountUsageSummary(insights: insights, now: now)
            }
        }
    }
}

private struct AccountUsageSummary: View {
    let insights: CodexAccountInsights
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("insights.account.title"))
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("codex.insights.account-detail")

            if insights.hasDisplayableUsage {
                AnalyticsMetricStrip(
                    metrics: [
                        AnalyticsMetric(
                        identifier: "codex.insights.account.metric.tokens",
                        title: L10n.tr("insights.metric.tokens"),
                        value: CodexInsightsTextPresentation.compactTokens(insights.totals.usage.totalTokens),
                        detail: accountCoverageText
                    ),
                        AnalyticsMetric(
                        identifier: "codex.insights.account.metric.credits",
                        title: L10n.tr("insights.metric.credits"),
                        value: insights.totals.credits.map { L10n.localizedDecimal($0, maximumFractionDigits: 1) } ?? "—",
                        detail: nil
                    ),
                        AnalyticsMetric(
                        identifier: "codex.insights.account.metric.api-equivalent",
                        title: L10n.tr("insights.metric.api_equivalent"),
                        value: insights.totals.apiEquivalentUSD.map { L10n.localizedCurrencyUSD($0) } ?? "—",
                        detail: insights.effectiveSubscriptionUSDPerMillionTokens.map {
                            L10n.tr("insights.metric.effective_per_million", L10n.localizedCurrencyUSD($0))
                        } ?? L10n.tr("insights.metric.effective.collecting")
                    ),
                    ]
                )

                if hasModelUsage {
                    ModelUsageStrip(models: insights.models)
                }
                if hasDailyUsage {
                    UsageTrendChart(daily: insights.daily, window: insights.window, now: now)
                        .frame(height: 130)
                }
            } else {
                Text(L10n.tr("insights.account.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("codex.insights.account-detail.empty")
            }
        }
    }

    private var hasModelUsage: Bool {
        insights.models.contains { $0.totals.usage.totalTokens > 0 }
    }

    private var hasDailyUsage: Bool {
        insights.daily.contains { day in
            day.totals.usage.totalTokens > 0
                || day.totals.credits.map({ $0 != 0 }) == true
                || day.totals.apiEquivalentUSD.map({ $0 != 0 }) == true
        }
    }

    private var accountCoverageText: String {
        guard let coverage = insights.coverage, let fraction = coverage.fraction else {
            return L10n.tr("insights.coverage.unavailable")
        }
        if coverage.hasInconsistentTotals {
            return L10n.tr(
                "insights.coverage.inconsistent",
                CodexInsightsTextPresentation.compactTokens(coverage.observedTokens),
                CodexInsightsTextPresentation.compactTokens(coverage.serverTokens)
            )
        }
        return L10n.tr("insights.coverage.percent", Int((fraction * 100).rounded()))
    }
}

private struct AccountHeaderAccessory: View {
    let presentation: ProviderBadgePresentation
    let canDelete: Bool
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProviderStatusBadge(presentation: presentation)

            Group {
                if canDelete {
                    Menu {
                        Button(L10n.tr("action.delete"), role: .destructive, action: delete)
                    } label: {
                        actionsIcon
                    }
                    .menuStyle(.borderlessButton)
                } else {
                    Button(action: delete) {
                        actionsIcon
                    }
                    .buttonStyle(.borderless)
                    .disabled(true)
                }
            }
            .fixedSize()
            .help(L10n.tr("action.more"))
            .accessibilityLabel(L10n.tr("action.more"))
            .accessibilityIdentifier("account.actions.more")
        }
    }

    private var actionsIcon: some View {
        Image(systemName: "ellipsis.circle")
            .font(.system(size: 16))
    }
}

private struct AccountDetailLayout<HeaderAccessory: View, Details: View, Actions: View>: View {
    let title: String
    let subtitle: String?
    let note: String?
    let metaLine: String?
    let renameTitle: ((String) -> Void)?
    let subtitleIsCopyable: Bool
    let showsActions: Bool
    let headerAccessory: HeaderAccessory
    let details: Details
    let actions: Actions

    @State private var isRenamingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFieldIsFocused: Bool

    init(
        title: String,
        subtitle: String?,
        note: String?,
        metaLine: String?,
        renameTitle: ((String) -> Void)? = nil,
        subtitleIsCopyable: Bool = false,
        showsActions: Bool,
        @ViewBuilder headerAccessory: () -> HeaderAccessory,
        @ViewBuilder details: () -> Details,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.note = note
        self.metaLine = metaLine
        self.renameTitle = renameTitle
        self.subtitleIsCopyable = subtitleIsCopyable
        self.showsActions = showsActions
        self.headerAccessory = headerAccessory()
        self.details = details()
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    if isRenamingTitle {
                        TextField(L10n.tr("account.rename.prompt"), text: $titleDraft)
                            .textFieldStyle(.plain)
                            .font(.largeTitle.weight(.semibold))
                            .focused($titleFieldIsFocused)
                            .onSubmit(commitRename)
                            .onExitCommand(perform: cancelRename)
                            .accessibilityIdentifier("account.identity.name-field")
                    } else {
                        displayedTitle
                    }

                    if let subtitle {
                        if subtitleIsCopyable {
                            Button {
                                copyToPasteboard(subtitle)
                            } label: {
                                subtitleLabel(subtitle)
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                            .help(L10n.tr("account.email.copy"))
                            .accessibilityHint(L10n.tr("account.email.copy"))
                            .accessibilityIdentifier("account.identity.email")
                        } else {
                            subtitleLabel(subtitle)
                        }
                    }
                }

                Spacer(minLength: 12)
                headerAccessory
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

            if showsActions {
                HStack(spacing: 10) {
                    actions
                }
            }

            details
        }
        .onChange(of: titleFieldIsFocused) { _, isFocused in
            if !isFocused, isRenamingTitle {
                commitRename()
            }
        }
    }

    @ViewBuilder
    private var displayedTitle: some View {
        let text = Text(title)
            .font(.largeTitle.weight(.semibold))
            .lineLimit(2)
            .accessibilityLabel(title)
            .accessibilityIdentifier("account.identity.title")

        if renameTitle != nil {
            text
                .onTapGesture(count: 2, perform: beginRename)
                .help(L10n.tr("account.rename.hint"))
                .accessibilityHint(L10n.tr("account.rename.hint"))
                .accessibilityAction(named: Text(L10n.tr("account.rename.action")), beginRename)
        } else {
            text
        }
    }

    private func subtitleLabel(_ subtitle: String) -> some View {
        Text(subtitle)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    private func beginRename() {
        guard renameTitle != nil else { return }
        titleDraft = title
        isRenamingTitle = true
        Task { @MainActor in
            await Task.yield()
            titleFieldIsFocused = true
        }
    }

    private func commitRename() {
        guard isRenamingTitle else { return }
        let proposedTitle = titleDraft
        isRenamingTitle = false
        titleFieldIsFocused = false
        guard !proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            titleDraft = title
            return
        }
        guard proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines) != title else {
            return
        }
        renameTitle?(proposedTitle)
    }

    private func cancelRename() {
        guard isRenamingTitle else { return }
        isRenamingTitle = false
        titleFieldIsFocused = false
        titleDraft = title
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct ChatGPTAccountPanel<AdditionalContent: View>: View {
    let plan: ChatGPTPlanPresentation
    let cycle: ChatGPTSubscriptionCyclePresentation?
    let additionalContent: AdditionalContent

    init(
        plan: ChatGPTPlanPresentation,
        cycle: ChatGPTSubscriptionCyclePresentation?,
        @ViewBuilder additionalContent: () -> AdditionalContent
    ) {
        self.plan = plan
        self.cycle = cycle
        self.additionalContent = additionalContent()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(plan.title)
                    .font(.headline)

                Spacer(minLength: 12)

                if let monthlyPrice = plan.monthlyPrice {
                    Text(monthlyPrice)
                        .font(.headline)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                plan.monthlyPrice.map { "\(plan.title), \($0)" } ?? plan.title
            )
            .accessibilityIdentifier("chatgpt.subscription.plan")

            if let cycle {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow(alignment: .center) {
                        Text(L10n.tr("subscription.payment_in"))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 160, alignment: .leading)

                        if let progress = cycle.remainingProgress {
                            LimitsProgressBar(progress: progress, tint: subscriptionTint(for: cycle))
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier("chatgpt.subscription.progress")
                        } else {
                            LimitsProgressBar(progress: 0, tint: .secondary)
                                .frame(height: 12)
                        }

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(cycle.countdownText)
                                .font(.headline)
                                .monospacedDigit()

                            Text(cycle.paymentDateText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 190, alignment: .trailing)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(L10n.tr("subscription.payment_in")): \(cycle.countdownText). \(cycle.paymentDateText)"
                )
                .accessibilityIdentifier("chatgpt.subscription.cycle")
            } else {
                Text(L10n.tr("subscription.date_unavailable"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            additionalContent
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            shape
                .fill(.primary.opacity(0.035))
                .overlay {
                    shape
                        .stroke(.primary.opacity(0.07), lineWidth: 1)
                }
        )
        .clipShape(shape)
    }

    private func subscriptionTint(for cycle: ChatGPTSubscriptionCyclePresentation) -> Color {
        if cycle.isExpired { return .red }
        if let progress = cycle.remainingProgress, progress <= 0.1 { return .orange }
        return ProviderAccent.codex
    }
}

private extension ChatGPTAccountPanel where AdditionalContent == EmptyView {
    init(plan: ChatGPTPlanPresentation, cycle: ChatGPTSubscriptionCyclePresentation?) {
        self.init(plan: plan, cycle: cycle) { EmptyView() }
    }
}

private struct CodexAccountIssueSummary: View {
    let issue: CodexAccountIssuePresentation
    let reauthenticate: (() -> Void)?
    let canReauthenticate: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: issue.recommendedAction == .reauthenticate
                  ? "person.crop.circle.badge.exclamationmark"
                  : "exclamationmark.circle.fill")
                .foregroundStyle(issue.tone.color)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title)
                    .font(.headline)
                Text(issue.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(issue.title). \(issue.message)")
            .accessibilityIdentifier("codex.account.issue")

            Spacer(minLength: 12)

            if let reauthenticate {
                Button(L10n.tr("action.reauthenticate"), action: reauthenticate)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canReauthenticate)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LimitSection: View {
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

private struct AccountLimitsGrid: View {
    let sections: [RateLimitDisplaySection]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(sections) { section in
                HStack(alignment: .top, spacing: 14) {
                    Text(section.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(width: 160, alignment: .leading)
                        .help(section.title)

                    LazyVGrid(columns: columns(for: section.rows.count), alignment: .leading, spacing: 10) {
                        ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                            StoredAccountLimitWindow(
                                quotaTitle: section.title,
                                row: row,
                                tint: resolvedTint(for: row)
                            )
                            .padding(.leading, index % 2 == 1 ? 12 : 0)
                            .overlay(alignment: .leading) {
                                if index % 2 == 1 {
                                    Rectangle()
                                        .fill(.primary.opacity(0.08))
                                        .frame(width: 1)
                                }
                            }
                        }
                    }
                }
                .padding(.top, section.id != sections.first?.id ? 4 : 0)
            }
        }
    }

    private func columns(for rowCount: Int) -> [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
            count: min(max(rowCount, 1), 2)
        )
    }

    private func resolvedTint(for row: RateLimitDisplayRow) -> Color {
        row.remainingPercent <= 9 ? .red : tint
    }
}

private struct StoredAccountLimitWindow: View {
    let quotaTitle: String
    let row: RateLimitDisplayRow
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(row.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 4)

                LimitRemainingValue(
                    row: row,
                    valueFont: .callout.weight(.semibold),
                    showsReset: false
                )
            }

            LimitsProgressBar(progress: row.remainingProgressValue, tint: tint)
                .frame(maxWidth: .infinity)

            LimitResetLabel(row: row)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        [quotaTitle, row.title, L10n.percentRemaining(row.remainingPercent), row.resetText]
            .compactMap { $0 }
            .joined(separator: ". ")
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

                LimitsProgressBar(progress: row.remainingProgressValue, tint: resolvedTint)
                    .frame(maxWidth: .infinity)

                LimitRemainingValue(row: row)
                .frame(width: 190, alignment: .trailing)
            }
        }
    }

    private var resolvedTint: Color {
        row.remainingPercent <= 9 ? .red : tint
    }
}

private struct LimitRemainingValue: View {
    let row: RateLimitDisplayRow
    let valueFont: Font
    let showsReset: Bool

    init(
        row: RateLimitDisplayRow,
        valueFont: Font = .headline,
        showsReset: Bool = true
    ) {
        self.row = row
        self.valueFont = valueFont
        self.showsReset = showsReset
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(L10n.percentRemaining(row.remainingPercent))
                .font(valueFont)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            if showsReset {
                LimitResetLabel(row: row)
            }
        }
    }
}

private struct LimitResetLabel: View {
    let row: RateLimitDisplayRow

    var body: some View {
        if let resetText = row.resetText {
            Text(resetText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

private struct EmptyLimitsSummary: View {
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

private struct InlineStatusMessage: View {
    let text: String
    var color: Color = .red

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(color)
            .padding(.vertical, 2)
    }
}
