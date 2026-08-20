import SwiftUI
import LimitsCore
import LimitsShared

struct CompactLimitBarsView: View {
    let rows: [RateLimitDisplayRow]
    var dense = false
    var tint: Color = ProviderAccent.codex

    var body: some View {
        if dense {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(rows.prefix(2))) { row in
                    CompactLimitMetricTile(row: row, tint: tint)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(rows.prefix(2))) { row in
                    CompactLimitBarRow(row: row, dense: dense, tint: tint)
                }
            }
        }
    }
}

private struct CompactLimitMetricTile: View {
    let row: RateLimitDisplayRow
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(compactLimitTitle(for: row.title))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("\(row.remainingPercent)%")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
            }

            CompactLimitBar(progress: row.remainingProgressValue, tint: resolvedTint, height: 5)
                .frame(maxWidth: .infinity)

            if let resetText = row.compactResetText() {
                Text(resetText)
                    .font(.caption2)
                    .foregroundStyle(row.isResetStale() ? Color.orange : Color.secondary.opacity(0.70))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resolvedTint: Color {
        row.remainingPercent <= 9 ? .red : tint
    }
}

private struct CompactLimitBarRow: View {
    let row: RateLimitDisplayRow
    let dense: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: dense ? 6 : 8) {
            Text(compactTitle)
                .font(dense ? .caption : .caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: dense ? 46 : 56, alignment: .leading)

            CompactLimitBar(progress: row.remainingProgressValue, tint: resolvedTint, height: dense ? 8 : 10)
                .frame(maxWidth: .infinity)

            VStack(alignment: .trailing, spacing: dense ? 0 : 1) {
                Text("\(row.remainingPercent)%")
                    .font(dense ? .caption.weight(.semibold) : .caption.weight(.bold))
                    .monospacedDigit()

                if let resetText = row.compactResetText() {
                    Text(resetText)
                        .font(.caption2)
                        .foregroundStyle(row.isResetStale() ? Color.orange : Color.secondary.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            }
            .frame(width: dense ? 76 : 92, alignment: .trailing)
        }
    }

    private var compactTitle: String {
        compactLimitTitle(for: row.title)
    }

    private var resolvedTint: Color {
        row.remainingPercent <= 9 ? .red : tint
    }
}

private func compactLimitTitle(for title: String) -> String {
    switch title {
    case L10n.tr("limit.five_hour"):
        return L10n.windowLabel(minutes: 300, fallback: title)
    case L10n.tr("limit.weekly"):
        return L10n.tr("duration.week")
    case L10n.tr("limit.one_hour"):
        return L10n.windowLabel(minutes: 60, fallback: title)
    case L10n.tr("limit.daily"):
        return L10n.windowLabel(minutes: 1440, fallback: title)
    default:
        return title
            .replacingOccurrences(of: L10n.tr("limit.generic"), with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

private struct CompactLimitBar: View {
    let progress: Double
    let tint: Color
    let height: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedProgress: Double?

    var body: some View {
        GeometryReader { geometry in
            let lineHeight = min(height, height <= 5 ? 3 : 4)
            let progress = visibleProgress
            let fillWidth = progress == 0 ? 0 : max(lineHeight * 1.8, geometry.size.width * progress)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)
                    .frame(height: lineHeight)

                Capsule()
                    .fill(tint.opacity(colorScheme == .dark ? 0.82 : 0.74))
                    .frame(width: min(geometry.size.width, fillWidth), height: lineHeight)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: height)
        .onAppear {
            updateDisplayedProgress(progress, animated: !reduceMotion)
        }
        .onChange(of: progress) { _, newProgress in
            updateDisplayedProgress(newProgress, animated: !reduceMotion)
        }
    }

    private var trackColor: Color {
        colorScheme == .dark ? .white.opacity(0.16) : .black.opacity(0.12)
    }

    private var visibleProgress: Double {
        displayedProgress ?? (reduceMotion ? clampedProgress(progress) : 0)
    }

    private func updateDisplayedProgress(_ progress: Double, animated: Bool) {
        let progress = clampedProgress(progress)
        guard animated else {
            displayedProgress = progress
            return
        }

        if displayedProgress == nil {
            displayedProgress = 0
        }

        withAnimation(.easeOut(duration: 0.14)) {
            displayedProgress = progress
        }
    }

    private func clampedProgress(_ progress: Double) -> Double {
        min(max(progress, 0), 1)
    }
}
