import Foundation
import Testing
@testable import LimitsCore
import LimitsShared

private func makeProvider(
    id: LimitsWidgetProviderID = .claude,
    title: String = "claude@example.com",
    status: LimitsWidgetProviderStatus = .available,
    limits: [LimitsWidgetLimitSnapshot],
    observedAt: Date?,
    freshUntil: Date?,
    note: String? = nil
) -> LimitsWidgetProviderSnapshot {
    LimitsWidgetProviderSnapshot(
        id: id,
        title: title,
        subtitle: nil,
        status: status,
        limits: limits,
        observedAt: observedAt,
        freshUntil: freshUntil,
        note: note
    )
}

@Test func railSeverityFollowsUsageThresholds() {
    #expect(UsageRailPresentation.severity(usedPercent: nil) == .unknown)
    #expect(UsageRailPresentation.severity(usedPercent: 0) == .low)
    #expect(UsageRailPresentation.severity(usedPercent: 49) == .low)
    #expect(UsageRailPresentation.severity(usedPercent: 50) == .medium)
    #expect(UsageRailPresentation.severity(usedPercent: 69) == .medium)
    #expect(UsageRailPresentation.severity(usedPercent: 70) == .high)
    #expect(UsageRailPresentation.severity(usedPercent: 89) == .high)
    #expect(UsageRailPresentation.severity(usedPercent: 90) == .critical)
    #expect(UsageRailPresentation.severity(usedPercent: 100) == .critical)
}

@Test func railItemConvertsRemainingIntoUsedAndPicksSessionHeadline() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let sessionReset = now.addingTimeInterval(51 * 60)
    let weeklyReset = now.addingTimeInterval(3 * 86_400)

    try L10n.withLanguage("en") {
        let provider = makeProvider(
            limits: [
                LimitsWidgetLimitSnapshot(
                    id: "limit:claude.weekly",
                    title: L10n.tr("limit.weekly"),
                    remainingPercent: 93,
                    resetDate: weeklyReset
                ),
                LimitsWidgetLimitSnapshot(
                    id: "limit:claude.session",
                    title: L10n.tr("limit.five_hour"),
                    remainingPercent: 27,
                    resetDate: sessionReset
                ),
            ],
            observedAt: now.addingTimeInterval(-60),
            freshUntil: now.addingTimeInterval(600)
        )

        let item = UsageRailPresentation.item(from: provider, now: now)

        // The ring reports the session window even though the weekly row is listed first.
        #expect(item.usedPercent == 73)
        #expect(item.severity == .high)
        #expect(item.metricText == "73%")
        #expect(item.title == "Claude")
        #expect(item.accountTitle == "claude@example.com")
        #expect(item.headerText == "Claude Usage")
        #expect(item.note == nil)

        #expect(item.rows.count == 2)
        let weekly = try #require(item.rows.first)
        #expect(weekly.usedPercent == 7)
        #expect(weekly.severity == .low)
        #expect(weekly.usedText == "7% Used")

        let session = try #require(item.rows.last)
        #expect(session.usedPercent == 73)
        #expect(session.resetText == RateLimitResetFormatter.expandedText(for: sessionReset, now: now))
    }
}

@Test func railItemDropsExpiredAndUnknownLimits() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    try L10n.withLanguage("en") {
        let provider = makeProvider(
            limits: [
                LimitsWidgetLimitSnapshot(
                    id: "limit:codex.expired",
                    title: L10n.tr("limit.five_hour"),
                    remainingPercent: 40,
                    resetDate: now.addingTimeInterval(-60)
                ),
                LimitsWidgetLimitSnapshot(
                    id: "limit:codex.unknown",
                    title: L10n.tr("limit.weekly"),
                    remainingPercent: nil,
                    resetDate: now.addingTimeInterval(3_600)
                ),
                LimitsWidgetLimitSnapshot(
                    id: "limit:codex.live",
                    title: L10n.tr("limit.daily"),
                    remainingPercent: 80,
                    resetDate: now.addingTimeInterval(7_200)
                ),
            ],
            observedAt: now.addingTimeInterval(-60),
            freshUntil: now.addingTimeInterval(600)
        )

        let item = UsageRailPresentation.item(from: provider, now: now)
        let row = try #require(item.rows.first)
        #expect(item.rows.count == 1)
        #expect(row.id == "limit:codex.live")
        // No session window survived, so the ring falls back to the first fresh limit.
        #expect(item.usedPercent == 20)
    }
}

@Test func railItemReportsStatusNoteWhenNothingIsFresh() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    L10n.withLanguage("en") {
        let staleProvider = makeProvider(
            limits: [
                LimitsWidgetLimitSnapshot(
                    id: "limit:claude.session",
                    title: L10n.tr("limit.five_hour"),
                    remainingPercent: 50,
                    resetDate: now.addingTimeInterval(3_600)
                )
            ],
            observedAt: now.addingTimeInterval(-3_600),
            freshUntil: now.addingTimeInterval(-600)
        )

        let stale = UsageRailPresentation.item(from: staleProvider, now: now)
        #expect(stale.rows.isEmpty)
        #expect(stale.usedPercent == nil)
        #expect(stale.hasData == false)
        #expect(stale.metricText == "—")
        #expect(stale.progressValue == 0)
        #expect(stale.severity == .unknown)
        #expect(stale.note == L10n.tr("rail.no_data"))

        let signedOut = UsageRailPresentation.item(
            from: makeProvider(status: .unavailable, limits: [], observedAt: nil, freshUntil: nil),
            now: now
        )
        #expect(signedOut.note == L10n.tr("rail.signed_out"))

        let failing = UsageRailPresentation.item(
            from: makeProvider(status: .error, limits: [], observedAt: nil, freshUntil: nil),
            now: now
        )
        #expect(failing.note == L10n.tr("rail.unavailable"))

        // An explicit provider note wins over the generic status text.
        let annotated = UsageRailPresentation.item(
            from: makeProvider(status: .error, limits: [], observedAt: nil, freshUntil: nil, note: "Sign-in expired"),
            now: now
        )
        #expect(annotated.note == "Sign-in expired")
    }
}

@Test func railItemsFollowSnapshotProviderOrder() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = LimitsWidgetSnapshot(
        generatedAt: now,
        providers: [
            makeProvider(id: .codex, title: "codex@example.com", limits: [], observedAt: nil, freshUntil: nil),
            makeProvider(id: .claude, limits: [], observedAt: nil, freshUntil: nil),
        ]
    )

    let items = UsageRailPresentation.items(from: snapshot, now: now)
    #expect(items.map(\.id) == [.codex, .claude])
}

@Test func railVisibilityDefaultsToOnAndHonoursAnExplicitChoice() throws {
    let suiteName = "limits.rail.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(UsageRailPresentation.isEnabled(in: defaults))

    defaults.set(false, forKey: UsageRailPresentation.enabledStorageKey)
    #expect(UsageRailPresentation.isEnabled(in: defaults) == false)

    defaults.set(true, forKey: UsageRailPresentation.enabledStorageKey)
    #expect(UsageRailPresentation.isEnabled(in: defaults))
}
