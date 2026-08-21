import SwiftUI
import LimitsCore

struct MinimalSeparator: View {
    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.08))
            .frame(height: 1)
    }
}

struct ProviderStatusBadge: View {
    enum Density {
        case compact
        case regular
    }

    let presentation: ProviderBadgePresentation
    var density: Density = .regular

    var body: some View {
        Text(presentation.text)
            .font(density == .compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
            .padding(.horizontal, density == .compact ? 7 : 9)
            .padding(.vertical, density == .compact ? 3 : 4)
            .background(presentation.tone.color.opacity(0.12), in: Capsule())
            .foregroundStyle(presentation.tone.color)
    }
}
