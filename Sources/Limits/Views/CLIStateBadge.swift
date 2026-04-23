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
            return "Missing"
        case .stored:
            return "Stored"
        case .external:
            return "Drift"
        case .unreadable:
            return "Unreadable"
        }
    }

    private var color: Color {
        switch source {
        case .missing:
            return .secondary
        case .stored:
            return .blue
        case .external:
            return .orange
        case .unreadable:
            return .red
        }
    }
}
