import SwiftUI
import LimitsCore

struct MinimalSeparator: View {
    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.08))
            .frame(height: 1)
    }
}

struct MinimalProgressTrack: View {
    let fillOpacity: Double
    let strokeOpacity: Double
    @Environment(\.colorScheme) private var colorScheme

    init(fillOpacity: Double = 0.035, strokeOpacity: Double = 0.14) {
        self.fillOpacity = fillOpacity
        self.strokeOpacity = strokeOpacity
    }

    var body: some View {
        Capsule()
            .fill(trackFill)
            .overlay {
                Capsule()
                    .stroke(trackStroke, lineWidth: 1)
            }
    }

    private var trackFill: Color {
        colorScheme == .dark ? .white.opacity(fillOpacity * 1.35) : .black.opacity(fillOpacity)
    }

    private var trackStroke: Color {
        colorScheme == .dark ? .white.opacity(strokeOpacity * 1.25) : .black.opacity(strokeOpacity)
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
