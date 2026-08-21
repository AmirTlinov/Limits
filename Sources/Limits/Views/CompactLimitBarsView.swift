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

struct CompactSubscriptionBarView: View {
    let cycle: ChatGPTSubscriptionCyclePresentation
    var tint: Color = ProviderAccent.codex

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(L10n.tr("subscription.payment_in"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 6)

                Text(cycle.countdownText)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
            }

            if let progress = cycle.remainingProgress {
                LimitsProgressBar(progress: progress, tint: resolvedTint)
                    .frame(maxWidth: .infinity)
                    .frame(height: 7)
            } else {
                LimitsProgressBar(progress: 0, tint: .secondary)
                    .frame(height: 7)
            }

            Text(cycle.paymentDateText)
                .font(.caption2)
                .foregroundStyle(.secondary.opacity(0.78))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(L10n.tr("subscription.payment_in")): \(cycle.countdownText). \(cycle.paymentDateText)"
        )
    }

    private var resolvedTint: Color {
        if cycle.isExpired { return .red }
        if let progress = cycle.remainingProgress, progress <= 0.1 { return .orange }
        return tint
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

            LimitsProgressBar(progress: row.remainingProgressValue, tint: resolvedTint)
                .frame(maxWidth: .infinity)
                .frame(height: 5)

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

            LimitsProgressBar(progress: row.remainingProgressValue, tint: resolvedTint)
                .frame(maxWidth: .infinity)
                .frame(height: dense ? 8 : 10)

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
