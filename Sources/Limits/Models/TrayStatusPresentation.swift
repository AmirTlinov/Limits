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

enum TrayStatusPresentation {
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
        segments(filter: filter, codex: codex, claude: claude)
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
}
