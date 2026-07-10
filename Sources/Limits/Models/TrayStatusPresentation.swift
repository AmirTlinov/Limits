import Foundation

struct TrayProviderAvailability: Equatable {
    let remainingPercent: Int?
    let availableAccounts: Int
    let totalAccounts: Int

    var hasKnownCurrentLimit: Bool {
        remainingPercent != nil
    }
}

struct TrayStatusPresentationSegment: Equatable {
    let provider: TrayStatusProvider
    let metricText: String
    let remainingPercent: Int?
}

struct TrayStatusSnapshot: Equatable {
    let filter: AccountsSidebarFilter
    let segments: [TrayStatusPresentationSegment]
    let title: String
    let tooltip: String
    let accessibilityLabel: String
}

struct TrayLimitSnapshot: Equatable {
    let remainingPercent: Int?
    let resetText: String?
}

enum TrayStatusPresentation {
    static func snapshot(
        filter: AccountsSidebarFilter,
        codex: TrayProviderAvailability,
        claude: TrayProviderAvailability,
        codexLimit: TrayLimitSnapshot,
        claudeLimit: TrayLimitSnapshot
    ) -> TrayStatusSnapshot {
        let segments = segments(filter: filter, codex: codex, claude: claude)
        return TrayStatusSnapshot(
            filter: filter,
            segments: segments,
            title: title(segments: segments),
            tooltip: [
                tooltipText(provider: .codex, limit: codexLimit, availability: codex),
                tooltipText(provider: .claude, limit: claudeLimit, availability: claude),
            ].joined(separator: " · "),
            accessibilityLabel: [
                accessibilitySegment(provider: .codex, limit: codexLimit, availability: codex),
                accessibilitySegment(provider: .claude, limit: claudeLimit, availability: claude),
            ].joined(separator: " · ")
        )
    }

    static func segments(
        filter: AccountsSidebarFilter,
        codex: TrayProviderAvailability,
        claude: TrayProviderAvailability
    ) -> [TrayStatusPresentationSegment] {
        switch filter {
        case .codex:
            return [providerSegment(provider: .codex, availability: codex)]
        case .claude:
            return [providerSegment(provider: .claude, availability: claude)]
        case .all:
            return [
                providerSegment(provider: .codex, availability: codex),
                providerSegment(provider: .claude, availability: claude),
            ]
        }
    }

    static func title(
        filter: AccountsSidebarFilter,
        codex: TrayProviderAvailability,
        claude: TrayProviderAvailability
    ) -> String {
        title(segments: segments(filter: filter, codex: codex, claude: claude))
    }

    static func title(segments: [TrayStatusPresentationSegment]) -> String {
        segments
            .map { "\($0.provider.displayTitle) \($0.metricText)" }
            .joined(separator: " · ")
    }

    static func metricText(availability: TrayProviderAvailability) -> String {
        let percent = availability.remainingPercent.map { "\($0)%" } ?? "—"
        return "\(percent) \(availability.availableAccounts)/\(availability.totalAccounts)"
    }

    private static func providerSegment(provider: TrayStatusProvider, availability: TrayProviderAvailability) -> TrayStatusPresentationSegment {
        TrayStatusPresentationSegment(
            provider: provider,
            metricText: metricText(availability: availability),
            remainingPercent: availability.remainingPercent
        )
    }

    private static func tooltipText(provider: TrayStatusProvider, limit: TrayLimitSnapshot, availability: TrayProviderAvailability) -> String {
        var tooltip: String
        if let remainingPercent = limit.remainingPercent {
            tooltip = L10n.tr("tray.tooltip.five_hour", provider.displayTitle, remainingPercent)
            if let resetText = limit.resetText {
                tooltip += " · \(resetText)"
            }
        } else {
            tooltip = L10n.tr("tray.tooltip.five_hour.no_data", provider.displayTitle)
        }
        tooltip += " · \(L10n.limitAvailability(available: availability.availableAccounts, total: availability.totalAccounts))"
        return tooltip
    }

    private static func accessibilitySegment(provider: TrayStatusProvider, limit: TrayLimitSnapshot, availability: TrayProviderAvailability) -> String {
        let base: String = if let remainingPercent = limit.remainingPercent {
            L10n.tr("tray.accessibility.five_hour", provider.displayTitle, remainingPercent)
        } else {
            L10n.tr("tray.accessibility.five_hour.no_data", provider.displayTitle)
        }
        return "\(base), \(L10n.limitAvailability(available: availability.availableAccounts, total: availability.totalAccounts))"
    }
}
