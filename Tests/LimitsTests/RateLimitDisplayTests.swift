import Foundation
import Testing
@testable import Limits

@Test func resetFormatterShowsTodayOtherDayAndStaleState() throws {
    let calendar = Calendar.current
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 24, hour: 3, minute: 10)))
    let laterToday = try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 24, hour: 4, minute: 15)))
    let tomorrow = try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 25, hour: 4, minute: 15)))
    let stale = try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 24, hour: 2, minute: 15)))

    L10n.withLanguage("ru") {
        #expect(RateLimitResetFormatter.expandedText(for: laterToday, now: now) == "Сброс в 04:15")
        #expect(RateLimitResetFormatter.compactText(for: laterToday, now: now) == "Сброс 04:15")
        #expect(RateLimitResetFormatter.expandedText(for: stale, now: now) == "Сброс прошёл · автообновление")
        #expect(RateLimitResetFormatter.compactText(for: stale, now: now) == "сброс прошёл")
        #expect(RateLimitResetFormatter.compactText(for: tomorrow, now: now).hasPrefix("Сброс 25"))
    }
}

@Test func displayBuilderCarriesResetDateIntoRows() throws {
    let calendar = Calendar.current
    let resetDate = try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 24, hour: 3, minute: 6)))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 24, hour: 3, minute: 5)))
    let resetTimestamp = Int64(resetDate.timeIntervalSince1970)
    let snapshot = RateLimitSnapshotModel(
        credits: nil,
        limitId: "codex",
        limitName: nil,
        planType: "pro",
        primary: RateLimitWindowSnapshot(resetsAt: resetTimestamp, usedPercent: 15, windowDurationMins: 300),
        rateLimitReachedType: nil,
        secondary: nil
    )

    let sections = RateLimitDisplayBuilder.makeSections(primary: snapshot, byLimitId: nil)
    let row = try #require(sections.first?.rows.first)

    #expect(row.resetDate == resetDate)
    #expect(row.resetText != nil)
    L10n.withLanguage("ru") {
        #expect(row.compactResetText(now: now) == "Сброс 03:06")
    }
}

@Test func localizationSwitchesCoreTrayStringsByLanguage() {
    L10n.withLanguage("en") {
        #expect(L10n.tr("filter.all") == "All")
        #expect(L10n.tr("limit.five_hour") == "5h limit")
        #expect(L10n.percentRemaining(42) == "42% remaining")
        #expect(L10n.tr("settings.language.title") == "Language")
    }

    L10n.withLanguage("zh-Hans") {
        #expect(L10n.tr("filter.all") == "全部")
        #expect(L10n.tr("limit.five_hour") == "5小时限额")
        #expect(L10n.tr("settings.language.title") == "语言")
    }
}

@Test func supportedLanguageDisplayNamesStayReadable() {
    #expect(L10n.displayName(for: "en") == "English")
    #expect(L10n.displayName(for: "ru") == "Русский")
    #expect(L10n.displayName(for: "zh-Hans") == "简体中文")
}

@Test func trayReadyAccountCountUsesLocalizedPluralRules() {
    L10n.withLanguage("en") {
        #expect(L10n.readyAccountCount(1) == "1 other account ready")
        #expect(L10n.readyAccountCount(2) == "2 other accounts ready")
    }

    L10n.withLanguage("ru") {
        #expect(L10n.readyAccountCount(1) == "1 другой аккаунт откатился")
        #expect(L10n.readyAccountCount(2) == "2 других аккаунта откатились")
        #expect(L10n.readyAccountCount(5) == "5 других аккаунтов откатились")
    }
}

@Test func fiveHourResetDetectionIgnoresFutureAndNonFiveHourWindows() throws {
    let calendar = Calendar.current
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 24, hour: 12)))
    let past = try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 24, hour: 11)))
    let future = try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 24, hour: 13)))

    let rolledBack = RateLimitSnapshotModel(
        credits: nil,
        limitId: "codex",
        limitName: nil,
        planType: "pro",
        primary: RateLimitWindowSnapshot(resetsAt: Int64(past.timeIntervalSince1970), usedPercent: 100, windowDurationMins: 300),
        rateLimitReachedType: nil,
        secondary: nil
    )
    let pending = RateLimitSnapshotModel(
        credits: nil,
        limitId: "codex",
        limitName: nil,
        planType: "pro",
        primary: RateLimitWindowSnapshot(resetsAt: Int64(future.timeIntervalSince1970), usedPercent: 100, windowDurationMins: 300),
        rateLimitReachedType: nil,
        secondary: nil
    )
    let weekly = RateLimitSnapshotModel(
        credits: nil,
        limitId: "codex",
        limitName: nil,
        planType: "pro",
        primary: RateLimitWindowSnapshot(resetsAt: Int64(past.timeIntervalSince1970), usedPercent: 100, windowDurationMins: 10080),
        rateLimitReachedType: nil,
        secondary: nil
    )

    #expect(rolledBack.fiveHourHasReset(now: now))
    #expect(!pending.fiveHourHasReset(now: now))
    #expect(!weekly.fiveHourHasReset(now: now))
}

