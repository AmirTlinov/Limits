import SwiftUI
import LimitsCore
import LimitsShared

enum ProviderAccent {
    static let codex = LimitsProviderAppearance.codex.color
    static let claude = LimitsProviderAppearance.claude.color
}

extension ProviderTone {
    var color: Color {
        switch self {
        case .codex:
            return ProviderAccent.codex
        case .claude:
            return ProviderAccent.claude
        case .warning:
            return .orange
        case .danger:
            return .red
        case .secondary:
            return .secondary
        }
    }
}
