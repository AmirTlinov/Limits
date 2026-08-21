import Foundation
import LimitsShared
import SwiftUI
import WidgetKit

struct LimitsWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: LimitsWidgetSnapshot?
    let errorText: String?
}

struct LimitsWidgetTimelineProvider: TimelineProvider {
    private let store = LimitsWidgetSnapshotStore()

    func placeholder(in context: Context) -> LimitsWidgetEntry {
        LimitsWidgetEntry(
            date: .now,
            snapshot: LimitsWidgetSnapshot.demo(generatedAt: .now),
            errorText: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (LimitsWidgetEntry) -> Void) {
        completion(loadEntry(date: .now, allowDemo: context.isPreview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LimitsWidgetEntry>) -> Void) {
        let now = Date()
        let entry = loadEntry(date: now, allowDemo: false)
        let nextExpiry = entry.snapshot?.providers
            .compactMap(\.freshUntil)
            .filter { $0 > now }
            .min()
        let regularReload = now.addingTimeInterval(300)
        let reloadDate = min(regularReload, nextExpiry?.addingTimeInterval(1) ?? regularReload)
        completion(Timeline(entries: [entry], policy: .after(reloadDate)))
    }

    private func loadEntry(date: Date, allowDemo: Bool) -> LimitsWidgetEntry {
        do {
            if let snapshot = try store.readSnapshot() {
                return LimitsWidgetEntry(date: date, snapshot: snapshot, errorText: nil)
            }

            return LimitsWidgetEntry(
                date: date,
                snapshot: allowDemo ? LimitsWidgetSnapshot.demo(generatedAt: date) : nil,
                errorText: L10n.tr("widget.open_once")
            )
        } catch {
            return LimitsWidgetEntry(date: date, snapshot: nil, errorText: L10n.tr("widget.snapshot_unavailable"))
        }
    }
}

struct LimitsCurrentLimitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: LimitsWidgetConstants.widgetKind, provider: LimitsWidgetTimelineProvider()) { entry in
            LimitsWidgetView(entry: entry)
        }
        .configurationDisplayName("Limits")
        .description(L10n.tr("widget.description"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

@main
struct LimitsWidgetBundle: WidgetBundle {
    var body: some Widget {
        LimitsCurrentLimitsWidget()
    }
}

private struct LimitsWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: LimitsWidgetEntry

    private var providers: [LimitsWidgetProviderSnapshot] {
        guard let snapshot = entry.snapshot else { return [] }
        return LimitsWidgetProviderID.allCases.compactMap { snapshot.provider($0) }
    }

    private var allProvidersAreStale: Bool {
        !providers.contains { $0.isFresh(at: entry.date) }
    }

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                content(snapshot: snapshot)
            } else {
                emptyState
            }
        }
        .widgetURL(LimitsWidgetConstants.openURL)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color(nsColor: .controlBackgroundColor)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    @ViewBuilder
    private func content(snapshot: LimitsWidgetSnapshot) -> some View {
        switch family {
        case .systemSmall:
            smallContent(snapshot: snapshot)
        case .systemMedium:
            mediumContent(snapshot: snapshot)
        case .systemLarge, .systemExtraLarge:
            largeContent(snapshot: snapshot)
        default:
            mediumContent(snapshot: snapshot)
        }
    }

