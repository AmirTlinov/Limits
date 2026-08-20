import SwiftUI
import LimitsCore

struct CLIStateBadge: View {
    let source: AppModel.CurrentCLIState.Source

    var body: some View {
        Text(presentation.text)
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(presentation.tone.color.opacity(0.16), in: Capsule())
            .foregroundStyle(presentation.tone.color)
    }

    private var presentation: ProviderBadgePresentation {
        ProviderPresentation.codexBadge(source: source)
    }
}
