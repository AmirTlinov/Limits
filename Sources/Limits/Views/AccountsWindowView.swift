import AppKit
import SwiftUI

private enum AccountsSidebarSelection: Hashable {
    case currentCLI
    case account(UUID)

    var rawValue: String {
        switch self {
        case .currentCLI:
            return "current-cli"
        case .account(let id):
            return "account:\(id.uuidString)"
        }
    }

    init?(rawValue: String) {
        if rawValue == "current-cli" {
            self = .currentCLI
            return
        }

        guard rawValue.hasPrefix("account:") else {
            return nil
        }

        let value = String(rawValue.dropFirst("account:".count))
        guard let id = UUID(uuidString: value) else {
            return nil
        }
        self = .account(id)
    }
}

struct AccountsWindowView: View {
    @ObservedObject var model: AppModel
    @SceneStorage("limits.accounts.selection") private var sidebarSelectionRaw = AccountsSidebarSelection.currentCLI.rawValue

    private var overview: AppModel.CurrentCLIOverview {
        model.currentCLIOverview()
    }

    private var selectionBinding: Binding<AccountsSidebarSelection?> {
        Binding(
            get: { AccountsSidebarSelection(rawValue: sidebarSelectionRaw) ?? .currentCLI },
            set: { sidebarSelectionRaw = ($0 ?? .currentCLI).rawValue }
        )
    }

    private var selectedAccount: StoredAccount? {
        guard case .account(let id) = selectionBinding.wrappedValue else {
            return nil
        }
        return model.accounts.first(where: { $0.id == id })
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
                .help("Добавить аккаунт")
                .disabled(model.isBusy)

                if model.hasCurrentCLIAuthToImport() {
                    Button {
                        Task { await model.importCurrentCLIAuth() }
                    } label: {
                        Image(systemName: "arrow.down.doc")
                    }
                    .help("Импортировать текущую авторизацию")
                    .disabled(model.isBusy)
                }

                Button {
                    Task { await model.validateAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Обновить")
                .disabled(model.isBusy)
            }
        }
        .background(WindowChromeConfigurator())
        .frame(minWidth: 980, minHeight: 620)
        .onAppear {
            ensureValidSelection()
            Task { await model.refreshCurrentCLIPanel(forceProbe: false) }
        }
        .onChange(of: model.accounts) { _, _ in
            ensureValidSelection()
        }
    }

