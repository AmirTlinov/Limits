import Charts
import SwiftUI
import LimitsCore
import LimitsShared

struct UsageTrendChart: View {
    let daily: [CodexDailyUsage]
    let period: CodexUsagePeriod
    let now: Date
    @State private var selectedDate: Date?

    private var selected: CodexDailyUsage? {
        guard let selectedDate else { return nil }
        return chartDaily.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    private var rangeText: String? {
        L10n.tr("insights.activity.range", L10n.shortDate(displayStart), L10n.shortDate(displayEnd))
    }

    private var calendar: Calendar { CodexUsageWindow.utcCalendar }
    private var displayEnd: Date { calendar.startOfDay(for: now) }
    private var displayStart: Date {
        switch period {
        case .currentWeek:
            calendar.date(byAdding: .day, value: -6, to: displayEnd) ?? displayEnd
        case .last30Days:
            calendar.date(byAdding: .day, value: -29, to: displayEnd) ?? displayEnd
        case .all:
            daily.first.map { calendar.startOfDay(for: $0.date) } ?? displayEnd
        }
    }
    private var chartDaily: [CodexDailyUsage] {
        let totalsByDay = Dictionary(uniqueKeysWithValues: daily.map {
            (calendar.startOfDay(for: $0.date), $0.totals)
        })
        var date = displayStart
        var result: [CodexDailyUsage] = []
        while date <= displayEnd {
            result.append(
                CodexDailyUsage(
                    date: date,
                    totals: totalsByDay[date]
                        ?? CodexUsageTotals(usage: .zero, credits: nil, apiEquivalentUSD: nil)
                )
            )
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? displayEnd.addingTimeInterval(1)
        }
        return result
    }
    private var chartDomain: ClosedRange<Date> {
        let lower = displayStart.addingTimeInterval(-12 * 60 * 60)
        let upper = displayEnd.addingTimeInterval(12 * 60 * 60)
        return lower...upper
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.tr("insights.trend.title")).font(.caption.weight(.semibold))
                    if let rangeText {
                        Text(rangeText).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let selected {
                    Text(
                        L10n.tr(
                            "insights.trend.selection",
                            L10n.shortDayTime(selected.date),
                            CodexInsightsTextPresentation.compactTokens(selected.totals.usage.totalTokens),
                            selected.totals.credits.map { L10n.localizedDecimal($0, maximumFractionDigits: 1) } ?? "—"
                        )
                    )
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Chart(chartDaily) { day in
                BarMark(
                    x: .value(L10n.tr("insights.chart.date"), day.date, unit: .day),
                    y: .value(L10n.tr("insights.chart.tokens"), day.totals.usage.totalTokens),
                    width: .ratio(0.64)
                )
                .foregroundStyle(ProviderAccent.codex.opacity(0.82))
                .cornerRadius(2)
            }
            .chartXScale(domain: chartDomain)
            .chartXAxis {
                if chartDaily.count > 62 {
                    AxisMarks(values: .stride(by: .month)) { value in
                        AxisGridLine().foregroundStyle(.quaternary.opacity(0.6))
                        AxisValueLabel {
                            if let date = value.as(Date.self) { Text(L10n.shortMonth(date)) }
                        }
                        .font(.caption2)
                    }
                } else {
                    AxisMarks(values: .automatic(desiredCount: min(7, max(2, chartDaily.count)))) { value in
                        AxisGridLine().foregroundStyle(.quaternary.opacity(0.6))
                        AxisValueLabel {
                            if let date = value.as(Date.self) { Text(L10n.shortDate(date)) }
                        }
                        .font(.caption2)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let tokens = value.as(Int64.self) {
                            Text(CodexInsightsTextPresentation.compactTokens(tokens))
                        } else if let tokens = value.as(Double.self) {
                            Text(CodexInsightsTextPresentation.compactTokens(Int64(tokens)))
                        }
                    }
                    .font(.caption2)
                }
            }
            .chartXSelection(value: $selectedDate)
            .accessibilityRepresentation {
                VStack(alignment: .leading) {
                    Text(L10n.tr("insights.trend.accessibility_summary", daily.count))
                    ForEach(daily) { day in
                        Text(
                            L10n.tr(
                                "insights.trend.accessibility_row",
                                L10n.shortDayTime(day.date),
                                CodexInsightsTextPresentation.compactTokens(day.totals.usage.totalTokens),
                                day.totals.credits.map { L10n.localizedDecimal($0, maximumFractionDigits: 1) } ?? "—"
                            )
                        )
                    }
                }
            }
        }
        .accessibilityIdentifier("codex.insights.trend")
    }
}

struct TokenActivityCalendar: View {
    private struct Day: Identifiable {
        let date: Date
        let tokens: Int64
        let isInRange: Bool
        var id: Date { date }
    }

