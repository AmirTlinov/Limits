import Foundation
import Testing
@testable import LimitsCore
import LimitsShared

private func codexSection(
    id: String,
    rows: [RateLimitDisplayRow]
) -> RateLimitDisplaySection {
    RateLimitDisplaySection(id: id, title: "Codex", rows: rows)
}

private func weeklyRow(id: String, usedPercent: Int, resetText: String? = "Resets Wednesday") -> RateLimitDisplayRow {
    RateLimitDisplayRow(
        id: id,
        title: "Weekly limit",
        usedPercent: usedPercent,
        resetText: resetText,
        resetDate: nil,
        windowMinutes: 10_080
    )
}

private func sessionRow(id: String, usedPercent: Int) -> RateLimitDisplayRow {
    RateLimitDisplayRow(
        id: id,
        title: "5h limit",
        usedPercent: usedPercent,
        resetText: "Resets soon",
        resetDate: nil,
        windowMinutes: 300
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

@Test func codexRailKeepsOnlyTheWeeklyAllowanceThatBindsFirst() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let input = UsageRailProviderInput(
        id: .codex,
        accounts: [
            UsageRailAccountInput(
                id: "account-a",
                title: "first@example.com",
                sections: [
                    codexSection(id: "limit:codex", rows: [
                        weeklyRow(id: "codex.primary", usedPercent: 97),
                    ]),
                    codexSection(id: "limit:codex_bengalfox", rows: [
                        sessionRow(id: "codex_bengalfox.primary", usedPercent: 0),
                        weeklyRow(id: "codex_bengalfox.secondary", usedPercent: 4),
                    ]),
                ]
            ),
            UsageRailAccountInput(
                id: "account-b",
                title: "second@example.com",
                sections: [codexSection(id: "limit:codex", rows: [weeklyRow(id: "codex.primary", usedPercent: 12)])]
            ),
        ],
        status: .available
    )

    let item = UsageRailPresentation.item(from: input, now: now)

    #expect(item.groups.count == 2)
    #expect(item.showsAccountTitles)

    let first = try #require(item.groups.first)
    #expect(first.title == "first@example.com")
    // The session window is dropped and only the most-consumed weekly survives.
    #expect(first.rows.count == 1)
    #expect(first.rows.first?.usedPercent == 97)

    let second = try #require(item.groups.last)
    #expect(second.rows.map(\.usedPercent) == [12])

    // The ring reports the first (current) account.
    #expect(item.usedPercent == 97)
    #expect(item.severity == .critical)
    #expect(item.metricText == "97%")
    #expect(item.isStale == false)
}

@Test func codexRailDropsAccountsWithoutAWeeklyAllowance() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let input = UsageRailProviderInput(
        id: .codex,
        accounts: [
            UsageRailAccountInput(id: "a", title: "only-session", sections: [
                codexSection(id: "limit:codex", rows: [sessionRow(id: "codex.primary", usedPercent: 30)])
            ]),
            UsageRailAccountInput(id: "b", title: "has-weekly", sections: [
                codexSection(id: "limit:codex", rows: [weeklyRow(id: "codex.primary", usedPercent: 55)])
            ]),
        ],
        status: .available
    )

    let item = UsageRailPresentation.item(from: input, now: now)
    #expect(item.groups.map(\.title) == ["has-weekly"])
    #expect(item.showsAccountTitles == false)
    #expect(item.usedPercent == 55)
}