    private func smallContent(snapshot: LimitsWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(compact: true)

            ForEach(providers.prefix(2)) { provider in
                ProviderCompactLine(provider: provider, stale: !provider.isFresh(at: entry.date))
            }

            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private func mediumContent(snapshot: LimitsWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(compact: false)

            Divider()

            ProviderSummaryColumns(
                providers: Array(providers.prefix(2)),
                now: entry.date,
                maxLimits: 2
            )

            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private func largeContent(snapshot: LimitsWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(compact: false)

            if let analytics = snapshot.codexAnalytics {
                Divider()
                WidgetCodexAnalyticsSummary(
                    summary: analytics,
                    now: entry.date,
                    stale: analytics.forecastState == .stale || (
                        analytics.forecastObservedAt != nil
                            && !LimitsFreshnessPolicy.isFresh(
                                observedAt: analytics.forecastObservedAt,
                                at: entry.date
                            )
                    )
                )
            }

            Divider()

            ProviderSummaryColumns(
                providers: Array(providers.prefix(2)),
                now: entry.date,
                maxLimits: family == .systemExtraLarge ? 3 : 2
            )

            Spacer(minLength: 0)
            updatedText(snapshot: snapshot)
        }
        .padding(16)
    }

    private func header(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: compact ? 14 : 16, weight: .semibold))
                .foregroundStyle(.blue)
            Text("Limits")
                .font(compact ? .headline : .title3.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            if allProvidersAreStale {
                Text(L10n.tr("widget.stale"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.12), in: Capsule())
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            header(compact: false)
            Text(entry.errorText ?? L10n.tr("widget.open_once"))
                .font(.callout.weight(.semibold))
            Text(L10n.tr("widget.empty_explanation"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func updatedText(snapshot: LimitsWidgetSnapshot) -> some View {
        let observedAt = snapshot.providers.compactMap(\.observedAt).max() ?? snapshot.generatedAt
        return HStack(spacing: 4) {
            Text(L10n.tr("widget.updated"))
            Text(L10n.shortTime(observedAt))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

private struct WidgetCodexAnalyticsSummary: View {
    let summary: CodexAnalyticsSummary
    let now: Date
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.accountLabel ?? L10n.tr("insights.overview.title"))
                        .font(.headline)
                        .lineLimit(1)
                    let detail = [summary.quotaTitle, summary.planTitle].compactMap { $0 }.joined(separator: " · ")
                    if !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(stale ? L10n.tr("insights.forecast.stale") : forecastText)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(forecastColor)
                    .lineLimit(1)
            }

            LimitsProgressBar(
                progress: stale ? 0 : Double(summary.remainingPercent ?? 0) / 100,
                tint: forecastColor
            )

            HStack(spacing: 12) {
                WidgetAnalyticsMetric(
                    title: L10n.tr("insights.metric.tokens"),
                    value: compactTokens(summary.weeklyTokens)
                )
                Divider().frame(height: 24)
                WidgetAnalyticsMetric(
                    title: L10n.tr("insights.metric.credits"),
                    value: summary.weeklyCredits.map { L10n.localizedDecimal($0, maximumFractionDigits: 1) } ?? "—"
                )
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var forecastText: String {
        switch summary.forecastState {
        case .collecting: L10n.tr("insights.forecast.collecting")
        case .stale: L10n.tr("insights.forecast.stale")
        case .lastsUntilReset: L10n.tr("insights.forecast.lasts")
        case .exhaustsBeforeReset:
            if let exhaustion = summary.predictedExhaustionAt,
               let countdown = L10n.countdown(until: Int64(exhaustion.timeIntervalSince1970), now: now) {
                L10n.tr("insights.forecast.exhausts_in", countdown)
            } else {
                L10n.tr("insights.forecast.exhausted")
            }
        @unknown default:
            L10n.tr("insights.forecast.collecting")
        }
    }

    private var forecastColor: Color {
        if stale { return .secondary }
        return summary.forecastState == .exhaustsBeforeReset ? .orange : .blue
    }

    private func compactTokens(_ tokens: Int64) -> String {
        if tokens >= 1_000_000 {
            return "\(L10n.localizedDecimal(Decimal(tokens) / 1_000_000, maximumFractionDigits: 1))\(L10n.tr("insights.tokens.millions_suffix"))"
        }
        if tokens >= 1_000 {
            return "\(L10n.localizedDecimal(Decimal(tokens) / 1_000, maximumFractionDigits: 1))\(L10n.tr("insights.tokens.thousands_suffix"))"
        }
        return L10n.localizedInteger(tokens)
    }
}

private struct WidgetAnalyticsMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
    }
}

private struct ProviderCompactLine: View {
    let provider: LimitsWidgetProviderSnapshot
    let stale: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(provider.appearance.color)
                .frame(width: 7, height: 7)
            Text(provider.appearance.shortTitle)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(provider.primaryPercentText(stale: stale))
                .font(.system(.callout, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(provider.primaryPercentColor(stale: stale))
        }
    }
}

private struct ProviderSummaryColumns: View {
    let providers: [LimitsWidgetProviderSnapshot]
    let now: Date
    let maxLimits: Int

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let first = providers.first {
                ProviderSummaryColumn(
                    provider: first,
                    stale: !first.isFresh(at: now),
                    maxLimits: maxLimits
                )
            }

            if providers.count > 1 {
                Divider()
                ProviderSummaryColumn(
                    provider: providers[1],
                    stale: !providers[1].isFresh(at: now),
                    maxLimits: maxLimits
                )
            }
        }
    }
}

private struct ProviderSummaryColumn: View {
    let provider: LimitsWidgetProviderSnapshot
    let stale: Bool
    let maxLimits: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(provider.appearance.color)
                    .frame(width: 8, height: 8)
                Text(provider.appearance.displayTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(provider.primaryPercentText(stale: stale))
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(provider.primaryPercentColor(stale: stale))
            }

            Text(provider.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)

            if provider.status != .available || provider.limits.isEmpty || stale {
                Text(provider.statusText(stale: stale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                ForEach(provider.limits.prefix(maxLimits)) { limit in
                    LimitBarRow(limit: limit, tint: provider.appearance.color)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct LimitBarRow: View {
    let limit: LimitsWidgetLimitSnapshot
    let tint: Color

    private var normalizedRemaining: Double? {
        guard let remainingPercent = limit.remainingPercent else { return nil }
        return min(max(Double(remainingPercent) / 100, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(limit.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let remainingPercent = limit.remainingPercent {
                    Text("\(remainingPercent)%")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                } else {
                    Text("—")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            LimitsProgressBar(
                progress: normalizedRemaining ?? 0,
                tint: limit.remainingPercent.map { $0 <= 9 ? .red : tint } ?? .secondary
            )

            if let resetDate = limit.resetDate {
                HStack(spacing: 4) {
                    Text(L10n.tr("widget.reset"))
                    Text(L10n.shortTime(resetDate))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private extension LimitsWidgetProviderSnapshot {
    var appearance: LimitsProviderAppearance {
        id.appearance
    }

    func primaryPercentText(stale: Bool) -> String {
        if stale { return "—" }
        guard let percent = primaryLimit?.remainingPercent else { return "—" }
        return "\(percent)%"
    }

    func primaryPercentColor(stale: Bool) -> Color {
        guard !stale, let percent = primaryLimit?.remainingPercent else { return .secondary }
        return percent <= 9 ? .red : appearance.color
    }

    func statusText(stale: Bool) -> String {
        if stale { return L10n.tr("widget.status.stale") }
        switch status {
        case .available:
            return L10n.tr("widget.status.no_rows")
        case .unavailable:
            return note ?? L10n.tr("widget.status.not_connected")
        case .noData:
            return note ?? L10n.tr("widget.status.no_data")
        case .error:
            return note ?? L10n.tr("widget.status.error")
        @unknown default:
            return note ?? L10n.tr("widget.status.no_data")
        }
    }

    private var primaryLimit: LimitsWidgetLimitSnapshot? {
        limits.first { $0.id.contains("five") || $0.title.localizedCaseInsensitiveContains("5") } ?? limits.first
    }
}

private extension LimitsWidgetSnapshot {
    static func demo(generatedAt: Date) -> LimitsWidgetSnapshot {
        LimitsWidgetSnapshot(
            generatedAt: generatedAt,
            providers: [
                LimitsWidgetProviderSnapshot(
                    id: .codex,
                    title: "Codex Pro",
                    subtitle: "Demo account",
                    status: .available,
                    limits: [
                        LimitsWidgetLimitSnapshot(id: "codex.five_hour", title: "5h", remainingPercent: 64, resetDate: generatedAt.addingTimeInterval(3_600)),
                        LimitsWidgetLimitSnapshot(id: "codex.weekly", title: "Weekly", remainingPercent: 81, resetDate: generatedAt.addingTimeInterval(86_400)),
                    ],
                    observedAt: generatedAt,
                    freshUntil: generatedAt.addingTimeInterval(LimitsFreshnessPolicy.defaultTTL),
                    note: nil
                ),
                LimitsWidgetProviderSnapshot(
                    id: .claude,
                    title: "Claude Max",
                    subtitle: "Demo account",
                    status: .available,
                    limits: [
                        LimitsWidgetLimitSnapshot(id: "claude.five_hour", title: "5h", remainingPercent: 42, resetDate: generatedAt.addingTimeInterval(2_400)),
                        LimitsWidgetLimitSnapshot(id: "claude.weekly", title: "Weekly", remainingPercent: 73, resetDate: generatedAt.addingTimeInterval(72_000)),
                    ],
                    observedAt: generatedAt,
                    freshUntil: generatedAt.addingTimeInterval(LimitsFreshnessPolicy.defaultTTL),
                    note: nil
                ),
            ],
            codexAnalytics: CodexAnalyticsSummary(
                accountLabel: "Demo account",
                planTitle: "ChatGPT Pro 20×",
                quotaTitle: "GPT-5.3-Codex-Spark",
                forecastState: .lastsUntilReset,
                predictedExhaustionAt: nil,
                resetAt: generatedAt.addingTimeInterval(86_400),
                remainingPercent: 81,
                forecastObservedAt: generatedAt,
                weeklyTokens: 12_400_000,
                weeklyCredits: 482
            )
        )
    }
}
