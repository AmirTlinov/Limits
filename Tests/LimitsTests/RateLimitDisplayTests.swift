import Foundation
import Testing
@testable import Limits

@Test func resetFormatterShowsTodayOtherDayAndStaleState() throws {
    let calendar = Calendar.current
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 24, hour: 3, minute: 10)))
    let laterToday = try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 24, hour: 4, minute: 15)))
    let tomorrow = try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 25, hour: 4, minute: 15)))
    let stale = try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 24, hour: 2, minute: 15)))

    #expect(RateLimitResetFormatter.expandedText(for: laterToday, now: now) == "Сброс в 04:15")
    #expect(RateLimitResetFormatter.compactText(for: laterToday, now: now) == "Сброс 04:15")
    #expect(RateLimitResetFormatter.expandedText(for: stale, now: now) == "Сброс прошёл · обновите")
    #expect(RateLimitResetFormatter.compactText(for: stale, now: now) == "сброс прошёл")
    #expect(RateLimitResetFormatter.compactText(for: tomorrow, now: now).hasPrefix("Сброс 25"))
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
    #expect(row.compactResetText(now: now) == "Сброс 03:06")
}
