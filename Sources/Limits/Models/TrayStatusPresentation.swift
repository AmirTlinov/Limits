import Foundation

struct TrayProviderAvailability: Equatable {
    let remainingPercent: Int?
    let availableAccounts: Int
    let totalAccounts: Int

    var hasKnownCurrentLimit: Bool {
        remainingPercent != nil
    }
}

enum TrayStatusPresentation {
    static func title(
        filter: AccountsSidebarFilter,
        codex: TrayProviderAvailability,
        claude: TrayProviderAvailability
    ) -> String {
        switch filter {
        case .codex:
            return providerTitle(name: "Codex", availability: codex)
        case .claude:
            return providerTitle(name: "Claude", availability: claude)
        case .all:
            return [
                providerTitle(name: "C", availability: codex),
                providerTitle(name: "Cl", availability: claude),
            ].joined(separator: " · ")
        }
    }

    static func providerTitle(name: String, availability: TrayProviderAvailability) -> String {
        let percent = availability.remainingPercent.map { "\($0)%" } ?? "—"
        return "\(name) \(percent) \(availability.availableAccounts)/\(availability.totalAccounts)"
    }
}
