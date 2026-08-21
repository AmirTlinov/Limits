import Foundation
import Testing
@testable import LimitsCore

@Test func usageRepositoryDeduplicatesCanonicalEventsAndKeepsDailyAggregate() async throws {
    let root = usageRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    _ = try await repository.open()
    let event = usageRepositoryEvent(threadID: "thread", turnID: "turn", accountID: "acct")

    #expect(try await repository.recordUsageEvents([event]) == 1)
    #expect(try await repository.recordUsageEvents([event]) == 0)
    let snapshot = try await repository.snapshot()
    #expect(snapshot.dailyUsage.count == 1)
    #expect(snapshot.dailyUsage.first?.usage.totalTokens == 120)
    await repository.close()
}

@Test func threadUsageEvidenceUpgradesUnattributedIdentityWithoutDoubleCountingTokens() async throws {
    let root = usageRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    _ = try await repository.open()
    let event = usageRepositoryEvent(threadID: "thread-evidence", turnID: "turn", accountID: nil)
    _ = try await repository.recordUsageEvents([event])
    #expect(try await repository.snapshot().dailyUsage.first?.accountID == nil)

    try await repository.recordThreadUsageEvidence(
        CodexThreadUsageEvidence(
            threadID: "thread-evidence",
            accountID: "acct_matched",
            observedAt: .now,
            estimatedCreditsMicros: 50_000,
            estimatedUSDMicros: nil,
            groups: []
        )
    )
    let snapshot = try await repository.snapshot()
    #expect(snapshot.dailyUsage.count == 1)
    #expect(snapshot.dailyUsage.first?.accountID == "acct_matched")
    #expect(snapshot.dailyUsage.first?.attribution == .serverMatched)
    #expect(snapshot.dailyUsage.first?.usage.totalTokens == 120)
    #expect(snapshot.threadUsageEvidence["thread-evidence"]?.accountID == "acct_matched")
    await repository.close()
}

@Test func threadUsageEvidenceUsesOnlyTheNewestServerIdentity() async throws {
    let root = usageRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    _ = try await repository.open()
    let event = usageRepositoryEvent(threadID: "thread-corrected", turnID: "turn", accountID: nil)
    _ = try await repository.recordUsageEvents([event])

    func evidence(accountID: String, observedAt: TimeInterval) -> CodexThreadUsageEvidence {
        CodexThreadUsageEvidence(
            threadID: "thread-corrected",
            accountID: accountID,
            observedAt: Date(timeIntervalSince1970: observedAt),
            estimatedCreditsMicros: 50_000,
            estimatedUSDMicros: nil,
            groups: []
        )
    }

    try await repository.recordThreadUsageEvidence(evidence(accountID: "acct_initial", observedAt: 200))
    try await repository.recordThreadUsageEvidence(evidence(accountID: "acct_stale", observedAt: 100))
    var snapshot = try await repository.snapshot()
    #expect(snapshot.dailyUsage.count == 1)
    #expect(snapshot.dailyUsage.first?.accountID == "acct_initial")
    #expect(snapshot.threadUsageEvidence["thread-corrected"]?.accountID == "acct_initial")

    try await repository.recordThreadUsageEvidence(evidence(accountID: "acct_corrected", observedAt: 300))
    snapshot = try await repository.snapshot()
    #expect(snapshot.dailyUsage.count == 1)
    #expect(snapshot.dailyUsage.first?.accountID == "acct_corrected")
    #expect(snapshot.dailyUsage.first?.usage.totalTokens == 120)
    #expect(snapshot.threadUsageEvidence["thread-corrected"]?.accountID == "acct_corrected")
    await repository.close()
}

@Test func rawEventRetentionLeavesPermanentDailyAggregate() async throws {
    let root = usageRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    _ = try await repository.open()
    let old = usageRepositoryEvent(
        threadID: "old-thread",
        turnID: "turn",
        accountID: "acct",
        occurredAt: Date(timeIntervalSince1970: 1_000)
    )
    _ = try await repository.recordUsageEvents([old])
    try await repository.purgeRawEvents(now: Date(timeIntervalSince1970: 1_000 + CodexUsageRepository.rawEventRetention + 1))
    let snapshot = try await repository.snapshot()
    #expect(snapshot.dailyUsage.first?.usage.totalTokens == 120)
    await repository.close()
}