@Test func storedLimitDisplayDoesNotRenderExpiredFiveHourSnapshotAsCurrentData() throws {
    let calendar = Calendar.current
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 16)))
    let resetAlreadyPassed = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 15)))
    let staleSnapshot = RateLimitSnapshotModel(
        credits: nil,
        limitId: "codex",
        limitName: nil,
        planType: "pro",
        primary: RateLimitWindowSnapshot(resetsAt: Int64(resetAlreadyPassed.timeIntervalSince1970), usedPercent: 95, windowDurationMins: 300),
        rateLimitReachedType: nil,
        secondary: nil
    )

    L10n.withLanguage("ru") {
        #expect(AppModel.storedRateLimitSections(primary: staleSnapshot, byLimitId: nil, now: now).isEmpty)
        #expect(AppModel.storedRateLimitSummary(primary: staleSnapshot, byLimitId: nil, now: now) == "Сброс прошёл · автообновление")
        #expect(AppModel.storedRemainingPercent(primary: staleSnapshot, byLimitId: nil, now: now) == nil)
    }
}

@Test func storedLimitDisplayKeepsFutureWeeklyWhenFiveHourResetPassed() throws {
    let calendar = Calendar.current
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 16)))
    let resetAlreadyPassed = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 15)))
    let weeklyReset = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 10, hour: 12)))
    let snapshot = RateLimitSnapshotModel(
        credits: nil,
        limitId: "codex",
        limitName: nil,
        planType: "pro",
        primary: RateLimitWindowSnapshot(resetsAt: Int64(resetAlreadyPassed.timeIntervalSince1970), usedPercent: 0, windowDurationMins: 300),
        rateLimitReachedType: nil,
        secondary: RateLimitWindowSnapshot(resetsAt: Int64(weeklyReset.timeIntervalSince1970), usedPercent: 81, windowDurationMins: 10_080)
    )

    L10n.withLanguage("ru") {
        let sections = AppModel.storedRateLimitSections(primary: snapshot, byLimitId: nil, now: now)
        #expect(sections.count == 1)
        #expect(sections.first?.rows.map(\.title) == ["Недельный лимит"])
        #expect(sections.first?.rows.first?.usedPercent == 81)

        let summary = AppModel.sidebarLimitSummary(primary: snapshot, byLimitId: nil, now: now)
        #expect(summary?.fiveHourRemainingPercent == nil)
        #expect(summary?.weeklyRemainingPercent == 19)
        #expect(summary?.compactLimitText() == "7д 19%")
        #expect(AppModel.storedRemainingPercent(primary: snapshot, byLimitId: nil, now: now) == nil)
    }
}

@Test func storedLimitDisplayUsesExactByLimitSnapshotsInsteadOfAggregateFallback() throws {
    let calendar = Calendar.current
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 16)))
    let pastReset = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 15)))
    let futureReset = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 18)))
    let aggregate = RateLimitSnapshotModel(
        credits: nil,
        limitId: "aggregate",
        limitName: "Aggregate",
        planType: "pro",
        primary: RateLimitWindowSnapshot(resetsAt: Int64(futureReset.timeIntervalSince1970), usedPercent: 5, windowDurationMins: 300),
        rateLimitReachedType: nil,
        secondary: nil
    )
    let expiredCodex = RateLimitSnapshotModel(
        credits: nil,
        limitId: "codex",
        limitName: nil,
        planType: "pro",
        primary: RateLimitWindowSnapshot(resetsAt: Int64(pastReset.timeIntervalSince1970), usedPercent: 95, windowDurationMins: 300),
        rateLimitReachedType: nil,
        secondary: nil
    )

    let sections = AppModel.storedRateLimitSections(primary: aggregate, byLimitId: ["codex": expiredCodex], now: now)
    #expect(sections.isEmpty)
}

@Test func storedLimitDisplayTreatsExpiredCodexByLimitSnapshotAsStale() throws {
    let calendar = Calendar.current
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 16)))
    let futureReset = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 17)))
    let pastReset = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 15)))
    let primary = RateLimitSnapshotModel(
        credits: nil,
        limitId: "aggregate",
        limitName: "Aggregate",
        planType: "pro",
        primary: RateLimitWindowSnapshot(resetsAt: Int64(futureReset.timeIntervalSince1970), usedPercent: 5, windowDurationMins: 300),
        rateLimitReachedType: nil,
        secondary: nil
    )
    let expiredCodex = RateLimitSnapshotModel(
        credits: nil,
        limitId: "codex",
        limitName: nil,
        planType: "pro",
        primary: RateLimitWindowSnapshot(resetsAt: Int64(pastReset.timeIntervalSince1970), usedPercent: 95, windowDurationMins: 300),
        rateLimitReachedType: nil,
        secondary: nil
    )

    #expect(AppModel.storedRateLimitSections(primary: primary, byLimitId: ["codex": expiredCodex], now: now).isEmpty)
    #expect(AppModel.storedRemainingPercent(primary: primary, byLimitId: ["codex": expiredCodex], now: now) == nil)
}