@Test func claudeRailListsSessionThenAllModelsThenTopModel() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    try L10n.withLanguage("en") {
        let evidence = ClaudeLiveEvidence(
            identity: try #require(ClaudeAccountIdentity(email: "claude@example.com", organizationId: nil)),
            identityChangedAt: now,
            snapshot: ClaudeStatuslineBridgeSnapshot(
                fiveHour: .init(usedPercentage: 13, resetsAt: Int64(now.timeIntervalSince1970) + 6_480),
                sevenDay: .init(usedPercentage: 20, resetsAt: Int64(now.timeIntervalSince1970) + 300_000),
                sevenDayTopModel: .init(usedPercentage: 33, resetsAt: Int64(now.timeIntervalSince1970) + 300_000)
            ),
            snapshotAt: now
        )

        let sections = ClaudeLivePresentation.lastKnownRateLimitSections(evidence: evidence)
        let item = UsageRailPresentation.item(
            from: UsageRailProviderInput(
                id: .claude,
                accounts: [UsageRailAccountInput(id: "claude", title: "claude@example.com", sections: sections)],
                status: .available
            ),
            now: now
        )

        let group = try #require(item.groups.first)
        #expect(group.rows.map(\.title) == ["Current session", "All models", "Fable"])
        #expect(group.rows.map(\.usedPercent) == [13, 20, 33])
        // The ring tracks the session, as the reference design does.
        #expect(item.usedPercent == 13)
        #expect(item.showsAccountTitles == false)
        #expect(item.rowsAreFableAware)
    }
}

private extension UsageRailItem {
    /// Guards the mapping from Claude's `seven_day_opus` key onto its top-model row.
    var rowsAreFableAware: Bool {
        groups.first?.rows.contains { $0.id == ClaudeLivePresentation.topModelRowID } ?? false
    }
}

@Test func claudeRailOmitsWindowsTheBridgeDidNotReport() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    try L10n.withLanguage("en") {
        let evidence = ClaudeLiveEvidence(
            identity: try #require(ClaudeAccountIdentity(email: "claude@example.com", organizationId: nil)),
            identityChangedAt: now,
            snapshot: ClaudeStatuslineBridgeSnapshot(
                fiveHour: .init(usedPercentage: 3, resetsAt: nil),
                sevenDay: .init(usedPercentage: 18, resetsAt: nil),
                sevenDayTopModel: nil
            ),
            snapshotAt: now
        )

        let sections = ClaudeLivePresentation.lastKnownRateLimitSections(evidence: evidence)
        let group = try #require(sections.first)
        #expect(group.rows.map(\.title) == ["Current session", "All models"])
    }
}

@Test func staleReadingsStayVisibleAndAreLabelled() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let observedAt = now.addingTimeInterval(-90 * 60)

    try L10n.withLanguage("en") {
        let input = UsageRailProviderInput(
            id: .codex,
            accounts: [
                UsageRailAccountInput(id: "a", title: "acct", sections: [
                    codexSection(id: "limit:codex", rows: [weeklyRow(id: "codex.primary", usedPercent: 42)])
                ])
            ],
            status: .available,
            observedAt: observedAt,
            isStale: true
        )

        let item = UsageRailPresentation.item(from: input, now: now)
        #expect(item.usedPercent == 42)
        #expect(item.isStale)
        let updated = try #require(item.updatedText)
        #expect(updated.contains("1h"))
        #expect(updated.hasPrefix("Updated"))
    }
}

@Test func railFallsBackToAStatusNoteWhenNoAccountHasRows() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    L10n.withLanguage("en") {
        func item(status: LimitsWidgetProviderStatus, note: String? = nil) -> UsageRailItem {
            UsageRailPresentation.item(
                from: UsageRailProviderInput(
                    id: .claude,
                    accounts: [UsageRailAccountInput(id: "a", title: "acct", sections: [])],
                    status: status,
                    note: note,
                    isStale: true
                ),
                now: now
            )
        }

        let empty = item(status: .noData)
        #expect(empty.groups.isEmpty)
        #expect(empty.usedPercent == nil)
        #expect(empty.metricText == "—")
        // Staleness only means something once there is a reading to call stale.
        #expect(empty.isStale == false)
        #expect(empty.updatedText == nil)
        #expect(empty.note == L10n.tr("rail.no_data"))

        #expect(item(status: .unavailable).note == L10n.tr("rail.signed_out"))
        #expect(item(status: .error).note == L10n.tr("rail.unavailable"))
        #expect(item(status: .error, note: "Sign-in expired").note == "Sign-in expired")
    }
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

