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
        #expect(RateLimitResetFormatter.expandedText(for: stale, now: now) == "Сброс прошёл · обновите")
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
    }

    L10n.withLanguage("zh-Hans") {
        #expect(L10n.tr("filter.all") == "全部")
        #expect(L10n.tr("limit.five_hour") == "5小时限额")
    }
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
