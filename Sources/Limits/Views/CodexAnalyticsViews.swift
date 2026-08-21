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
    private enum PeriodSelection: Hashable {
        case rollingYear
        case calendarYear(Int)
    }

    private struct Day: Identifiable {
        let date: Date
        let usage: CodexDailyUsage?
        let isInRange: Bool
        let isFuture: Bool

        var id: Date { date }
        var tokens: Int64 { usage?.totals.usage.totalTokens ?? 0 }
    }

    private struct Week: Identifiable {
        let start: Date
        let monthLabel: String?
        let days: [Day]
        var id: Date { start }
    }

    private struct ActivityGrid {
        let weeks: [Week]
        let intensityScale: TokenActivityIntensityScale
    }

    let daily: [CodexDailyUsage]
    let now: Date
    @State private var periodSelection = PeriodSelection.rollingYear
    @State private var presentedDate: Date?
    @State private var gridViewportWidth: CGFloat = 0

    private let cellSpacing: CGFloat = 2
    private let minimumCellSize: CGFloat = 9
    private let maximumCellSize: CGFloat = 13
    private let weekdayColumnWidth: CGFloat = 18
    private let weekdayColumnSpacing: CGFloat = 6

    private var calendar: Calendar {
        var calendar = CodexUsageWindow.utcCalendar
        calendar.firstWeekday = 2
        return calendar
    }

    private var today: Date { calendar.startOfDay(for: now) }
    private var currentYear: Int { calendar.component(.year, from: today) }
    private var availableYears: [Int] {
        Set(
            daily.lazy
                .map { calendar.startOfDay(for: $0.date) }
                .filter { $0 <= today }
                .map { calendar.component(.year, from: $0) }
        )
        .union([currentYear])
        .sorted(by: >)
    }
    private var start: Date {
        switch periodSelection {
        case .rollingYear:
            calendar.date(byAdding: .day, value: -364, to: today) ?? today
        case let .calendarYear(year):
            calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? today
        }
    }
    private var end: Date {
        switch periodSelection {
        case .rollingYear:
            return today
        case let .calendarYear(year):
            let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? today
            let nextYear = calendar.date(byAdding: .year, value: 1, to: yearStart) ?? today
            return calendar.date(byAdding: .day, value: -1, to: nextYear) ?? yearStart
        }
    }
    private func cellSize(for weekCount: Int) -> CGFloat {
        guard gridViewportWidth > 0, weekCount > 0 else { return minimumCellSize }
        let columnGaps = CGFloat(max(0, weekCount - 1)) * cellSpacing
        let available = gridViewportWidth - weekdayColumnWidth - weekdayColumnSpacing - columnGaps
        return min(maximumCellSize, max(minimumCellSize, available / CGFloat(weekCount)))
    }

    private var activityGrid: ActivityGrid {
        let usageByDay = Dictionary(
            uniqueKeysWithValues: daily.map { (calendar.startOfDay(for: $0.date), $0) }
        )
        let visibleTokens = usageByDay.compactMap { entry -> Int64? in
            guard entry.key >= start, entry.key <= min(end, today) else { return nil }
            return entry.value.totals.usage.totalTokens
        }
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
                    usage: usageByDay[date],
                    isInRange: date >= start && date <= end,
                    isFuture: date > today
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
        return ActivityGrid(
            weeks: result,
            intensityScale: TokenActivityIntensityScale(tokens: visibleTokens)
        )
    }

    var body: some View {
        let grid = activityGrid
        let cellSize = cellSize(for: grid.weeks.count)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.tr("insights.calendar.title")).font(.caption.weight(.semibold))
                    Text(
                        L10n.tr(
                            periodSelection == .rollingYear
                                ? "insights.calendar.range"
                                : "insights.calendar.year_range",
                            L10n.shortDateWithYear(start),
                            L10n.shortDateWithYear(end)
                        )
                    )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker(L10n.tr("insights.calendar.period"), selection: $periodSelection) {
                    Text(L10n.tr("insights.calendar.rolling_year"))
                        .tag(PeriodSelection.rollingYear)
                    Divider()
                    ForEach(availableYears, id: \.self) { year in
                        Text(L10n.localizedInteger(Int64(year)))
                            .tag(PeriodSelection.calendarYear(year))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("codex.insights.activity-calendar-period")
            }

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: weekdayColumnSpacing) {
                    VStack(alignment: .trailing, spacing: cellSpacing) {
                        Text("").frame(height: 13)
                        ForEach(0..<7, id: \.self) { index in
                            Text(weekdayLabel(index))
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .frame(width: weekdayColumnWidth, height: cellSize, alignment: .trailing)
                        }
                    }
                    HStack(alignment: .top, spacing: cellSpacing) {
                        ForEach(grid.weeks) { week in
                            VStack(alignment: .leading, spacing: cellSpacing) {
                                Text(week.monthLabel ?? "")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                                    .frame(width: cellSize, height: 13, alignment: .leading)
                                    .zIndex(1)
                                ForEach(week.days) { day in
                                    if day.isInRange, !day.isFuture {
                                        Button { presentedDate = day.date } label: {
                                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                                .fill(color(for: grid.intensityScale.intensity(for: day.tokens)))
                                                .frame(width: cellSize, height: cellSize)
                                        }
                                        .buttonStyle(.plain)
                                        .onHover { isInside in
                                            if isInside {
                                                presentedDate = day.date
                                            } else if presentedDate == day.date {
                                                presentedDate = nil
                                            }
                                        }
                                        .popover(
                                            isPresented: presentationBinding(for: day.date),
                                            attachmentAnchor: .rect(.bounds),
                                            arrowEdge: .bottom
                                        ) {
                                            DayDetails(date: day.date, usage: day.usage)
                                                .padding(12)
                                                .frame(width: 280)
                                        }
                                        .accessibilityLabel(L10n.shortDate(day.date))
                                        .accessibilityValue(CodexInsightsTextPresentation.compactTokens(day.tokens))
                                    } else if day.isInRange {
                                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                                            .fill(Color.secondary.opacity(0.05))
                                            .frame(width: cellSize, height: cellSize)
                                            .accessibilityHidden(true)
                                    } else {
                                        Color.clear.frame(width: cellSize, height: cellSize)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                if abs(width - gridViewportWidth) > 0.5 {
                    gridViewportWidth = width
                }
            }

            HStack(spacing: 4) {
                Spacer()
                Text(L10n.tr("insights.calendar.less")).font(.caption2).foregroundStyle(.secondary)
                ForEach(TokenActivityIntensity.allCases, id: \.self) { intensity in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color(for: intensity))
                        .frame(width: 9, height: 9)
                }
                Text(L10n.tr("insights.calendar.more")).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("codex.insights.activity-calendar")
        .onChange(of: availableYears) {
            if case let .calendarYear(year) = periodSelection,
               !availableYears.contains(year) {
                periodSelection = .rollingYear
            }
        }
        .onChange(of: periodSelection) {
            presentedDate = nil
        }
    }

    private func presentationBinding(for date: Date) -> Binding<Bool> {
        Binding(
            get: { presentedDate == date },
            set: { isPresented in
                if !isPresented, presentedDate == date {
                    presentedDate = nil
                }
            }
        )
    }

    private func weekdayLabel(_ index: Int) -> String {
        switch index {
        case 0: L10n.tr("insights.calendar.monday")
        case 2: L10n.tr("insights.calendar.wednesday")
        case 4: L10n.tr("insights.calendar.friday")
        default: ""
        }
    }

    private func color(for intensity: TokenActivityIntensity) -> Color {
        switch intensity {
        case .firstQuartile: ProviderAccent.codex.opacity(0.24)
        case .secondQuartile: ProviderAccent.codex.opacity(0.45)
        case .thirdQuartile: ProviderAccent.codex.opacity(0.68)
        case .fourthQuartile: ProviderAccent.codex
        case .none: Color.secondary.opacity(0.12)
        }
    }

    private struct DayDetails: View {
        let date: Date
        let usage: CodexDailyUsage?

        private var totals: CodexUsageTotals {
            usage?.totals ?? CodexUsageTotals(usage: .zero, credits: nil, apiEquivalentUSD: nil)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 9) {
                Text(L10n.shortDateWithYear(date))
                    .font(.headline)

                detailRow(
                    L10n.tr("insights.metric.tokens"),
                    CodexInsightsTextPresentation.compactTokens(totals.usage.totalTokens)
                )

                Divider()

                Text(L10n.tr("insights.calendar.details.models"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let usage, !usage.models.isEmpty {
                    ForEach(Array(usage.models.prefix(5))) { model in
                        detailRow(
                            CodexInsightsTextPresentation.modelTitle(model.modelID),
                            CodexInsightsTextPresentation.compactTokens(model.totals.usage.totalTokens)
                        )
                    }
                    if usage.models.count > 5 {
                        Text(L10n.tr("insights.calendar.details.more_models", usage.models.count - 5))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if usage.modelAttributedTokens != totals.usage.totalTokens {
                        Text(
                            L10n.tr(
                                "insights.calendar.details.model_coverage",
                                CodexInsightsTextPresentation.compactTokens(usage.modelAttributedTokens),
                                CodexInsightsTextPresentation.compactTokens(totals.usage.totalTokens)
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(L10n.tr("insights.calendar.details.no_models"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if totals.credits != nil || totals.apiEquivalentUSD != nil {
                    Divider()
                    if let credits = totals.credits {
                        detailRow(
                            L10n.tr("insights.metric.credits"),
                            L10n.localizedDecimal(credits, maximumFractionDigits: 1)
                        )
                    }
                    if let apiEquivalentUSD = totals.apiEquivalentUSD {
                        detailRow(
                            L10n.tr("insights.metric.api_equivalent"),
                            L10n.localizedCurrencyUSD(apiEquivalentUSD)
                        )
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }

        private func detailRow(_ title: String, _ value: String) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(value)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.caption)
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