@Test func statuslineBridgeDecodesTheTopModelWindow() throws {
    let json = """
    {"five_hour":{"resets_at":1787971800,"used_percentage":13},
     "seven_day":{"resets_at":1788393600,"used_percentage":20},
     "seven_day_opus":{"resets_at":1788393600,"used_percentage":33}}
    """
    let snapshot = try JSONDecoder().decode(ClaudeStatuslineBridgeSnapshot.self, from: Data(json.utf8))
    #expect(snapshot.fiveHour?.usedPercentage == 13)
    #expect(snapshot.sevenDay?.usedPercentage == 20)
    #expect(snapshot.sevenDayTopModel?.usedPercentage == 33)
    #expect(snapshot.sevenDayTopModel?.resetsAt == 1788393600)
}

@Test func recentReadingsCarryNoUpdatedLabel() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    L10n.withLanguage("en") {
        func item(observedAt: Date?) -> UsageRailItem {
            UsageRailPresentation.item(
                from: UsageRailProviderInput(
                    id: .codex,
                    accounts: [UsageRailAccountInput(id: "a", title: "acct", sections: [
                        codexSection(id: "limit:codex", rows: [weeklyRow(id: "codex.primary", usedPercent: 42)])
                    ])],
                    status: .available,
                    observedAt: observedAt,
                    isStale: true
                ),
                now: now
            )
        }

        // Under a minute old rounds to nothing worth printing.
        #expect(item(observedAt: now.addingTimeInterval(-30)).updatedText == nil)
        // A clock that ran backwards must not produce a negative age.
        #expect(item(observedAt: now.addingTimeInterval(600)).updatedText == nil)
        #expect(item(observedAt: nil).updatedText == nil)
        // Still flagged stale either way, so the ring stays dimmed.
        #expect(item(observedAt: nil).isStale)
    }
}

@Test func claudeRailDropsWindowsWithAnUnusablePercentage() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    try L10n.withLanguage("en") {
        let evidence = ClaudeLiveEvidence(
            identity: try #require(ClaudeAccountIdentity(email: "claude@example.com", organizationId: nil)),
            identityChangedAt: now,
            snapshot: ClaudeStatuslineBridgeSnapshot(
                fiveHour: .init(usedPercentage: .nan, resetsAt: nil),
                sevenDay: .init(usedPercentage: nil, resetsAt: nil),
                sevenDayTopModel: .init(usedPercentage: 33, resetsAt: nil)
            ),
            snapshotAt: now
        )

        let sections = ClaudeLivePresentation.lastKnownRateLimitSections(evidence: evidence)
        let group = try #require(sections.first)
        #expect(group.rows.map(\.title) == ["Fable"])
    }
}

@Test func codexAccountsExposeTheirLastKnownSectionsPastTheFreshnessWindow() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let observedAt = now.addingTimeInterval(-2 * 60 * 60)
    let snapshot = RateLimitSnapshotModel(
        credits: nil,
        limitId: "codex",
        limitName: nil,
        planType: "pro",
        primary: RateLimitWindowSnapshot(
            resetsAt: Int64(now.timeIntervalSince1970) + 86_400,
            usedPercent: 57,
            windowDurationMins: 10_080
        ),
        rateLimitReachedType: nil,
        secondary: nil
    )

    // The freshness-gated reader goes quiet, which would leave a non-active account blank.
    let fresh = CodexAccountsPresentationPolicy.storedRateLimitSections(
        primary: snapshot,
        byLimitId: nil,
        observedAt: observedAt,
        now: now
    )
    #expect(fresh.isEmpty)

    let lastKnown = CodexAccountsPresentationPolicy.lastKnownRateLimitSections(
        primary: snapshot,
        byLimitId: nil,
        now: now
    )
    let row = try #require(lastKnown.flatMap(\.rows).first)
    #expect(row.usedPercent == 57)
    #expect(row.isWeeklyWindow)

    // Windows that already reset are still dropped, stale or not.
    let expired = CodexAccountsPresentationPolicy.lastKnownRateLimitSections(
        primary: RateLimitSnapshotModel(
            credits: nil,
            limitId: "codex",
            limitName: nil,
            planType: "pro",
            primary: RateLimitWindowSnapshot(
                resetsAt: Int64(now.timeIntervalSince1970) - 60,
                usedPercent: 57,
                windowDurationMins: 10_080
            ),
            rateLimitReachedType: nil,
            secondary: nil
        ),
        byLimitId: nil,
        now: now
    )
    #expect(expired.isEmpty)
}
