import SwiftUI

public struct LimitsProviderAppearance: Sendable {
    public let displayTitle: String
    public let shortTitle: String
    public let color: Color

    public static let codex = LimitsProviderAppearance(
        displayTitle: "Codex",
        shortTitle: "Codex",
        color: .blue
    )

    public static let claude = LimitsProviderAppearance(
        displayTitle: "Claude Code",
        shortTitle: "Claude",
        color: Color(red: 0.86, green: 0.39, blue: 0.24)
    )
}

public extension LimitsWidgetProviderID {
    var appearance: LimitsProviderAppearance {
        switch self {
        case .codex: .codex
        case .claude: .claude
        }
    }
}
