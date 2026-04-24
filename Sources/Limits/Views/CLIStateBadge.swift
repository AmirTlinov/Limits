import SwiftUI

struct CLIStateBadge: View {
    let source: AppModel.CurrentCLIState.Source

    var body: some View {
        Text(label)
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch source {
        case .missing:
            return L10n.tr("account.no_login")
        case .stored:
            return L10n.tr("account.active")
        case .external:
            return L10n.tr("account.current") + " CLI"
        case .unreadable:
            return L10n.tr("account.error")
        }
    }

    private var color: Color {
        switch source {
        case .missing:
            return .secondary
        case .stored:
            return ProviderAccent.codex
        case .external:
            return .secondary
        case .unreadable:
            return .red
        }
    }
}