@Test func rateRevisionIsBoundToEachEventWithoutMergingChangedPrices() async throws {
    let root = usageRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    _ = try await repository.open()
    let oldObservedAt = Date(timeIntervalSince1970: 100_000)
    let newObservedAt = oldObservedAt.addingTimeInterval(60 * 60)
    let oldRevision = usageRateRevision(id: "old", observedAt: oldObservedAt)
    let newRevision = usageRateRevision(id: "new", observedAt: newObservedAt)
    _ = try await repository.recordRateCardRevision(oldRevision)
    _ = try await repository.recordUsageEvents([
        usageRepositoryEvent(
            threadID: "thread-old-rate",
            turnID: "turn",
            accountID: "acct",
            occurredAt: oldObservedAt.addingTimeInterval(30 * 60)
        ),
    ])
    _ = try await repository.recordRateCardRevision(newRevision)
    _ = try await repository.recordUsageEvents([
        usageRepositoryEvent(
            threadID: "thread-new-rate",
            turnID: "turn",
            accountID: "acct",
            occurredAt: newObservedAt.addingTimeInterval(30 * 60)
        ),
    ])

    let snapshot = try await repository.snapshot()
    #expect(Set(snapshot.dailyUsage.compactMap(\.rateRevisionID)) == ["old", "new"])
    #expect(snapshot.dailyUsage.reduce(0) { $0 + $1.usage.totalTokens } == 240)
    await repository.close()
}

@Test func dailyUsageKeepsStandardAndLongContextRequestsSeparate() async throws {
    let root = usageRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    _ = try await repository.open()
    _ = try await repository.recordRateCardRevision(
        usageRateRevision(id: "rate", observedAt: Date(timeIntervalSince1970: 1_000))
    )
    let standard = CodexTokenUsage(inputTokens: 200_000, outputTokens: 10_000, totalTokens: 210_000)
    let long = CodexTokenUsage(inputTokens: 300_000, outputTokens: 20_000, totalTokens: 320_000)
    let event = CodexUsageEvent(
        threadID: "thread-context",
        turnID: "turn-context",
        counterEpoch: 0,
        occurredAt: Date(timeIntervalSince1970: 2_000),
        accountID: "acct",
        requestedModel: "gpt-5.6-sol",
        billedModel: nil,
        reasoningEffort: "high",
        speed: nil,
        usage: standard + long,
        contextBreakdown: CodexUsageContextBreakdown(standard: standard, long: long),
        attribution: .confirmed,
        source: .localRollout
    )

    #expect(try await repository.recordUsageEvents([event]) == 1)
    let rows = try await repository.snapshot().dailyUsage
    #expect(Set(rows.map(\.contextTier)) == [.standard, .long])
    #expect(rows.first { $0.contextTier == .standard }?.usage == standard)
    #expect(rows.first { $0.contextTier == .long }?.usage == long)
    await repository.close()
}

@Test func rateCardRecheckKeepsItsFirstObservedBoundary() async throws {
    let root = usageRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    _ = try await repository.open()
    let firstSeen = Date(timeIntervalSince1970: 100_000)
    let checkedAgain = firstSeen.addingTimeInterval(24 * 60 * 60)
    _ = try await repository.recordRateCardRevision(usageRateRevision(id: "same", observedAt: firstSeen))
    _ = try await repository.recordRateCardRevision(
        usageRateRevision(id: "same", observedAt: checkedAgain, checkedAt: checkedAgain)
    )

    let stored = try #require(try await repository.snapshot().rateCardRevisions.first)
    #expect(stored.observedAt == firstSeen)
    #expect(stored.lastCheckedAt == checkedAgain)
    await repository.close()
}

@Test func laterAttributionDoesNotEraseAggregatesWhoseRawEventsExpired() async throws {
    let root = usageRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    _ = try await repository.open()
    let oldDate = Date(timeIntervalSince1970: 1_000)
    let recentDate = oldDate.addingTimeInterval(CodexUsageRepository.rawEventRetention + 60)
    _ = try await repository.recordUsageEvents([
        usageRepositoryEvent(threadID: "expired", turnID: "turn", accountID: "acct", occurredAt: oldDate),
        usageRepositoryEvent(threadID: "recent", turnID: "turn", accountID: nil, occurredAt: recentDate),
    ])
    try await repository.purgeRawEvents(now: recentDate)
    try await repository.recordThreadUsageEvidence(
        CodexThreadUsageEvidence(
            threadID: "recent",
            accountID: "acct",
            observedAt: recentDate,
            estimatedCreditsMicros: 0,
            estimatedUSDMicros: nil,
            groups: []
        )
    )

    let snapshot = try await repository.snapshot()
    #expect(snapshot.dailyUsage.reduce(0) { $0 + $1.usage.totalTokens } == 240)
    #expect(snapshot.dailyUsage.allSatisfy { $0.accountID == "acct" })
    await repository.close()
}

