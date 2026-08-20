import Foundation
import LimitsShared

public struct TrayProviderAvailability: Equatable, Sendable {
    public let remainingPercent: Int?
    public let availableAccounts: Int
    public let totalAccounts: Int

    public init(remainingPercent: Int?, availableAccounts: Int, totalAccounts: Int) {
        self.remainingPercent = remainingPercent
        self.availableAccounts = availableAccounts
        self.totalAccounts = totalAccounts
    }

    public var hasKnownCurrentLimit: Bool {
        remainingPercent != nil
    }
}

public struct TrayStatusPresentationSegment: Equatable, Sendable {
    public let provider: TrayStatusProvider
    public let metricText: String
    public let remainingPercent: Int?

    public init(provider: TrayStatusProvider, metricText: String, remainingPercent: Int?) {
        self.provider = provider
        self.metricText = metricText
        self.remainingPercent = remainingPercent
    }
}

public struct TrayStatusSnapshot: Equatable, Sendable {
    public let filter: AccountsSidebarFilter
    public let segments: [TrayStatusPresentationSegment]
    public let title: String
    public let tooltip: String
    public let accessibilityLabel: String
}

public struct TrayLimitSnapshot: Equatable, Sendable {
    public let remainingPercent: Int?
    public let resetText: String?

    public init(remainingPercent: Int?, resetText: String?) {
        self.remainingPercent = remainingPercent
        self.resetText = resetText
    }
}

public enum TrayStatusPresentation {
    public static func snapshot(
        filter: AccountsSidebarFilter,
        catalog: ProviderCatalogSnapshot,
        codex: TrayProviderAvailability,
        claude: TrayProviderAvailability,
        codexLimit: TrayLimitSnapshot,
        claudeLimit: TrayLimitSnapshot
    ) -> TrayStatusSnapshot {
        let normalizedFilter = catalog.normalized(filter)
        let segments = segments(filter: normalizedFilter, catalog: catalog, codex: codex, claude: claude)
        let visibleProviders = catalog.providers.map { $0 == .codex ? TrayStatusProvider.codex : .claude }
        return TrayStatusSnapshot(
            filter: normalizedFilter,
            segments: segments,
            title: title(segments: segments),
            tooltip: visibleProviders.map {
                tooltipText(provider: $0, limit: $0 == .codex ? codexLimit : claudeLimit, availability: $0 == .codex ? codex : claude)
            }.joined(separator: " · "),
            accessibilityLabel: visibleProviders.map {
                accessibilitySegment(provider: $0, limit: $0 == .codex ? codexLimit : claudeLimit, availability: $0 == .codex ? codex : claude)
            }.joined(separator: " · ")
        )
    }

    public static func segments(
        filter: AccountsSidebarFilter,
        catalog: ProviderCatalogSnapshot,
        codex: TrayProviderAvailability,
        claude: TrayProviderAvailability
    ) -> [TrayStatusPresentationSegment] {
        switch filter {
        case .codex:
            return [providerSegment(provider: .codex, availability: codex)]
        case .claude:
            return catalog.contains(.claude) ? [providerSegment(provider: .claude, availability: claude)] : [providerSegment(provider: .codex, availability: codex)]
        case .all:
            var result = [providerSegment(provider: .codex, availability: codex)]
            if catalog.contains(.claude) { result.append(providerSegment(provider: .claude, availability: claude)) }
            return result
        }
    }

    public static func title(
        filter: AccountsSidebarFilter,
        catalog: ProviderCatalogSnapshot,
        codex: TrayProviderAvailability,
        claude: TrayProviderAvailability
    ) -> String {
        title(segments: segments(filter: filter, catalog: catalog, codex: codex, claude: claude))
    }

    public static func title(segments: [TrayStatusPresentationSegment]) -> String {
        segments
            .map { "\($0.provider.displayTitle) \($0.metricText)" }
            .joined(separator: " · ")
    }

    public static func metricText(availability: TrayProviderAvailability) -> String {
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
