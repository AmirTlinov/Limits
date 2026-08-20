import AppKit
import SwiftUI
import LimitsCore
import LimitsShared

struct MenuBarContentView: View {
    @ObservedObject var model: AppModel
    let openAccountsWindow: () -> Void
    let openSettingsWindow: () -> Void
    let providerFilterDidChange: (AccountsSidebarFilter) -> Void
    let maxScrollableContentHeight: CGFloat

    @AppStorage("limits.tray.codex.expanded") private var codexExpanded = true
    @AppStorage("limits.tray.claude.expanded") private var claudeExpanded = true
    @AppStorage(AccountsSidebarFilter.providerFilterStorageKey) private var providerFilterRaw = AccountsSidebarFilter.all.rawValue

    init(
        model: AppModel,
        openAccountsWindow: @escaping () -> Void,
        openSettingsWindow: @escaping () -> Void,
        maxScrollableContentHeight: CGFloat = 420,
        providerFilterDidChange: @escaping (AccountsSidebarFilter) -> Void = { _ in }
    ) {
        self.model = model
        self.openAccountsWindow = openAccountsWindow
        self.openSettingsWindow = openSettingsWindow
        self.maxScrollableContentHeight = maxScrollableContentHeight
        self.providerFilterDidChange = providerFilterDidChange
    }

    private var codexOverview: AppModel.CurrentCLIOverview {
        model.currentCLIOverview()
    }

    private var claudeOverview: AppModel.CurrentClaudeOverview {
        model.currentClaudeOverview()
    }

    private var currentCodexRows: [RateLimitDisplayRow] {
        compactRows(from: model.currentCLIDisplayRateLimitSections())
    }

    private var currentClaudeRows: [RateLimitDisplayRow] {
        compactRows(from: model.currentClaudeLiveRateLimitSections())
    }

    private var storedCodexAccounts: [StoredAccount] {
        model.sortedCodexAccountsForSidebar().filter { !model.isCurrentCLIAccount($0) }
    }

    private var storedClaudeAccounts: [ClaudeStoredAccount] {
        model.claudeAccounts.filter { !model.isCurrentClaudeAccount($0) }
    }

    private var codexAccountCount: Int {
        (ProviderPresentation.currentCodexCountsAsAccount(model.currentCLIState.source) ? 1 : 0) + storedCodexAccounts.count
    }

    private var claudeAccountCount: Int {
        (ProviderPresentation.currentClaudeCountsAsAccount(model.currentClaudeState.source) ? 1 : 0) + storedClaudeAccounts.count
    }

    private var header: some View {
        HStack(spacing: 8) {
            panelActionButton(L10n.tr("action.open_window")) {
                openAccountsWindow()
            }

            Spacer(minLength: 0)
        }
    }

    private var shouldShowClaudeRow: Bool {
        model.providerCatalog.contains(.claude)
    }

    private var shouldScrollAccountContent: Bool {
        AccountsPresentationLogic.needsStoredAccountsScroll(
            storedCodexCount: providerFilter.includesCodex && codexExpanded ? storedCodexAccounts.count : 0,
            storedClaudeCount: providerFilter.includesClaude && claudeExpanded ? storedClaudeAccounts.count : 0
        )
    }

    private var providerFilter: AccountsSidebarFilter {
        model.providerCatalog.normalized(AccountsSidebarFilter(rawValue: providerFilterRaw) ?? .all)
    }

    private var providerFilterBinding: Binding<AccountsSidebarFilter> {
        Binding(
            get: { providerFilter },
            set: { newFilter in
                providerFilterRaw = newFilter.rawValue
                revealVisibleSections(for: newFilter)
                providerFilterDidChange(newFilter)
            }
        )
    }