@Test func clearingStatisticsKeepsImportCursorAndIdentityForFutureEvents() async throws {
    let root = usageRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    _ = try await repository.open()
    let observedAt = Date(timeIntervalSince1970: 20_000)
    try await repository.recordCurrentAuthIdentity(
        accountID: "acct",
        fingerprint: "fingerprint",
        observedAt: observedAt,
        transition: .observed
    )
    try await repository.saveImportCursor(
        CodexImportCursor(
            path: "/tmp/session.jsonl",
            inode: 42,
            byteOffset: 512,
            modifiedAt: observedAt,
            schemaAdapter: CodexRolloutUsageImporter.schemaAdapter,
            parserState: Data("state".utf8)
        )
    )
    _ = try await repository.recordUsageEvents([
        usageRepositoryEvent(threadID: "thread", turnID: "turn", accountID: "acct", occurredAt: observedAt),
    ])

    let epoch = observedAt.addingTimeInterval(1)
    try await repository.beginAnalyticsEpoch(at: epoch, baselines: [])

    let cleared = try await repository.snapshot()
    #expect(cleared.dailyUsage.isEmpty)
    #expect(cleared.analyticsEpochStartedAt == epoch)
    #expect(try await repository.accountID(at: observedAt.addingTimeInterval(1)) == "acct")
    #expect(try await repository.importCursor(for: "/tmp/session.jsonl")?.byteOffset == 512)
    _ = try await repository.recordUsageEvents([
        usageRepositoryEvent(threadID: "old", turnID: "turn", accountID: "acct", occurredAt: observedAt),
    ])
    #expect(try await repository.snapshot().dailyUsage.isEmpty)
    try await repository.resetAnalyticsHistoryForReimport()
    #expect(try await repository.importCursor(for: "/tmp/session.jsonl") == nil)
    #expect(try await repository.snapshot().analyticsEpochStartedAt == nil)
    await repository.close()
}

@Test func externallyObservedIdentityChangeLeavesUncertainTimeUnattributed() async throws {
    let root = usageRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    _ = try await repository.open()
    let firstSeen = Date(timeIntervalSince1970: 10_000)
    let firstConfirmed = firstSeen.addingTimeInterval(100)
    let secondSeen = firstConfirmed.addingTimeInterval(100)

    try await repository.recordCurrentAuthIdentity(
        accountID: "acct_a",
        fingerprint: "fingerprint_a",
        observedAt: firstSeen,
        transition: .observed
    )
    try await repository.recordCurrentAuthIdentity(
        accountID: "acct_a",
        fingerprint: "fingerprint_a",
        observedAt: firstConfirmed,
        transition: .observed
    )
    try await repository.recordCurrentAuthIdentity(
        accountID: "acct_b",
        fingerprint: "fingerprint_b",
        observedAt: secondSeen,
        transition: .observed
    )

    #expect(try await repository.accountID(at: firstSeen.addingTimeInterval(1)) == "acct_a")
    #expect(try await repository.accountID(at: firstConfirmed.addingTimeInterval(1)) == nil)
    #expect(try await repository.accountID(at: secondSeen) == "acct_b")
    await repository.close()
}

@Test func limitsOwnedAuthSwitchCreatesAnExactIdentityBoundary() async throws {
    let root = usageRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    _ = try await repository.open()
    let firstSeen = Date(timeIntervalSince1970: 20_000)
    let firstConfirmed = firstSeen.addingTimeInterval(100)
    let switchedAt = firstConfirmed.addingTimeInterval(100)

    try await repository.recordCurrentAuthIdentity(
        accountID: "acct_a",
        fingerprint: "fingerprint_a",
        observedAt: firstSeen,
        transition: .observed
    )
    try await repository.recordCurrentAuthIdentity(
        accountID: "acct_a",
        fingerprint: "fingerprint_a",
        observedAt: firstConfirmed,
        transition: .observed
    )
    try await repository.recordCurrentAuthIdentity(
        accountID: "acct_b",
        fingerprint: "fingerprint_b",
        observedAt: switchedAt,
        transition: .exact
    )

    #expect(try await repository.accountID(at: switchedAt.addingTimeInterval(-1)) == "acct_a")
    #expect(try await repository.accountID(at: switchedAt) == "acct_b")
    await repository.close()
}