    private var sidebar: some View {
        List(selection: selectionBinding) {
            Section {
                SidebarRowView(
                    icon: "terminal",
                    title: "Текущий CLI",
                    subtitle: overview.title,
                    trailing: currentCLITrailingText,
                    accent: .blue
                )
                .tag(AccountsSidebarSelection.currentCLI)
            }

            Section("Аккаунты") {
                ForEach(model.accounts) { account in
                    SidebarRowView(
                        icon: "person.crop.circle",
                        title: account.label,
                        subtitle: nil,
                        trailing: sidebarTrailing(for: account),
                        accent: sidebarAccent(for: account)
                    )
                    .tag(AccountsSidebarSelection.account(account.id))
                    .contextMenu {
                        if !model.isCurrentCLIAccount(account) {
                            Button("Сделать текущим") {
                                Task { await model.activateAccount(account) }
                            }
                        }

                        Button("Обновить") {
                            Task { await model.validateAccount(account) }
                        }

                        Button("Повторный вход") {
                            Task { await model.reauthenticateAccount(account) }
                        }

                        Divider()

                        Button("Удалить аккаунт", role: .destructive) {
                            Task { await model.deleteAccount(account) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
    }

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let selectedAccount {
                    StoredAccountDetailPane(model: model, account: selectedAccount)
                } else {
                    CurrentCLIDetailPane(model: model)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(DetailPaneBackground())
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

    private func sidebarTrailing(for account: StoredAccount) -> String? {
        if let used = account.lastRateLimit?.primary?.usedPercent {
            return "\(max(0, 100 - used))%"
        }
        return nil
    }

    private func sidebarAccent(for account: StoredAccount) -> Color {
        if model.isCurrentCLIAccount(account) {
            return .blue
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

    private func ensureValidSelection() {
        guard let selection = AccountsSidebarSelection(rawValue: sidebarSelectionRaw) else {
            sidebarSelectionRaw = AccountsSidebarSelection.currentCLI.rawValue
            return
        }

        if case .account(let id) = selection, !model.accounts.contains(where: { $0.id == id }) {
            sidebarSelectionRaw = AccountsSidebarSelection.currentCLI.rawValue
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
                        Button("Импортировать текущую авторизацию") {
                            Task { await model.importCurrentCLIAuth() }
                        }
                        .heroActionStyle(primary: true)
                        .disabled(model.isBusy)
                    } else if model.shouldOfferAddAccountAsPrimaryAction() {
                        Button("Добавить аккаунт") {
                            Task { await model.addAccount() }
                        }
                        .heroActionStyle(primary: true)
                        .disabled(model.isBusy)
                    }

                    Button("Обновить") {
                        Task { await model.refreshCurrentCLIPanel(forceProbe: true) }
                    }
                    .heroActionStyle()
                    .disabled(model.isBusy)
                }
            )

            if let errorMessage = model.errorMessage {
                MinimalSeparator()
                InlineWarningCard(text: errorMessage)
            }

            if sections.isEmpty {
                MinimalSeparator()
                EmptyLimitsCard(
                    title: "Лимиты пока не загружены",
                    subtitle: overview.note ?? "Проверьте авторизацию или обновите данные."
                )
            } else {
                MinimalSeparator()
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    LimitSectionCard(section: section)

                    if index < sections.count - 1 {
                        MinimalSeparator()
                    }
                }
            }
        }
    }

    private var currentCLIMetaLine: String? {
        if let date = model.currentCLIValidatedAt() {
            return "Обновлено \(formatted(date: date))"
        }
        if model.isRefreshingCurrentCLIProbe {
            return "Обновляю живые лимиты…"
        }
        return nil
    }

    private func formatted(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
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
                        Button("Сделать текущим") {
                            Task { await model.activateAccount(account) }
                        }
                        .heroActionStyle(primary: true)
                        .disabled(model.isBusy)
                    }

                    Button("Обновить") {
                        Task { await model.validateAccount(account) }
                    }
                    .heroActionStyle()
                    .disabled(model.isBusy)

                    Button("Повторный вход") {
                        Task { await model.reauthenticateAccount(account) }
                    }
                    .heroActionStyle()
                    .disabled(model.isBusy)

                    Button("Удалить", role: .destructive) {
                        Task { await model.deleteAccount(account) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
                }
            )

            if sections.isEmpty {
                MinimalSeparator()
                EmptyLimitsCard(
                    title: "Лимиты пока не загружены",
                    subtitle: "Нажмите «Обновить», чтобы получить актуальные данные по этому аккаунту."
                )
            } else {
                MinimalSeparator()
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    LimitSectionCard(section: section)

                    if index < sections.count - 1 {
                        MinimalSeparator()
                    }
                }
            }
        }
    }

    private var accountNote: String? {
        if isCurrent, model.currentCLIProbe != nil {
            return "Показаны живые лимиты текущего CLI."
        }
        return account.statusMessage
    }

    private var accountMetaLine: String? {
        var parts: [String] = []

        if isCurrent {
            parts.append("Текущий CLI")
        }

        parts.append(model.localizedPlan(account.planType))

        if let date = account.lastValidatedAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            parts.append("Проверено \(formatter.string(from: date))")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct DetailPaneBackground: View {
    var body: some View {
        Color.clear
            .glassPanelSurface(
                in: Rectangle(),
                tone: .regular,
                fallbackMaterial: .ultraThinMaterial
            )
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(section.title)
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 14) {
                ForEach(section.rows) { row in
                    LimitProgressRowView(row: row)
                }
            }
        }
    }
}

private struct LimitProgressRowView: View {
    let row: RateLimitDisplayRow

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow(alignment: .center) {
                Text(row.title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(width: 160, alignment: .leading)

                LimitProgressBar(progress: row.remainingProgressValue, tint: tint)
                    .frame(maxWidth: .infinity)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(row.remainingPercent)% осталось")
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

    private var tint: Color {
        switch row.remainingPercent {
        case 0...9:
            return .red
        case 10...24:
            return .orange
        default:
            return .blue
        }
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

private extension View {
    @ViewBuilder
    func heroActionStyle(primary: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if primary {
                self
                    .buttonStyle(.glass)
                    .buttonBorderShape(.roundedRectangle(radius: 14))
                    .tint(.accentColor)
            } else {
                self
                    .buttonStyle(.glass)
                    .buttonBorderShape(.roundedRectangle(radius: 14))
            }
        } else {
            if primary {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }
}

private struct AccountStatusBadge: View {
    let status: AccountStatus
    let isCurrent: Bool

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
            return "Текущий"
        }
        return switch status {
        case .ok: "Готов"
        case .limitReached: "Лимит"
        case .needsReauth: "Нужен вход"
        case .validationFailed: "Ошибка"
        case .unknown: "Неизвестно"
        }
    }

    private var color: Color {
        if isCurrent {
            return .blue
        }
        return switch status {
        case .ok: .green
        case .limitReached: .orange
        case .needsReauth, .validationFailed: .red
        case .unknown: .secondary
        }
    }
}