    private struct Week: Identifiable {
        let start: Date
        let monthLabel: String?
        let days: [Day]
        var id: Date { start }
    }

    let daily: [CodexDailyUsage]
    let now: Date
    @State private var selectedDate: Date?

    private var calendar: Calendar {
        var calendar = CodexUsageWindow.utcCalendar
        calendar.firstWeekday = 2
        return calendar
    }

    private var end: Date { calendar.startOfDay(for: now) }
    private var start: Date { calendar.date(byAdding: .day, value: -364, to: end) ?? end }
    private var tokensByDay: [Date: Int64] {
        daily.reduce(into: [:]) { result, day in
            result[calendar.startOfDay(for: day.date), default: 0] += day.totals.usage.totalTokens
        }
    }
    private var maximumTokens: Int64 { tokensByDay.values.max() ?? 0 }
    private var selectedTokens: Int64? {
        selectedDate.flatMap { tokensByDay[calendar.startOfDay(for: $0)] }
    }

    private var weeks: [Week] {
        let weekday = calendar.component(.weekday, from: start)
        let daysSinceMonday = (weekday - calendar.firstWeekday + 7) % 7
        var weekStart = calendar.date(byAdding: .day, value: -daysSinceMonday, to: start) ?? start
        var result: [Week] = []
        var lastLabeledMonth: Int?
        while weekStart <= end {
            let days = (0..<7).compactMap { offset -> Day? in
                guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
                return Day(
                    date: date,
                    tokens: tokensByDay[date] ?? 0,
                    isInRange: date >= start && date <= end
                )
            }
            let visibleDate = days.first(where: \.isInRange)?.date
            let month = visibleDate.map { calendar.component(.month, from: $0) }
            let monthLabel = month != nil && month != lastLabeledMonth
                ? visibleDate.map(L10n.shortMonth)
                : nil
            if let month { lastLabeledMonth = month }
            result.append(Week(start: weekStart, monthLabel: monthLabel, days: days))
            weekStart = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? end.addingTimeInterval(1)
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.tr("insights.calendar.title")).font(.caption.weight(.semibold))
                    Text(
                        L10n.tr(
                            "insights.calendar.range",
                            L10n.shortDateWithYear(start),
                            L10n.shortDateWithYear(end)
                        )
                    )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let selectedDate {
                    Text(
                        L10n.tr(
                            "insights.calendar.selection",
                            L10n.shortDate(selectedDate),
                            CodexInsightsTextPresentation.compactTokens(selectedTokens ?? 0)
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("").frame(height: 13)
                        ForEach(0..<7, id: \.self) { index in
                            Text(weekdayLabel(index))
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, height: 9, alignment: .trailing)
                        }
                    }
                    HStack(alignment: .top, spacing: 2) {
                        ForEach(weeks) { week in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(week.monthLabel ?? "")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                                    .frame(width: 9, height: 13, alignment: .leading)
                                    .zIndex(1)
                                ForEach(week.days) { day in
                                    if day.isInRange {
                                        Button { selectedDate = day.date } label: {
                                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                                .fill(color(for: day.tokens))
                                                .frame(width: 9, height: 9)
                                        }
                                        .buttonStyle(.plain)
                                        .help(
                                            L10n.tr(
                                                "insights.calendar.selection",
                                                L10n.shortDate(day.date),
                                                CodexInsightsTextPresentation.compactTokens(day.tokens)
                                            )
                                        )
                                        .accessibilityLabel(L10n.shortDate(day.date))
                                        .accessibilityValue(CodexInsightsTextPresentation.compactTokens(day.tokens))
                                    } else {
                                        Color.clear.frame(width: 9, height: 9)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 4) {
                Spacer()
                Text(L10n.tr("insights.calendar.less")).font(.caption2).foregroundStyle(.secondary)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color(forLevel: level))
                        .frame(width: 9, height: 9)
                }
                Text(L10n.tr("insights.calendar.more")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("codex.insights.activity-calendar")
    }

    private func weekdayLabel(_ index: Int) -> String {
        switch index {
        case 0: L10n.tr("insights.calendar.monday")
        case 2: L10n.tr("insights.calendar.wednesday")
        case 4: L10n.tr("insights.calendar.friday")
        default: ""
        }
    }

    private func color(for tokens: Int64) -> Color {
        color(forLevel: level(for: tokens))
    }

    private func level(for tokens: Int64) -> Int {
        guard tokens > 0, maximumTokens > 0 else { return 0 }
        let fraction = log1p(Double(tokens)) / log1p(Double(maximumTokens))
        return min(4, max(1, Int(ceil(fraction * 4))))
    }

    private func color(forLevel level: Int) -> Color {
        switch level {
        case 1: ProviderAccent.codex.opacity(0.24)
        case 2: ProviderAccent.codex.opacity(0.45)
        case 3: ProviderAccent.codex.opacity(0.68)
        case 4: ProviderAccent.codex
        default: Color.secondary.opacity(0.12)
        }
    }
}

struct WorkUsageBreakdown: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case projects
        case tasks
        var id: String { rawValue }
    }

    let insights: CodexWorkInsights
    @State private var mode: Mode = .projects

    private var items: [CodexWorkUsageItem] {
        compact(mode == .projects ? insights.projects : insights.tasks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.tr("insights.work.title")).font(.caption.weight(.semibold))
                    Text(
                        L10n.tr(
                            insights.isRetentionLimited ? "insights.work.range_limited" : "insights.work.range",
                            CodexInsightsTextPresentation.compactTokens(insights.observedTokens),
                            L10n.shortDate(insights.window.start),
                            L10n.shortDate(insights.window.end)
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Picker(L10n.tr("insights.work.mode"), selection: $mode) {
                    Text(L10n.tr("insights.work.projects")).tag(Mode.projects)
                    Text(L10n.tr("insights.work.tasks")).tag(Mode.tasks)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }

            VStack(spacing: 7) {
                ForEach(items) { item in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title ?? fallbackTitle)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            if let subtitle = item.subtitle, !subtitle.isEmpty {
                                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        ProgressView(value: share(of: item))
                            .progressViewStyle(.linear)
                            .tint(ProviderAccent.codex.opacity(0.75))
                            .frame(width: 150)
                        Text(CodexInsightsTextPresentation.compactTokens(item.tokens))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                        Text(L10n.localizedDecimal(Decimal(share(of: item) * 100), maximumFractionDigits: 0) + "%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .accessibilityIdentifier("codex.insights.work")
    }

    private var fallbackTitle: String {
        L10n.tr(mode == .projects ? "insights.work.unknown_project" : "insights.work.unknown_task")
    }

    private func share(of item: CodexWorkUsageItem) -> Double {
        guard insights.observedTokens > 0 else { return 0 }
        return Double(item.tokens) / Double(insights.observedTokens)
    }

    private func compact(_ values: [CodexWorkUsageItem]) -> [CodexWorkUsageItem] {
        guard values.count > 6 else { return values }
        let visible = Array(values.prefix(5))
        let remainder = values.dropFirst(5).reduce(Int64.zero) { $0 + $1.tokens }
        return visible + [
            CodexWorkUsageItem(
                id: "other-\(mode.rawValue)",
                title: L10n.tr("insights.work.other"),
                subtitle: nil,
                tokens: remainder
            ),
        ]
    }
}