@Test func usageSchemaV6MigratesIdentityConfirmationAndDailyPricingToCurrentSchema() async throws {
    let root = usageRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let database = root.appending(path: "usage.sqlite3")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [
        database.path,
        """
        CREATE TABLE auth_intervals (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account_id TEXT NOT NULL,
            fingerprint TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL
        );
        INSERT INTO auth_intervals(account_id, fingerprint, started_at, ended_at)
        VALUES ('acct', 'fingerprint', 1000, NULL);
        CREATE TABLE usage_events (
            id TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL,
            turn_id TEXT NOT NULL,
            counter_epoch INTEGER NOT NULL,
            occurred_at REAL NOT NULL,
            account_id TEXT,
            requested_model TEXT,
            billed_model TEXT,
            reasoning_effort TEXT,
            speed TEXT,
            attribution TEXT NOT NULL,
            source TEXT NOT NULL,
            input_tokens INTEGER NOT NULL,
            cached_input_tokens INTEGER NOT NULL,
            cache_write_input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            reasoning_output_tokens INTEGER NOT NULL,
            total_tokens INTEGER NOT NULL
        );
        CREATE TABLE daily_usage (
            day REAL NOT NULL,
            account_id TEXT NOT NULL,
            model_id TEXT NOT NULL,
            attribution TEXT NOT NULL,
            speed TEXT NOT NULL,
            input_tokens INTEGER NOT NULL,
            cached_input_tokens INTEGER NOT NULL,
            cache_write_input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            reasoning_output_tokens INTEGER NOT NULL,
            total_tokens INTEGER NOT NULL,
            PRIMARY KEY(day, account_id, model_id, attribution, speed)
        );
        INSERT INTO daily_usage(
            day, account_id, model_id, attribution, speed,
            input_tokens, cached_input_tokens, cache_write_input_tokens,
            output_tokens, reasoning_output_tokens, total_tokens
        ) VALUES (0, 'acct', 'gpt-5.6-sol', 'confirmed', '', 100, 0, 0, 20, 10, 120);
        CREATE TABLE account_usage_snapshots (
            account_id TEXT PRIMARY KEY,
            observed_at REAL NOT NULL,
            summary_json BLOB NOT NULL
        );
        CREATE TABLE account_daily_activity (
            account_id TEXT NOT NULL,
            day REAL NOT NULL,
            tokens INTEGER NOT NULL,
            observed_at REAL NOT NULL,
            PRIMARY KEY(account_id, day)
        );
        CREATE TABLE limit_observations (
            id TEXT PRIMARY KEY,
            account_id TEXT NOT NULL,
            limit_id TEXT NOT NULL,
            window_kind TEXT NOT NULL,
            observed_at REAL NOT NULL,
            used_percent INTEGER NOT NULL,
            resets_at REAL,
            window_duration_minutes INTEGER
        );
        CREATE TABLE latest_limit_snapshots (
            account_id TEXT PRIMARY KEY,
            observed_at REAL NOT NULL,
            payload BLOB NOT NULL
        );
        CREATE TABLE endpoint_statuses (
            account_id TEXT NOT NULL,
            endpoint TEXT NOT NULL,
            attempted_at REAL NOT NULL,
            successful_at REAL,
            error_message TEXT,
            PRIMARY KEY(account_id, endpoint)
        );
        CREATE TABLE thread_usage_evidence (
            thread_id TEXT PRIMARY KEY,
            account_id TEXT NOT NULL,
            observed_at REAL NOT NULL,
            payload BLOB NOT NULL
        );
        CREATE TABLE rate_card_revisions (
            id TEXT PRIMARY KEY,
            observed_at REAL NOT NULL,
            payload BLOB NOT NULL
        );
        CREATE TABLE import_cursors (
            path TEXT PRIMARY KEY,
            inode INTEGER NOT NULL,
            byte_offset INTEGER NOT NULL,
            modified_at REAL NOT NULL,
            schema_adapter INTEGER NOT NULL,
            parser_state BLOB
        );
        PRAGMA user_version = 6;
        """,
    ]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    #expect(try await repository.open() == .readWrite)
    let migratedUsage = try #require(try await repository.snapshot().dailyUsage.first)
    #expect(migratedUsage.contextTier == .unknown)
    #expect(migratedUsage.usage.totalTokens == 120)
    #expect(try await repository.accountID(at: Date(timeIntervalSince1970: 1_001)) == "acct")
    try await repository.recordCurrentAuthIdentity(
        accountID: "acct",
        fingerprint: "fingerprint",
        observedAt: Date(timeIntervalSince1970: 1_100),
        transition: .observed
    )
    #expect(try await repository.accountID(at: Date(timeIntervalSince1970: 1_099)) == "acct")
    await repository.close()
}

