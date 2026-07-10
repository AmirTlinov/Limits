import SwiftUI

enum ProviderAccent {
    static let codex = Color.blue
    static let claude = Color(red: 0.86, green: 0.39, blue: 0.24)
}

extension ProviderTone {
    var color: Color {
        switch self {
        case .codex:
            return ProviderAccent.codex
        case .claude:
            return ProviderAccent.claude
        case .success:
            return .green
        case .warning:
            return .orange
        case .danger:
            return .red
        case .secondary:
            return .secondary
        }
    }
}