    private func revealVisibleSections(for filter: AccountsSidebarFilter) {
        if filter.includesCodex {
            codexExpanded = true
        }
        if filter.includesClaude {
            claudeExpanded = true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            ProviderFilterPicker(selection: providerFilterBinding, catalog: model.providerCatalog)
                .padding(.bottom, 1)

            accountContent

            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(width: 326)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.98))
        .onChange(of: model.providerCatalog) { _, catalog in
            let normalized = catalog.normalized(providerFilter)
            providerFilterRaw = normalized.rawValue
            revealVisibleSections(for: normalized)
        }
        .onAppear {
            let normalized = model.providerCatalog.normalized(
                AccountsSidebarFilter(rawValue: providerFilterRaw) ?? .all
            )
            providerFilterRaw = normalized.rawValue
            revealVisibleSections(for: normalized)
        }
    }

    @ViewBuilder
    private var accountContent: some View {
        if shouldScrollAccountContent {
            TrayScrollView {
                accountSections
            }
            .frame(height: maxScrollableContentHeight)
        } else {
            accountSections
        }
    }

    private var accountSections: some View {
        VStack(alignment: .leading, spacing: 10) {
            if providerFilter.includesCodex {
                codexSection
            }

            if providerFilter.includesCodex, providerFilter.includesClaude, shouldShowClaudeRow {
                MinimalSeparator()
                    .opacity(0.30)
                    .padding(.horizontal, 2)
            }

            if providerFilter.includesClaude, shouldShowClaudeRow {
                claudeSection
            }
        }
        .padding(.vertical, 1)
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
                    badgeText: codexBadge.text,
                    badgeColor: codexBadge.tone.color,
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
                        accent: ProviderPresentation.statusTone(status: account.status, isCurrent: false, provider: .codex).color,
                        badgeText: nil,
                        badgeColor: .secondary,
                        style: .stored
                    ) {
                        Task { await model.activateAccount(account) }
                    }
                    .disabled(model.isProviderBusy(.codex))
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
                        badgeText: claudeBadge.text,
                        badgeColor: claudeBadge.tone.color,
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
                        accent: ProviderPresentation.statusTone(status: account.status, isCurrent: false, provider: .claude).color,
                        badgeText: nil,
                        badgeColor: .secondary,
                        style: .stored
                    ) {
                        Task { await model.activateClaudeAccount(account) }
                    }
                    .disabled(model.isProviderBusy(.claude))
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            if model.shouldOfferAddAccountAsPrimaryAction() {
                panelActionButton(L10n.tr("action.add"), primary: true) {
                    Task { await model.addAccount() }
                }
                .disabled(model.isProviderBusy(.codex))
            }

            Spacer(minLength: 0)

            Menu {
                Button(L10n.tr("action.add_account")) {
                    Task { await model.addAccount() }
                }

                if model.hasCurrentCLIAuthToImport() {
                    Button(L10n.tr("action.import_current_auth")) {
                        Task { await model.importCurrentCLIAuth() }
                    }
                }

                if model.hasCurrentClaudeAuthToImport() {
                    Button(L10n.tr("action.import_current_claude")) {
                        Task { await model.importCurrentClaudeAuth() }
                    }
                }

                if !model.accounts.isEmpty || model.currentClaudeStatus != nil {
                    Button(L10n.tr("action.refresh_current_values")) {
                        Task { await model.refreshCurrentValues() }
                    }
                }

                Divider()

                Button(L10n.tr("action.show_all")) {
                    codexExpanded = true
                    claudeExpanded = true
                }

                Button(L10n.tr("action.collapse_all")) {
                    codexExpanded = false
                    claudeExpanded = false
                }

                Divider()

                Button(L10n.tr("action.settings")) {
                    openSettingsWindow()
                }

                Divider()

                Button(L10n.tr("action.quit")) {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .menuStyle(.borderlessButton)
            .help(L10n.tr("action.more"))
            .accessibilityLabel(L10n.tr("action.more"))
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
        L10n.accountCount(count)
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

    private var codexBadge: ProviderBadgePresentation {
        ProviderPresentation.trayCodexBadge(source: model.currentCLIState.source)
    }

    private var claudeBadge: ProviderBadgePresentation {
        ProviderPresentation.trayClaudeBadge(source: model.currentClaudeState.source)
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
            return model.storedRateLimitSummary(for: account) ?? account.shortStatusText
        }
        return nil
    }

    private func storedClaudeSubtitle(for account: ClaudeStoredAccount) -> String? {
        if account.label.caseInsensitiveCompare(account.email) != .orderedSame {
            return account.email
        }

        let plan = model.localizedClaudePlan(account.subscriptionType)
        return plan == L10n.tr("plan.claude.subscription") ? nil : plan
    }

    private func updatedAtText(for date: Date?) -> String? {
        guard let date else { return nil }
        return L10n.updatedAtShort(date)
    }
}

private struct TrayScrollView<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> TrayScrollContainer<Content> {
        TrayScrollContainer(rootView: content)
    }

    func updateNSView(_ scrollView: TrayScrollContainer<Content>, context: Context) {
        scrollView.update(rootView: content)
    }
}

private final class TrayScrollContainer<Content: View>: NSScrollView {
    private let hostingView: NSHostingView<Content>

    init(rootView: Content) {
        self.hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = false
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .allowed
        horizontalScrollElasticity = .none
        documentView = hostingView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func update(rootView: Content) {
        hostingView.rootView = rootView
        needsLayout = true
    }

    override func layout() {
        super.layout()
        updateDocumentFrame()
    }

    private func updateDocumentFrame() {
        let width = max(1, contentView.bounds.width)
        hostingView.frame.size.width = width
        let fittingHeight = max(contentView.bounds.height, hostingView.fittingSize.height)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: fittingHeight)
    }
}

private struct TrayProviderSection<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                if reduceMotion {
                    isExpanded.toggle()
                } else {
                    withAnimation(.snappy(duration: 0.18)) {
                        isExpanded.toggle()
                    }
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
        case .current: 10
        case .stored: 8
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
        VStack(alignment: .leading, spacing: style == .current ? 7 : 6) {
            HStack(spacing: 9) {
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

        shape
            .fill(Color.white.opacity(style.fillOpacity))
            .overlay {
                shape.stroke(.primary.opacity(style.strokeOpacity), lineWidth: 1)
            }
    }
}