@Test func futureUsageSchemaOpensReadOnlyWithoutDowngrade() async throws {
    let root = usageRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let database = root.appending(path: "usage.sqlite3")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [database.path, "PRAGMA user_version = 999;"]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    let dataBefore = try Data(contentsOf: database)
    #expect(try await repository.open() == .readOnlyRecovery(schemaVersion: 999))
    await #expect(throws: CodexUsageRepositoryError.self) {
        try await repository.beginAnalyticsEpoch(at: .now, baselines: [])
    }
    await repository.close()
    #expect(try Data(contentsOf: database) == dataBefore)
    let verify = Process()
    let pipe = Pipe()
    verify.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    verify.arguments = [database.path, "PRAGMA user_version;"]
    verify.standardOutput = pipe
    try verify.run()
    verify.waitUntilExit()
    let version = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(version == "999")
}

private func usageRepositoryRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "limits-usage-repository-\(UUID().uuidString)")
}

private func usageRepositoryEvent(
    threadID: String,
    turnID: String,
    accountID: String?,
    occurredAt: Date = .now
) -> CodexUsageEvent {
    CodexUsageEvent(
        threadID: threadID,
        turnID: turnID,
        counterEpoch: 0,
        occurredAt: occurredAt,
        accountID: accountID,
        requestedModel: "gpt-5.6-sol",
        billedModel: nil,
        reasoningEffort: "high",
        speed: nil,
        usage: CodexTokenUsage(inputTokens: 100, outputTokens: 20, reasoningOutputTokens: 10, totalTokens: 120),
        attribution: accountID == nil ? .unattributed : .confirmed,
        source: .localRollout
    )
}

private func usageRateRevision(
    id: String,
    observedAt: Date,
    checkedAt: Date? = nil
) -> OpenAIRateCardRevision {
    OpenAIRateCardRevision(
        id: id,
        observedAt: observedAt,
        checkedAt: checkedAt,
        sourceHashes: ["fixture": id],
        rates: OpenAIPricingCatalog.bundledRevision.rates
    )
}

@Test func usageSchemaNineMigratesToAnalyticsEpochSchemaTen() async throws {
    let root = usageRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    _ = try await first.open()
    await first.close()

    let database = root.appending(path: "usage.sqlite3")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [
        database.path,
        "DROP TABLE analytics_epoch; DROP TABLE account_usage_baselines; PRAGMA user_version = 9;",
    ]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    let migrated = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    #expect(try await migrated.open() == .readWrite)
    let boundary = Date(timeIntervalSince1970: 10_000)
    try await migrated.beginAnalyticsEpoch(at: boundary, baselines: [])
    #expect(try await migrated.snapshot().analyticsEpochStartedAt == boundary)
    await migrated.close()
}

@Test func analyticsEpochKeepsOldServerHistoryBehindStoredBaseline() async throws {
    let root = usageRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    _ = try await repository.open()
    let dayOne = CodexUsageRepository.startOfUTCDay(Date(timeIntervalSince1970: 100_000))
    let dayTwo = dayOne.addingTimeInterval(24 * 60 * 60)
    let baseline = usageAccountSnapshot(
        accountID: "acct",
        observedAt: dayOne,
        lifetime: 1_000,
        daily: [(dayOne, 1_000)]
    )
    let boundary = dayOne.addingTimeInterval(12 * 60 * 60)
    try await repository.beginAnalyticsEpoch(at: boundary, baselines: [baseline])
    try await repository.recordAccountUsage(
        usageAccountSnapshot(
            accountID: "acct",
            observedAt: dayTwo,
            lifetime: 1_300,
            daily: [(dayOne, 1_050), (dayTwo, 250)]
        )
    )

    let visible = try #require(try await repository.snapshot().accountUsage["acct"])
    #expect(visible.summary.lifetimeTokens == 300)
    #expect(visible.dailyActivity == [
        CodexDailyTokenActivity(date: dayOne, tokens: 50),
        CodexDailyTokenActivity(date: dayTwo, tokens: 250),
    ])

    await repository.close()
    let reopened = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    _ = try await reopened.open()
    #expect(try await reopened.snapshot().accountUsage["acct"]?.summary.lifetimeTokens == 300)
    await reopened.close()
}

