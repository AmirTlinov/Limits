import AppKit
import Charts
import SwiftUI
import LimitsCore
import LimitsShared

private enum AccountsSidebarSelection: Hashable {
    case codexOverview
    case currentCodexCLI
    case codexAccount(UUID)
    case currentClaudeCode
    case claudeAccount(UUID)

    var rawValue: String {
        switch self {
        case .codexOverview:
            return "codex-overview"
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
        if rawValue == "codex-overview" {
            self = .codexOverview
            return
        }
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
    @AppStorage("limits.accounts.selection") private var sidebarSelectionRaw = AccountsSidebarSelection.codexOverview.rawValue
    @AppStorage(AccountsSidebarFilter.providerFilterStorageKey) private var sidebarFilterRaw = AccountsSidebarFilter.all.rawValue

    private var overview: AppModel.CurrentCLIOverview {
        model.currentCLIOverview()
    }

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
                            subtitle: overviewRiskSubtitle,
                            trailing: overviewCreditsText,
                            accent: ProviderAccent.codex
                        )
                        .tag(AccountsSidebarSelection.codexOverview)

                        SidebarRowView(
                            icon: "person.crop.circle.fill.badge.checkmark",
                            title: TrayStatusProvider.codex.displayTitle,
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
                } else if detailDestination == .codexOverview {
                    CodexOverviewPane(model: model) { accountID in
                        sidebarSelectionRaw = AccountsSidebarSelection.codexAccount(accountID).rawValue
                    }
                } else {
                    CurrentCLIDetailPane(model: model)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("accounts.detail.scroll")
        .background(Color.clear)
    }

    private var currentCLITrailingText: String? {
        model.currentCLIDisplaySidebarLimitSummary()?.compactLimitText()
    }

    private var overviewRiskSubtitle: String? {
        guard let risk = CodexAnalyticsSelection.quota(in: model.codexInsights),
              model.codexInsights.nearestRisk != nil else {
            let forecasts = model.codexInsights.accounts.flatMap(\.quotaForecasts).map(\.forecast.state)
            guard !forecasts.isEmpty else { return nil }
            if forecasts.allSatisfy({ [.lastsUntilReset, .stable].contains($0) }) {
                return L10n.tr("insights.risk.all_safe")
            }
            if forecasts.contains(.stale) { return L10n.tr("insights.forecast.stale") }
            return L10n.tr("insights.forecast.collecting")
        }
        return "\(risk.account.label) · \(risk.quota.title)"
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

private struct CodexOverviewPane: View {
    @ObservedObject var model: AppModel
    let openAccount: (UUID) -> Void

    private var snapshot: CodexInsightsSnapshot { model.codexInsights }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                Text(L10n.tr("insights.overview.title"))
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityIdentifier("codex.insights.overview")
                Spacer(minLength: 12)
                Picker(L10n.tr("insights.period.label"), selection: $model.codexUsagePeriod) {
                    Text(L10n.tr("insights.period.week")).tag(CodexUsagePeriod.currentWeek)
                    Text(L10n.tr("insights.period.30_days")).tag(CodexUsagePeriod.last30Days)
                    Text(L10n.tr("insights.period.all")).tag(CodexUsagePeriod.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                .accessibilityIdentifier("codex.insights.period")
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
                    daily: model.codexAnalyticsSnapshots.all.daily,
                    now: model.presentationNow
                )
                InsightsMetricsGrid(snapshot: snapshot)
                WeeklyRiskCard(snapshot: snapshot, now: model.presentationNow)
                ModelUsageStrip(models: snapshot.models)
                UsageTrendChart(daily: snapshot.daily, period: snapshot.period, now: model.presentationNow)
                    .frame(height: 176)
                if let work = snapshot.work {
                    WorkUsageBreakdown(insights: work)
                }
                InsightsAccountList(accounts: snapshot.accounts, openAccount: openAccount)
            }

            if let unattributed = snapshot.unattributed {
                UnattributedInsightsCard(insights: unattributed, period: snapshot.period)
            }
        }
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

private struct WeeklyRiskCard: View {
    let snapshot: CodexInsightsSnapshot
    let now: Date

    private var selection: (account: CodexAccountInsights, quota: CodexQuotaForecast)? {
        CodexAnalyticsSelection.quota(in: snapshot)
    }

    private var allSafe: Bool {
        snapshot.nearestRisk == nil
            && snapshot.accounts.flatMap(\.quotaForecasts).allSatisfy {
                [.lastsUntilReset, .stable].contains($0.forecast.state)
            }
    }

    var body: some View {
        if let selection {
            HStack(spacing: 12) {
                Image(systemName: selection.quota.forecast.state == .exhaustsBeforeReset ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.50percent")
                    .font(.callout)
                    .foregroundStyle(forecastColor(selection.quota.forecast.state))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(riskHeading(for: selection.quota))
                        .font(.caption.weight(.semibold))
                    Text(L10n.tr("insights.risk.scope"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Divider().frame(height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(selection.account.label).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(selection.quota.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(CodexInsightsTextPresentation.forecast(selection.quota.forecast, now: now))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(forecastColor(selection.quota.forecast.state))
                        .lineLimit(1)
                    if let reset = CodexInsightsTextPresentation.reset(selection.quota.forecast, now: now) {
                        Text(reset).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ForecastProgressBar(forecast: selection.quota.forecast)
                    .frame(width: 210)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("codex.insights.weekly-risk")
        }
    }

    private func riskHeading(for quota: CodexQuotaForecast) -> String {
        if allSafe { return L10n.tr("insights.risk.all_safe") }
        if quota.forecast.state == .exhaustsBeforeReset { return L10n.tr("insights.risk.nearest") }
        return L10n.tr("insights.limit.weekly")
    }
}

private struct ForecastProgressBar: View {
    let forecast: LimitBurnForecast

    var body: some View {
        let remaining = forecast.remainingPercent.map { Double($0) / 100 }
        HStack(spacing: 10) {
            ProgressView(value: min(max(remaining ?? 0, 0), 1))
                .progressViewStyle(.linear)
                .tint(remaining == nil ? Color.secondary : forecastColor(forecast.state))
                .opacity(remaining == nil ? 0.35 : 1)
            Text(forecast.remainingPercent.map { L10n.tr("insights.remaining.percent", $0) } ?? "—")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .frame(width: 82, alignment: .trailing)
        }
    }
}

private struct InsightsMetricsGrid: View {
    let snapshot: CodexInsightsSnapshot

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                InsightsMetric(
                    identifier: "codex.insights.metric.tokens",
                    title: L10n.tr("insights.metric.tokens"),
                    value: CodexInsightsTextPresentation.compactTokens(snapshot.totals.usage.totalTokens),
                    subtitle: coverageText
                )
                InsightsMetric(
                    identifier: "codex.insights.metric.credits",
                    title: L10n.tr("insights.metric.credits"),
                    value: snapshot.totals.credits.map { L10n.localizedDecimal($0, maximumFractionDigits: 1) } ?? "—",
                    subtitle: nil
                )
                InsightsMetric(
                    identifier: "codex.insights.metric.api-equivalent",
                    title: L10n.tr("insights.metric.api_equivalent"),
                    value: snapshot.totals.apiEquivalentUSD.map { L10n.localizedCurrencyUSD($0) } ?? "—",
                    subtitle: nil
                )
                InsightsMetric(
                    identifier: "codex.insights.metric.subscriptions",
                    title: L10n.tr("insights.metric.subscriptions"),
                    value: snapshot.totalMonthlySubscriptionUSD.map { L10n.localizedCurrencyUSD($0, maximumFractionDigits: 0) } ?? "—",
                    subtitle: snapshot.effectiveSubscriptionUSDPerMillionTokens.map {
                        L10n.tr("insights.metric.effective_per_million", L10n.localizedCurrencyUSD($0))
                    } ?? L10n.tr("insights.metric.effective.collecting")
                )
            }
        }
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

private struct InsightsMetric: View {
    let identifier: String
    let title: String
    let value: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
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
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(bucket.color)
                            .frame(width: max(3, availableWidth * fraction(for: bucket)))
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(height: 12)

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

private struct InsightsAccountList: View {
    let accounts: [CodexAccountInsights]
    let openAccount: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(accounts) { account in
                if let localID = account.localAccountID {
                    Button { openAccount(localID) } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.label).font(.callout.weight(.semibold)).lineLimit(1)
                                Text(account.planTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if let quota = account.riskiestQuotaForecast {
                                Text("\(quota.title) · \(CodexInsightsTextPresentation.forecast(quota.forecast))")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(forecastColor(quota.forecast.state))
                                    .lineLimit(1)
                            }
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("codex.insights.account.\(localID.uuidString)")
                }
            }
        }
    }
}

private struct UnattributedInsightsCard: View {
    let insights: CodexUnattributedInsights
    let period: CodexUsagePeriod

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("insights.unattributed.title"))
                        .font(.headline)
                    Text(L10n.tr("insights.unattributed.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Text(L10n.tr("insights.unattributed.period", periodTitle))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 18) {
                Label(
                    CodexInsightsTextPresentation.compactTokens(insights.totals.usage.totalTokens),
                    systemImage: "text.word.spacing"
                )
                Label(
                    insights.totals.credits.map { L10n.localizedDecimal($0, maximumFractionDigits: 1) } ?? "—",
                    systemImage: "sparkles"
                )
                Label(
                    insights.totals.apiEquivalentUSD.map { L10n.localizedCurrencyUSD($0) } ?? "—",
                    systemImage: "dollarsign.circle"
                )
            }
            .font(.callout.weight(.semibold))
            .monospacedDigit()

            Text(
                L10n.tr(
                    "insights.unattributed.models",
                    insights.models.prefix(4)
                        .map { CodexInsightsTextPresentation.modelTitle($0.modelID) }
                        .joined(separator: ", ")
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        .padding(14)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("codex.insights.unattributed")
    }

    private var periodTitle: String {
        switch period {
        case .currentWeek: L10n.tr("insights.period.week")
        case .last30Days: L10n.tr("insights.period.30_days")
        case .all: L10n.tr("insights.period.all")
        }
    }
}

private func forecastColor(_ state: LimitBurnForecastState) -> Color {
    switch state {
    case .exhaustsBeforeReset: .orange
    case .stale: .secondary
    case .collecting: .secondary
    case .stable, .lastsUntilReset: ProviderAccent.codex
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

    private var plan: ChatGPTPlanPresentation? {
        model.currentChatGPTPlanPresentation()
    }

    private var subscriptionCycle: ChatGPTSubscriptionCyclePresentation? {
        model.currentChatGPTSubscriptionCycle(now: model.presentationNow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DetailHeroCard(
                title: overview.title,
                subtitle: model.currentCLIProbe?.email ?? model.currentCLIReferenceAccount()?.email,
                note: overview.note,
                metaLine: nil,
                renameTitle: model.canMutateDomain ? model.currentCLIReferenceAccount().map { account in
                    { title in Task { await model.renameAccount(account, to: title) } }
                } : nil,
                subtitleIsCopyable: true,
                stateBadge: {
                    CLIStateBadge(source: model.currentCLIState.source)
                },
                details: {
                    if let plan {
                        ChatGPTAccountPanel(plan: plan, cycle: subscriptionCycle)
                    }
                },
                actions: {
                    if model.hasCurrentCLIAuthToImport() {
                        Button(L10n.tr("action.import_current_auth")) {
                            Task { await model.importCurrentCLIAuth() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isProviderBusy(.codex) || !model.canMutateDomain)
                    } else if model.shouldOfferAddAccountAsPrimaryAction() {
                        Button(L10n.tr("action.add_account")) {
                            Task { await model.addAccount() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isProviderBusy(.codex) || !model.canMutateDomain)
                    }

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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DetailHeroCard(
                title: overview.title,
                subtitle: email,
                note: overview.note,
                metaLine: metaLine,
                renameTitle: model.canMutateDomain ? referenceAccount.map { account in
                    { title in Task { await model.renameAccount(account, to: title) } }
                } : nil,
                subtitleIsCopyable: email != nil,
                stateBadge: {
                    ClaudeStateBadge(model: model)
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
                note: accountNote,
                metaLine: accountMetaLine,
                renameTitle: model.canMutateDomain ? { title in
                    Task { await model.renameAccount(account, to: title) }
                } : nil,
                subtitleIsCopyable: true,
                stateBadge: {
                    AccountStatusBadge(status: account.status, isCurrent: isCurrent, provider: .claude)
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

                    Button(L10n.tr("action.delete"), role: .destructive) {
                        model.requestDeleteClaudeAccount(account)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isProviderBusy(.claude) || !model.canMutateDomain)
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

    var body: some View {
        DetailHeroCard(
            title: account.label,
            subtitle: account.email,
            note: nil,
            metaLine: nil,
            renameTitle: model.canMutateDomain ? { title in
                Task { await model.renameAccount(account, to: title) }
            } : nil,
            subtitleIsCopyable: true,
            stateBadge: {
                AccountStatusBadge(status: account.status, isCurrent: isCurrent)
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
                        period: model.codexUsagePeriod,
                        now: model.presentationNow
                    )
                }
            },
            actions: {
                if !isCurrent {
                    Button(L10n.tr("action.make_current")) {
                        Task { await model.activateAccount(account) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isProviderBusy(.codex) || !model.canMutateDomain)
                }

                if accountIssue?.recommendedAction == .reauthenticate {
                    Button(L10n.tr("action.reauthenticate")) {
                        Task { await model.reauthenticateAccount(account) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isProviderBusy(.codex) || !model.canMutateDomain)
                }

                Button(L10n.tr("action.delete"), role: .destructive) {
                    model.requestDeleteAccount(account)
                }
                .buttonStyle(.bordered)
                .disabled(model.isProviderBusy(.codex) || !model.canMutateDomain)
            }
        )
    }
}

private struct StoredAccountSummary: View {
    let sections: [RateLimitDisplaySection]
    let emptyLimitsSummary: String?
    let issue: CodexAccountIssuePresentation?
    let insights: CodexAccountInsights?
    let period: CodexUsagePeriod
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let issue {
                MinimalSeparator()
                CodexAccountIssueCard(issue: issue)
            }

            if sections.isEmpty {
                if let emptyLimitsSummary {
                    MinimalSeparator()
                    EmptyLimitsCard(
                        title: L10n.tr("limits.empty.title"),
                        subtitle: emptyLimitsSummary
                    )
                }
            } else {
                ForEach(sections) { section in
                    MinimalSeparator()
                    LimitSectionCard(section: section, tint: ProviderAccent.codex)
                }
            }

            if let insights {
                MinimalSeparator()
                AccountUsageSummary(insights: insights, period: period, now: now)
            }
        }
    }
}

private struct AccountUsageSummary: View {
    let insights: CodexAccountInsights
    let period: CodexUsagePeriod
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("insights.account.title"))
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("codex.insights.account-detail")

            HStack(alignment: .top, spacing: 14) {
                AccountSummaryMetric(
                    identifier: "codex.insights.account.metric.tokens",
                    title: L10n.tr("insights.metric.tokens"),
                    value: CodexInsightsTextPresentation.compactTokens(insights.totals.usage.totalTokens),
                    subtitle: accountCoverageText
                )
                Divider().frame(height: 48)
                AccountSummaryMetric(
                    identifier: "codex.insights.account.metric.credits",
                    title: L10n.tr("insights.metric.credits"),
                    value: insights.totals.credits.map { L10n.localizedDecimal($0, maximumFractionDigits: 1) } ?? "—",
                    subtitle: nil
                )
                Divider().frame(height: 48)
                AccountSummaryMetric(
                    identifier: "codex.insights.account.metric.api-equivalent",
                    title: L10n.tr("insights.metric.api_equivalent"),
                    value: insights.totals.apiEquivalentUSD.map { L10n.localizedCurrencyUSD($0) } ?? "—",
                    subtitle: insights.effectiveSubscriptionUSDPerMillionTokens.map {
                        L10n.tr("insights.metric.effective_per_million", L10n.localizedCurrencyUSD($0))
                    } ?? L10n.tr("insights.metric.effective.collecting")
                )
            }

            ModelUsageStrip(models: insights.models)
            UsageTrendChart(daily: insights.daily, period: period, now: now).frame(height: 130)
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

private struct AccountSummaryMetric: View {
    let identifier: String
    let title: String
    let value: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

private struct DetailHeroCard<StateBadge: View, Details: View, Actions: View>: View {
    let title: String
    let subtitle: String?
    let note: String?
    let metaLine: String?
    let renameTitle: ((String) -> Void)?
    let subtitleIsCopyable: Bool
    let stateBadge: StateBadge
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
        @ViewBuilder stateBadge: () -> StateBadge,
        @ViewBuilder details: () -> Details,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.note = note
        self.metaLine = metaLine
        self.renameTitle = renameTitle
        self.subtitleIsCopyable = subtitleIsCopyable
        self.stateBadge = stateBadge()
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
                            .help(L10n.tr("account.email.copy"))
                            .accessibilityHint(L10n.tr("account.email.copy"))
                            .accessibilityIdentifier("account.identity.email")
                        } else {
                            subtitleLabel(subtitle)
                        }
                    }
                }

                Spacer(minLength: 12)
                stateBadge
            }

            details

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
            .font(subtitleIsCopyable ? .callout : .title3)
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
                    .font(.title2.weight(.semibold))

                Spacer(minLength: 12)

                if let monthlyPrice = plan.monthlyPrice {
                    Text(monthlyPrice)
                        .font(.title3.weight(.semibold))
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
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .frame(width: 160, alignment: .leading)

                        if let progress = cycle.remainingProgress {
                            LimitProgressBar(progress: progress, tint: subscriptionTint(for: cycle))
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier("chatgpt.subscription.progress")
                        } else {
                            MinimalProgressTrack(fillOpacity: 0.075, strokeOpacity: 0.18)
                                .frame(height: 12)
                        }

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(cycle.countdownText)
                                .font(.title3.weight(.semibold))
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

private struct CodexAccountIssueCard: View {
    let issue: CodexAccountIssuePresentation

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: issue.recommendedAction == .reauthenticate
                  ? "person.crop.circle.badge.exclamationmark"
                  : "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title)
                    .font(.headline)
                Text(issue.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(issue.title). \(issue.message)")
        .accessibilityIdentifier("codex.account.issue")
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
