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
                errorText: "Open Limits once"
            )
        } catch {
            return LimitsWidgetEntry(date: date, snapshot: nil, errorText: "Snapshot unavailable")
        }
    }
}

struct LimitsCurrentLimitsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: LimitsWidgetConstants.widgetKind, provider: LimitsWidgetTimelineProvider()) { entry in
            LimitsWidgetView(entry: entry)
        }
        .configurationDisplayName("Limits")
        .description("Codex and Claude limits at a glance.")
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

            HStack(alignment: .top, spacing: 10) {
                ForEach(providers.prefix(2)) { provider in
                    ProviderCard(provider: provider, stale: !provider.isFresh(at: entry.date), maxLimits: 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private func largeContent(snapshot: LimitsWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(compact: false)

            ForEach(providers.prefix(2)) { provider in
                ProviderCard(
                    provider: provider,
                    stale: !provider.isFresh(at: entry.date),
                    maxLimits: family == .systemExtraLarge ? 4 : 2
                )
            }

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
                Text("stale")
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
            Text(entry.errorText ?? "Open Limits once")
                .font(.callout.weight(.semibold))
            Text("The app will publish a safe limits snapshot for this widget.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func updatedText(snapshot: LimitsWidgetSnapshot) -> some View {
        let observedAt = snapshot.providers.compactMap(\.observedAt).max() ?? snapshot.generatedAt
        return HStack(spacing: 4) {
            Text("Updated")
            Text(observedAt, style: .time)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
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

private struct ProviderCard: View {
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

            if provider.limits.isEmpty || stale {
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
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.primary.opacity(0.06), lineWidth: 1)
        }
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

            ProgressView(value: normalizedRemaining ?? 0)
                .progressViewStyle(.linear)
                .tint(limit.remainingPercent.map { $0 <= 9 ? .red : tint } ?? .secondary)

            if let resetDate = limit.resetDate {
                HStack(spacing: 4) {
                    Text("Reset")
                    Text(resetDate, style: .time)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProviderAppearance {
    let displayTitle: String
    let shortTitle: String
    let color: Color
}

private extension LimitsWidgetProviderSnapshot {
    var appearance: ProviderAppearance {
        switch id {
        case .codex:
            ProviderAppearance(displayTitle: "Codex CLI", shortTitle: "Codex", color: .blue)
        case .claude:
            ProviderAppearance(displayTitle: "Claude Code", shortTitle: "Claude", color: Color(red: 0.86, green: 0.39, blue: 0.24))
        }
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
        if stale { return "Snapshot is stale. Open Limits to refresh." }
        switch status {
        case .available:
            return "No visible limit rows yet."
        case .unavailable:
            return note ?? "Not connected."
        case .noData:
            return note ?? "No live limit data yet."
        case .error:
            return note ?? "Cannot read limits."
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
            ]
        )
    }
}