@Test func firstServerSnapshotAfterOfflineClearBecomesPendingBaseline() async throws {
    let root = usageRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    _ = try await repository.open()
    let day = CodexUsageRepository.startOfUTCDay(Date(timeIntervalSince1970: 200_000))
    try await repository.beginAnalyticsEpoch(at: day.addingTimeInterval(60), baselines: [])

    try await repository.recordAccountUsage(
        usageAccountSnapshot(accountID: "acct", observedAt: day, lifetime: 5_000, daily: [(day, 5_000)])
    )
    let zero = try #require(try await repository.snapshot().accountUsage["acct"])
    #expect(zero.summary.lifetimeTokens == 0)
    #expect(zero.dailyActivity.isEmpty)

    try await repository.recordAccountUsage(
        usageAccountSnapshot(
            accountID: "acct",
            observedAt: day.addingTimeInterval(60),
            lifetime: 5_120,
            daily: [(day, 5_120)]
        )
    )
    let delta = try #require(try await repository.snapshot().accountUsage["acct"])
    #expect(delta.summary.lifetimeTokens == 120)
    #expect(delta.dailyActivity == [CodexDailyTokenActivity(date: day, tokens: 120)])
    await repository.close()
}

@Test func explicitReimportRemovesEpochAndServerBaseline() async throws {
    let root = usageRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    _ = try await repository.open()
    let day = CodexUsageRepository.startOfUTCDay(Date(timeIntervalSince1970: 300_000))
    let raw = usageAccountSnapshot(accountID: "acct", observedAt: day, lifetime: 1_000, daily: [(day, 1_000)])
    try await repository.beginAnalyticsEpoch(at: day, baselines: [raw])
    try await repository.recordAccountUsage(raw)
    #expect(try await repository.snapshot().accountUsage["acct"]?.summary.lifetimeTokens == 0)

    try await repository.resetAnalyticsHistoryForReimport()
    try await repository.recordAccountUsage(raw)
    let restored = try #require(try await repository.snapshot().accountUsage["acct"])
    #expect(restored.summary.lifetimeTokens == 1_000)
    #expect(restored.dailyActivity == [CodexDailyTokenActivity(date: day, tokens: 1_000)])
    #expect(try await repository.snapshot().analyticsEpochStartedAt == nil)
    await repository.close()
}

private func usageAccountSnapshot(
    accountID: String,
    observedAt: Date,
    lifetime: Int64,
    daily: [(Date, Int64)]
) -> CodexAccountUsageSnapshot {
    CodexAccountUsageSnapshot(
        accountID: accountID,
        observedAt: observedAt,
        summary: CodexAccountUsageSummary(
            lifetimeTokens: lifetime,
            peakDailyTokens: daily.map(\.1).max(),
            longestRunningTurnSeconds: nil,
            currentStreakDays: nil,
            longestStreakDays: nil
        ),
        dailyActivity: daily.map { CodexDailyTokenActivity(date: $0.0, tokens: $0.1) }
    )
}

@Test func clearingAnExistingEpochMovesTheServerBaselineForward() async throws {
    let root = usageRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    _ = try await repository.open()
    let day = CodexUsageRepository.startOfUTCDay(Date(timeIntervalSince1970: 400_000))
    let first = usageAccountSnapshot(accountID: "acct", observedAt: day, lifetime: 1_000, daily: [(day, 1_000)])
    try await repository.beginAnalyticsEpoch(at: day, baselines: [first])
    try await repository.recordAccountUsage(
        usageAccountSnapshot(
            accountID: "acct",
            observedAt: day.addingTimeInterval(60),
            lifetime: 1_300,
            daily: [(day, 1_300)]
        )
    )
    #expect(try await repository.snapshot().accountUsage["acct"]?.summary.lifetimeTokens == 300)

    let nextBaselines = try await repository.accountUsageBaselinesForClear(accountIDs: ["acct"])
    try await repository.beginAnalyticsEpoch(at: day.addingTimeInterval(120), baselines: nextBaselines)
    try await repository.recordAccountUsage(
        usageAccountSnapshot(
            accountID: "acct",
            observedAt: day.addingTimeInterval(180),
            lifetime: 1_400,
            daily: [(day, 1_400)]
        )
    )

    let visible = try #require(try await repository.snapshot().accountUsage["acct"])
    #expect(visible.summary.lifetimeTokens == 100)
    #expect(visible.dailyActivity == [CodexDailyTokenActivity(date: day, tokens: 100)])
    await repository.close()
}
