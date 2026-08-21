import Darwin
import Foundation
import LimitsShared
import SQLite3

@frozen public enum CodexUsageRepositoryAccess: Equatable, Sendable {
    case readWrite
    case readOnlyRecovery(schemaVersion: Int)
}

@frozen public enum CodexAuthIdentityTransition: Equatable, Sendable {
    /// Limits observed the global auth store after an outside process could have changed it.
    /// Time between the last confirmed observation and this one remains unattributed.
    case observed

    /// Limits performed the auth switch and therefore knows the exact boundary.
    case exact
}

public enum CodexUsageRepositoryError: LocalizedError, Equatable {
    case notOpened
    case openFailed(String)
    case statementFailed(String)
    case readOnlyRecovery(schemaVersion: Int)

    public var errorDescription: String? {
        switch self {
        case .notOpened:
            return L10n.tr("usage.repository.not_opened")
        case .openFailed(let detail):
            return L10n.tr("usage.repository.open_failed", detail)
        case .statementFailed(let detail):
            return L10n.tr("usage.repository.statement_failed", detail)
        case .readOnlyRecovery(let version):
            return L10n.tr("usage.repository.read_only", version)
        }
    }
}

public struct CodexUsagePersistence: @unchecked Sendable {
    public let baseURL: URL?
    public let fileManager: FileManager

    public init(baseURL: URL? = nil, fileManager: FileManager = .default) {
        self.baseURL = baseURL
        self.fileManager = fileManager
    }

    public var directoryURL: URL {
        if let baseURL { return baseURL }
        let applicationSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return (applicationSupport ?? fileManager.homeDirectoryForCurrentUser)
            .appending(path: "Limits", directoryHint: .isDirectory)
    }

    public var databaseURL: URL { directoryURL.appending(path: "usage.sqlite3") }

    public func secureDirectory() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    public func secureDatabaseFiles() {
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

public actor CodexUsageRepository {
    public static let currentSchemaVersion = 11
    public static let rawEventRetention: TimeInterval = 90 * 24 * 60 * 60

    private let persistence: CodexUsagePersistence
    private var connection: SQLiteConnection?
    private var access: CodexUsageRepositoryAccess?

    public init(persistence: CodexUsagePersistence = CodexUsagePersistence()) {
        self.persistence = persistence
    }

    @discardableResult
    public func open() throws -> CodexUsageRepositoryAccess {
        if let access { return access }
        try persistence.secureDirectory()

        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            persistence.databaseURL.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error \(result)"
            if let handle { sqlite3_close_v2(handle) }
            throw CodexUsageRepositoryError.openFailed(message)
        }
        connection = SQLiteConnection(handle)
        sqlite3_busy_timeout(handle, 5_000)
        let version = try scalarInt("PRAGMA user_version")
        if version > Self.currentSchemaVersion {
            connection = nil
            var readOnlyHandle: OpaquePointer?
            let readOnlyResult = sqlite3_open_v2(
                persistence.databaseURL.path,
                &readOnlyHandle,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                nil
            )
            guard readOnlyResult == SQLITE_OK, let readOnlyHandle else {
                let message = readOnlyHandle.map { String(cString: sqlite3_errmsg($0)) }
                    ?? "SQLite error \(readOnlyResult)"
                if let readOnlyHandle { sqlite3_close_v2(readOnlyHandle) }
                throw CodexUsageRepositoryError.openFailed(message)
            }
            connection = SQLiteConnection(readOnlyHandle)
            sqlite3_busy_timeout(readOnlyHandle, 5_000)
            access = .readOnlyRecovery(schemaVersion: version)
            persistence.secureDatabaseFiles()
            return access!
        }

        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = FULL")

        if version == 0 {
            try createSchema()
        } else {
            if version < 2 { try migrateSchemaFromV1() }
            if version < 3 { try migrateSchemaFromV2() }
            if version < 4 { try migrateSchemaFromV3() }
            if version < 5 { try migrateSchemaFromV4() }
            if version < 6 { try migrateSchemaFromV5() }
            if version < 7 { try migrateSchemaFromV6() }
            if version < 8 { try migrateSchemaFromV7() }
            if version < 9 { try migrateSchemaFromV8() }
            if version < 10 { try migrateSchemaFromV9() }
            if version < 11 { try migrateSchemaFromV10() }
        }
        access = .readWrite
        persistence.secureDatabaseFiles()
        return .readWrite
    }

    public func close() {
        connection = nil
        access = nil
    }

    public func snapshot() throws -> CodexUsageRepositorySnapshot {
        try requireOpen()
        return CodexUsageRepositorySnapshot(
            accountUsage: try loadAccountUsage(),
            dailyUsage: try loadDailyUsage(),
            workUsage: try loadWorkUsage(),
            limitObservations: try loadLimitObservations(),
            latestLimits: try loadLatestLimits(),
            endpointStatuses: try loadEndpointStatuses(),
            threadUsageEvidence: try loadThreadUsageEvidence(),
            rateCardRevisions: try loadRateCardRevisions(),
            analyticsEpochStartedAt: try loadAnalyticsEpochStartedAt()
        )
    }

    @discardableResult
    public func recordUsageEvents(_ events: [CodexUsageEvent]) throws -> Int {
        try requireWritable()
        let epoch = try loadAnalyticsEpochStartedAt()
        let events = epoch.map { boundary in events.filter { $0.occurredAt >= boundary } } ?? events
        guard !events.isEmpty else { return 0 }
        var inserted = 0
        try transaction {
            for event in events {
                let evidenceAccountID = event.accountID == nil ? try threadEvidenceAccountID(threadID: event.threadID) : nil
                let storedEvent = evidenceAccountID.map { accountID in
                    CodexUsageEvent(
                        threadID: event.threadID,
                        turnID: event.turnID,
                        counterEpoch: event.counterEpoch,
                        occurredAt: event.occurredAt,
                        accountID: accountID,
                        requestedModel: event.requestedModel,
                        billedModel: event.billedModel,
                        reasoningEffort: event.reasoningEffort,
                        speed: event.speed,
                        usage: event.usage,
                        contextBreakdown: event.contextBreakdown,
                        attribution: .serverMatched,
                        source: event.source
                    )
                } ?? event
                let rateRevisionID = try effectiveRateCardRevisionID(at: storedEvent.occurredAt) ?? ""
                let statement = try prepare(
                    """
                    INSERT OR IGNORE INTO usage_events (
                        id, thread_id, turn_id, counter_epoch, occurred_at, account_id,
                        requested_model, billed_model, reasoning_effort, speed, attribution, source, rate_revision_id,
                        input_tokens, cached_input_tokens, cache_write_input_tokens,
                        output_tokens, reasoning_output_tokens, total_tokens, context_breakdown
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """
                )
                defer { sqlite3_finalize(statement) }
                bind(storedEvent.id, to: 1, in: statement)
                bind(storedEvent.threadID, to: 2, in: statement)
                bind(storedEvent.turnID, to: 3, in: statement)
                bind(Int64(storedEvent.counterEpoch), to: 4, in: statement)
                bind(storedEvent.occurredAt.timeIntervalSince1970, to: 5, in: statement)
                bind(storedEvent.accountID, to: 6, in: statement)
                bind(storedEvent.requestedModel, to: 7, in: statement)
                bind(storedEvent.billedModel, to: 8, in: statement)
                bind(storedEvent.reasoningEffort, to: 9, in: statement)
                bind(storedEvent.speed, to: 10, in: statement)
                bind(storedEvent.attribution.rawValue, to: 11, in: statement)
                bind(storedEvent.source.rawValue, to: 12, in: statement)
                bind(rateRevisionID, to: 13, in: statement)
                bind(storedEvent.usage.inputTokens, to: 14, in: statement)
                bind(storedEvent.usage.cachedInputTokens, to: 15, in: statement)
                bind(storedEvent.usage.cacheWriteInputTokens, to: 16, in: statement)
                bind(storedEvent.usage.outputTokens, to: 17, in: statement)
                bind(storedEvent.usage.reasoningOutputTokens, to: 18, in: statement)
                bind(storedEvent.usage.totalTokens, to: 19, in: statement)
                if let contextBreakdown = storedEvent.contextBreakdown {
                    bind(try JSONEncoder.limits.encode(contextBreakdown), to: 20, in: statement)
                } else {
                    sqlite3_bind_null(statement, 20)
                }
                try stepDone(statement)

                guard sqlite3_changes(try handle()) == 1 else { continue }
                inserted += 1
                try incrementDailyAggregate(for: storedEvent, rateRevisionID: rateRevisionID)
            }
        }
        persistence.secureDatabaseFiles()
        return inserted
    }

    public func recordAccountUsage(_ snapshot: CodexAccountUsageSnapshot) throws {
        try requireWritable()
        try transaction {
            let persistedSnapshot = try accountUsageRelativeToAnalyticsEpoch(snapshot)
            if let existingObservedAt = try accountUsageObservedAt(accountID: persistedSnapshot.accountID),
               existingObservedAt > persistedSnapshot.observedAt {
                return
            }
            let summaryData = try JSONEncoder.limits.encode(persistedSnapshot.summary)
            let statement = try prepare(
                """
                INSERT INTO account_usage_snapshots (account_id, observed_at, summary_json)
                VALUES (?, ?, ?)
                ON CONFLICT(account_id) DO UPDATE SET
                    observed_at = excluded.observed_at,
                    summary_json = excluded.summary_json
                WHERE excluded.observed_at >= account_usage_snapshots.observed_at
                """
            )
            defer { sqlite3_finalize(statement) }
            bind(persistedSnapshot.accountID, to: 1, in: statement)
            bind(persistedSnapshot.observedAt.timeIntervalSince1970, to: 2, in: statement)
            bind(summaryData, to: 3, in: statement)
            try stepDone(statement)

            let clearActivity = try prepare("DELETE FROM account_daily_activity WHERE account_id = ?")
            defer { sqlite3_finalize(clearActivity) }
            bind(persistedSnapshot.accountID, to: 1, in: clearActivity)
            try stepDone(clearActivity)

            for bucket in persistedSnapshot.dailyActivity where bucket.tokens > 0 {
                let activity = try prepare(
                    """
                    INSERT INTO account_daily_activity (account_id, day, tokens, observed_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(account_id, day) DO UPDATE SET
                        tokens = excluded.tokens,
                        observed_at = excluded.observed_at
                    WHERE excluded.observed_at >= account_daily_activity.observed_at
                    """
                )
                defer { sqlite3_finalize(activity) }
                bind(persistedSnapshot.accountID, to: 1, in: activity)
                bind(Self.startOfUTCDay(bucket.date).timeIntervalSince1970, to: 2, in: activity)
                bind(bucket.tokens, to: 3, in: activity)
                bind(persistedSnapshot.observedAt.timeIntervalSince1970, to: 4, in: activity)
                try stepDone(activity)
            }
        }
    }

    public func recordLimitObservations(_ observations: [CodexLimitObservation]) throws {
        guard !observations.isEmpty else { return }
        try requireWritable()
        try transaction {
            for observation in observations {
                let statement = try prepare(
                    """
                    INSERT OR IGNORE INTO limit_observations (
                        id, account_id, limit_id, window_kind, observed_at,
                        used_percent, resets_at, window_duration_minutes
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """
                )
                defer { sqlite3_finalize(statement) }
                bind(observation.id, to: 1, in: statement)
                bind(observation.accountID, to: 2, in: statement)
                bind(observation.limitID, to: 3, in: statement)
                bind(observation.window.rawValue, to: 4, in: statement)
                bind(observation.observedAt.timeIntervalSince1970, to: 5, in: statement)
                bind(Int64(observation.usedPercent), to: 6, in: statement)
                bind(observation.resetsAt?.timeIntervalSince1970, to: 7, in: statement)
                bind(observation.windowDurationMinutes, to: 8, in: statement)
                try stepDone(statement)
            }
        }
    }

    public func recordRateLimits(_ snapshot: CodexRateLimitsSnapshot) throws {
        try requireWritable()
        let payload = try JSONEncoder.limits.encode(snapshot)
        let statement = try prepare(
            """
            INSERT INTO latest_limit_snapshots (account_id, observed_at, payload)
            VALUES (?, ?, ?)
            ON CONFLICT(account_id) DO UPDATE SET
                observed_at = excluded.observed_at,
                payload = excluded.payload
            WHERE excluded.observed_at >= latest_limit_snapshots.observed_at
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(snapshot.accountID, to: 1, in: statement)
        bind(snapshot.observedAt.timeIntervalSince1970, to: 2, in: statement)
        bind(payload, to: 3, in: statement)
        try stepDone(statement)
    }

    public func recordEndpointStatus(_ status: CodexUsageEndpointStatus) throws {
        try requireWritable()
        let statement = try prepare(
            """
            INSERT INTO endpoint_statuses (account_id, endpoint, attempted_at, successful_at, error_message)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(account_id, endpoint) DO UPDATE SET
                attempted_at = excluded.attempted_at,
                successful_at = excluded.successful_at,
                error_message = excluded.error_message
            WHERE excluded.attempted_at >= endpoint_statuses.attempted_at
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(status.accountID, to: 1, in: statement)
        bind(status.endpoint.rawValue, to: 2, in: statement)
        bind(status.attemptedAt.timeIntervalSince1970, to: 3, in: statement)
        bind(status.successfulAt?.timeIntervalSince1970, to: 4, in: statement)
        bind(status.errorMessage, to: 5, in: statement)
        try stepDone(statement)
    }

    public func recordThreadUsageEvidence(_ evidence: CodexThreadUsageEvidence) throws {
        try requireWritable()
        if let existing = try threadUsageEvidence(threadID: evidence.threadID) {
            if existing == evidence { return }
            guard evidence.observedAt > existing.observedAt else { return }
        }
        let payload = try JSONEncoder.limits.encode(evidence)
        try transaction {
            let statement = try prepare(
                """
                INSERT INTO thread_usage_evidence (thread_id, account_id, observed_at, payload)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(thread_id) DO UPDATE SET
                    account_id = excluded.account_id,
                    observed_at = excluded.observed_at,
                    payload = excluded.payload
                WHERE excluded.observed_at >= thread_usage_evidence.observed_at
                """
            )
            defer { sqlite3_finalize(statement) }
            bind(evidence.threadID, to: 1, in: statement)
            bind(evidence.accountID, to: 2, in: statement)
            bind(evidence.observedAt.timeIntervalSince1970, to: 3, in: statement)
            bind(payload, to: 4, in: statement)
            try stepDone(statement)

            let affectedEvents = try reconcilableRawUsageEvents(threadID: evidence.threadID)
            for stored in affectedEvents {
                try decrementDailyAggregate(for: stored.event, rateRevisionID: stored.rateRevisionID)
            }
            let update = try prepare(
                """
                UPDATE usage_events
                SET account_id = ?, attribution = ?
                WHERE thread_id = ? AND attribution IN (?, ?)
                """
            )
            defer { sqlite3_finalize(update) }
            bind(evidence.accountID, to: 1, in: update)
            bind(CodexUsageAttribution.serverMatched.rawValue, to: 2, in: update)
            bind(evidence.threadID, to: 3, in: update)
            bind(CodexUsageAttribution.unattributed.rawValue, to: 4, in: update)
            bind(CodexUsageAttribution.serverMatched.rawValue, to: 5, in: update)
            try stepDone(update)

            for stored in affectedEvents {
                let event = stored.event
                let attributed = CodexUsageEvent(
                    threadID: event.threadID,
                    turnID: event.turnID,
                    counterEpoch: event.counterEpoch,
                    occurredAt: event.occurredAt,
                    accountID: evidence.accountID,
                    requestedModel: event.requestedModel,
                    billedModel: event.billedModel,
                    reasoningEffort: event.reasoningEffort,
                    speed: event.speed,
                    usage: event.usage,
                    contextBreakdown: event.contextBreakdown,
                    attribution: .serverMatched,
                    source: event.source
                )
                try incrementDailyAggregate(for: attributed, rateRevisionID: stored.rateRevisionID)
            }
        }
    }

    @discardableResult
    public func recordRateCardRevision(_ revision: OpenAIRateCardRevision) throws -> Bool {
        try requireWritable()
        let existing = try rateCardRevision(id: revision.id)
        let persistedRevision = OpenAIRateCardRevision(
            id: revision.id,
            observedAt: existing?.observedAt ?? revision.observedAt,
            checkedAt: max(existing?.lastCheckedAt ?? revision.lastCheckedAt, revision.lastCheckedAt),
            sourceHashes: revision.sourceHashes,
            rates: revision.rates
        )
        let data = try JSONEncoder.limits.encode(persistedRevision)
        try transaction {
            let statement = try prepare(
                """
                INSERT INTO rate_card_revisions (id, observed_at, payload) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
                """
            )
            defer { sqlite3_finalize(statement) }
            bind(persistedRevision.id, to: 1, in: statement)
            bind(persistedRevision.observedAt.timeIntervalSince1970, to: 2, in: statement)
            bind(data, to: 3, in: statement)
            try stepDone(statement)

            for stored in try unassignedRateRawUsageEvents() {
                guard let rateRevisionID = try effectiveRateCardRevisionID(at: stored.event.occurredAt) else { continue }
                try decrementDailyAggregate(for: stored.event, rateRevisionID: stored.rateRevisionID)
                try {
                    let update = try prepare("UPDATE usage_events SET rate_revision_id = ? WHERE id = ?")
                    defer { sqlite3_finalize(update) }
                    bind(rateRevisionID, to: 1, in: update)
                    bind(stored.event.id, to: 2, in: update)
                    try stepDone(update)
                }()
                try incrementDailyAggregate(for: stored.event, rateRevisionID: rateRevisionID)
            }
        }
        return existing == nil
    }

    public func importCursor(for path: String) throws -> CodexImportCursor? {
        try requireOpen()
        let statement = try prepare(
            "SELECT inode, byte_offset, modified_at, schema_adapter, metadata_adapter, parser_state FROM import_cursors WHERE path = ?"
        )
        defer { sqlite3_finalize(statement) }
        bind(path, to: 1, in: statement)
        guard try stepRow(statement) else { return nil }
        return CodexImportCursor(
            path: path,
            inode: UInt64(max(0, sqlite3_column_int64(statement, 0))),
            byteOffset: UInt64(max(0, sqlite3_column_int64(statement, 1))),
            modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            schemaAdapter: Int(sqlite3_column_int64(statement, 3)),
            metadataAdapter: Int(sqlite3_column_int64(statement, 4)),
            parserState: columnData(statement, 5)
        )
    }

    public func saveImportCursor(_ cursor: CodexImportCursor) throws {
        try requireWritable()
        let statement = try prepare(
            """
            INSERT INTO import_cursors (path, inode, byte_offset, modified_at, schema_adapter, metadata_adapter, parser_state)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                inode = excluded.inode,
                byte_offset = excluded.byte_offset,
                modified_at = excluded.modified_at,
                schema_adapter = excluded.schema_adapter,
                metadata_adapter = excluded.metadata_adapter,
                parser_state = excluded.parser_state
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(cursor.path, to: 1, in: statement)
        bind(Int64(clamping: cursor.inode), to: 2, in: statement)
        bind(Int64(clamping: cursor.byteOffset), to: 3, in: statement)
        bind(cursor.modifiedAt.timeIntervalSince1970, to: 4, in: statement)
        bind(Int64(cursor.schemaAdapter), to: 5, in: statement)
        if let parserState = cursor.parserState {
            bind(Int64(cursor.metadataAdapter), to: 6, in: statement)
            bind(parserState, to: 7, in: statement)
        } else {
            bind(Int64(cursor.metadataAdapter), to: 6, in: statement)
            sqlite3_bind_null(statement, 7)
        }
        try stepDone(statement)
    }

    public func recordRolloutContexts(_ contexts: [CodexRolloutContext]) throws {
        guard !contexts.isEmpty else { return }
        try requireWritable()
        try transaction {
            for context in contexts {
                let statement = try prepare(
                    """
                    INSERT INTO rollout_contexts (
                        thread_id, turn_id, project_id, project_title, task_title, observed_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(thread_id, turn_id) DO UPDATE SET
                        project_id = COALESCE(excluded.project_id, rollout_contexts.project_id),
                        project_title = COALESCE(excluded.project_title, rollout_contexts.project_title),
                        task_title = COALESCE(excluded.task_title, rollout_contexts.task_title),
                        observed_at = MAX(excluded.observed_at, rollout_contexts.observed_at)
                    """
                )
                defer { sqlite3_finalize(statement) }
                bind(context.threadID, to: 1, in: statement)
                bind(context.turnID ?? "", to: 2, in: statement)
                bind(context.projectID, to: 3, in: statement)
                bind(context.projectTitle, to: 4, in: statement)
                bind(context.taskTitle, to: 5, in: statement)
                bind(context.observedAt.timeIntervalSince1970, to: 6, in: statement)
                try stepDone(statement)
            }
        }
    }

    public func recordCurrentAuthIdentity(
        accountID: String?,
        fingerprint: String?,
        observedAt: Date,
        transition: CodexAuthIdentityTransition
    ) throws {
        try requireWritable()
        try transaction {
            let open = try prepare(
                """
                SELECT id, account_id, fingerprint, started_at, confirmed_at
                FROM auth_intervals WHERE ended_at IS NULL ORDER BY id DESC LIMIT 1
                """
            )
            defer { sqlite3_finalize(open) }
            if try stepRow(open) {
                let id = sqlite3_column_int64(open, 0)
                let existingAccount = columnString(open, 1) ?? ""
                let existingFingerprint = columnString(open, 2) ?? ""
                let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(open, 3))
                let confirmedAt = Date(timeIntervalSince1970: sqlite3_column_double(open, 4))
                if existingAccount == accountID, existingFingerprint == fingerprint,
                   accountID != nil, fingerprint != nil {
                    guard observedAt > confirmedAt else { return }
                    let confirm = try prepare("UPDATE auth_intervals SET confirmed_at = ? WHERE id = ?")
                    defer { sqlite3_finalize(confirm) }
                    bind(observedAt.timeIntervalSince1970, to: 1, in: confirm)
                    bind(id, to: 2, in: confirm)
                    try stepDone(confirm)
                    return
                }
                guard observedAt >= confirmedAt else { return }
                let boundary = transition == .exact ? observedAt : max(startedAt, confirmedAt)
                let close = try prepare("UPDATE auth_intervals SET ended_at = ? WHERE id = ?")
                defer { sqlite3_finalize(close) }
                bind(boundary.timeIntervalSince1970, to: 1, in: close)
                bind(id, to: 2, in: close)
                try stepDone(close)
            }

            guard let accountID, let fingerprint else { return }
            let insert = try prepare(
                """
                INSERT INTO auth_intervals (account_id, fingerprint, started_at, confirmed_at, ended_at)
                VALUES (?, ?, ?, ?, NULL)
                """
            )
            defer { sqlite3_finalize(insert) }
            bind(accountID, to: 1, in: insert)
            bind(fingerprint, to: 2, in: insert)
            bind(observedAt.timeIntervalSince1970, to: 3, in: insert)
            bind(observedAt.timeIntervalSince1970, to: 4, in: insert)
            try stepDone(insert)
        }
    }

    public func accountID(at date: Date) throws -> String? {
        try requireOpen()
        let statement = try prepare(
            """
            SELECT account_id FROM auth_intervals
            WHERE started_at <= ? AND (ended_at IS NULL OR ? < ended_at)
            ORDER BY started_at DESC LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(date.timeIntervalSince1970, to: 1, in: statement)
        bind(date.timeIntervalSince1970, to: 2, in: statement)
        guard try stepRow(statement) else { return nil }
        return columnString(statement, 0)
    }

    public func deleteAccount(_ accountID: String) throws {
        try requireWritable()
        try transaction {
            for table in [
                "usage_events", "daily_usage", "account_usage_snapshots",
                "account_daily_activity", "limit_observations", "latest_limit_snapshots", "endpoint_statuses", "thread_usage_evidence", "auth_intervals", "account_usage_baselines",
            ] {
                let statement = try prepare("DELETE FROM \(table) WHERE account_id = ?")
                defer { sqlite3_finalize(statement) }
                bind(accountID, to: 1, in: statement)
                try stepDone(statement)
            }
        }
    }

    public func beginAnalyticsEpoch(
        at startedAt: Date,
        baselines: [CodexAccountUsageSnapshot]
    ) throws {
        try requireWritable()
        try transaction {
            try execute("DELETE FROM analytics_epoch")
            let epoch = try prepare("INSERT INTO analytics_epoch (id, started_at) VALUES (1, ?)")
            defer { sqlite3_finalize(epoch) }
            bind(startedAt.timeIntervalSince1970, to: 1, in: epoch)
            try stepDone(epoch)

            try execute("DELETE FROM account_usage_baselines")
            for baseline in baselines {
                try insertAccountUsageBaseline(baseline, epochStartedAt: startedAt)
            }
            try clearAnalyticsTables()
        }
    }

    public func accountUsageBaselinesForClear(
        accountIDs: Set<String>
    ) throws -> [CodexAccountUsageSnapshot] {
        try requireOpen()
        let visible = try loadAccountUsage()
        guard try loadAnalyticsEpochStartedAt() != nil else {
            return accountIDs.compactMap { visible[$0] }
        }
        return try accountIDs.compactMap { accountID -> CodexAccountUsageSnapshot? in
            let baseline = try accountUsageBaseline(accountID: accountID)
            if let baseline {
                if let delta = visible[accountID] {
                    return combinedAccountUsage(baseline: baseline, delta: delta)
                }
                return baseline
            }
            return visible[accountID]
        }
    }

    public func resetAnalyticsHistoryForReimport() throws {
        try requireWritable()
        try transaction {
            try clearAnalyticsTables()
            try execute("DELETE FROM import_cursors")
            try execute("DELETE FROM account_usage_baselines")
            try execute("DELETE FROM analytics_epoch")
        }
    }

    public func purgeRawEvents(now: Date = .now) throws {
        try requireWritable()
        let statement = try prepare("DELETE FROM usage_events WHERE occurred_at < ?")
        defer { sqlite3_finalize(statement) }
        bind(now.addingTimeInterval(-Self.rawEventRetention).timeIntervalSince1970, to: 1, in: statement)
        try stepDone(statement)
    }

    private func createSchema() throws {
        try transaction {
            try execute(
                """
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
                    rate_revision_id TEXT NOT NULL,
                    input_tokens INTEGER NOT NULL,
                    cached_input_tokens INTEGER NOT NULL,
                    cache_write_input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL,
                    reasoning_output_tokens INTEGER NOT NULL,
                    total_tokens INTEGER NOT NULL,
                    context_breakdown BLOB
                )
                """
            )
            try execute("CREATE INDEX usage_events_occurred_at ON usage_events(occurred_at)")
            try execute("CREATE INDEX usage_events_account_id ON usage_events(account_id)")
            try execute(
                """
                CREATE TABLE daily_usage (
                    day REAL NOT NULL,
                    account_id TEXT NOT NULL,
                    model_id TEXT NOT NULL,
                    attribution TEXT NOT NULL,
                    speed TEXT NOT NULL,
                    source TEXT NOT NULL,
                    rate_revision_id TEXT NOT NULL,
                    context_tier TEXT NOT NULL,
                    input_tokens INTEGER NOT NULL,
                    cached_input_tokens INTEGER NOT NULL,
                    cache_write_input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL,
                    reasoning_output_tokens INTEGER NOT NULL,
                    total_tokens INTEGER NOT NULL,
                    PRIMARY KEY(day, account_id, model_id, attribution, speed, source, rate_revision_id, context_tier)
                )
                """
            )
            try execute(
                """
                CREATE TABLE account_usage_snapshots (
                    account_id TEXT PRIMARY KEY,
                    observed_at REAL NOT NULL,
                    summary_json BLOB NOT NULL
                )
                """
            )
            try execute(
                """
                CREATE TABLE account_daily_activity (
                    account_id TEXT NOT NULL,
                    day REAL NOT NULL,
                    tokens INTEGER NOT NULL,
                    observed_at REAL NOT NULL,
                    PRIMARY KEY(account_id, day)
                )
                """
            )
            try execute(
                """
                CREATE TABLE limit_observations (
                    id TEXT PRIMARY KEY,
                    account_id TEXT NOT NULL,
                    limit_id TEXT NOT NULL,
                    window_kind TEXT NOT NULL,
                    observed_at REAL NOT NULL,
                    used_percent INTEGER NOT NULL,
                    resets_at REAL,
                    window_duration_minutes INTEGER
                )
                """
            )
            try execute("CREATE INDEX limit_observations_account_window ON limit_observations(account_id, limit_id, window_kind, observed_at)")
            try execute(
                """
                CREATE TABLE latest_limit_snapshots (
                    account_id TEXT PRIMARY KEY,
                    observed_at REAL NOT NULL,
                    payload BLOB NOT NULL
                )
                """
            )
            try execute(
                """
                CREATE TABLE endpoint_statuses (
                    account_id TEXT NOT NULL,
                    endpoint TEXT NOT NULL,
                    attempted_at REAL NOT NULL,
                    successful_at REAL,
                    error_message TEXT,
                    PRIMARY KEY(account_id, endpoint)
                )
                """
            )
            try execute(
                """
                CREATE TABLE thread_usage_evidence (
                    thread_id TEXT PRIMARY KEY,
                    account_id TEXT NOT NULL,
                    observed_at REAL NOT NULL,
                    payload BLOB NOT NULL
                )
                """
            )
            try execute(
                """
                CREATE TABLE rate_card_revisions (
                    id TEXT PRIMARY KEY,
                    observed_at REAL NOT NULL,
                    payload BLOB NOT NULL
                )
                """
            )
            try execute(
                """
                CREATE TABLE import_cursors (
                    path TEXT PRIMARY KEY,
                    inode INTEGER NOT NULL,
                    byte_offset INTEGER NOT NULL,
                    modified_at REAL NOT NULL,
                    schema_adapter INTEGER NOT NULL,
                    metadata_adapter INTEGER NOT NULL,
                    parser_state BLOB
                )
                """
            )
            try execute(
                """
                CREATE TABLE rollout_contexts (
                    thread_id TEXT NOT NULL,
                    turn_id TEXT NOT NULL,
                    project_id TEXT,
                    project_title TEXT,
                    task_title TEXT,
                    observed_at REAL NOT NULL,
                    PRIMARY KEY(thread_id, turn_id)
                )
                """
            )
            try execute(
                """
                CREATE TABLE auth_intervals (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    account_id TEXT NOT NULL,
                    fingerprint TEXT NOT NULL,
                    started_at REAL NOT NULL,
                    confirmed_at REAL NOT NULL,
                    ended_at REAL
                )
                """
            )
            try execute(
                """
                CREATE TABLE analytics_epoch (
                    id INTEGER PRIMARY KEY CHECK(id = 1),
                    started_at REAL NOT NULL
                )
                """
            )
            try execute(
                """
                CREATE TABLE account_usage_baselines (
                    account_id TEXT PRIMARY KEY,
                    epoch_started_at REAL NOT NULL,
                    payload BLOB NOT NULL
                )
                """
            )
            try execute("PRAGMA user_version = \(Self.currentSchemaVersion)")
        }
    }

    private func migrateSchemaFromV1() throws {
        try transaction {
            try execute(
                """
                CREATE TABLE IF NOT EXISTS latest_limit_snapshots (
                    account_id TEXT PRIMARY KEY,
                    observed_at REAL NOT NULL,
                    payload BLOB NOT NULL
                )
                """
            )
            try execute("PRAGMA user_version = 2")
        }
    }

    private func migrateSchemaFromV2() throws {
        try transaction {
            try execute("ALTER TABLE import_cursors ADD COLUMN parser_state BLOB")
            try execute("PRAGMA user_version = 3")
        }
    }

    private func migrateSchemaFromV3() throws {
        try transaction {
            try execute("ALTER TABLE daily_usage RENAME TO daily_usage_v3")
            try execute(
                """
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
                )
                """
            )
            try execute(
                """
                INSERT INTO daily_usage (
                    day, account_id, model_id, attribution, speed, input_tokens,
                    cached_input_tokens, cache_write_input_tokens, output_tokens,
                    reasoning_output_tokens, total_tokens
                )
                SELECT day, account_id, model_id, attribution, '', input_tokens,
                       cached_input_tokens, cache_write_input_tokens, output_tokens,
                       reasoning_output_tokens, total_tokens
                FROM daily_usage_v3
                """
            )
            try execute("DROP TABLE daily_usage_v3")
            try execute("PRAGMA user_version = 4")
        }
    }

    private func migrateSchemaFromV4() throws {
        try transaction {
            try execute(
                """
                CREATE TABLE endpoint_statuses (
                    account_id TEXT NOT NULL,
                    endpoint TEXT NOT NULL,
                    attempted_at REAL NOT NULL,
                    successful_at REAL,
                    error_message TEXT,
                    PRIMARY KEY(account_id, endpoint)
                )
                """
            )
            try execute("PRAGMA user_version = 5")
        }
    }

    private func migrateSchemaFromV5() throws {
        try transaction {
            try execute(
                """
                CREATE TABLE thread_usage_evidence (
                    thread_id TEXT PRIMARY KEY,
                    account_id TEXT NOT NULL,
                    observed_at REAL NOT NULL,
                    payload BLOB NOT NULL
                )
                """
            )
            try execute("PRAGMA user_version = 6")
        }
    }

    private func migrateSchemaFromV6() throws {
        try transaction {
            try execute("ALTER TABLE auth_intervals ADD COLUMN confirmed_at REAL")
            try execute("UPDATE auth_intervals SET confirmed_at = COALESCE(ended_at, started_at)")
            try execute("PRAGMA user_version = 7")
        }
    }

    private func migrateSchemaFromV7() throws {
        try transaction {
            try execute("ALTER TABLE usage_events ADD COLUMN rate_revision_id TEXT NOT NULL DEFAULT ''")
            try execute("ALTER TABLE daily_usage RENAME TO daily_usage_v7")
            try execute(
                """
                CREATE TABLE daily_usage (
                    day REAL NOT NULL,
                    account_id TEXT NOT NULL,
                    model_id TEXT NOT NULL,
                    attribution TEXT NOT NULL,
                    speed TEXT NOT NULL,
                    source TEXT NOT NULL,
                    rate_revision_id TEXT NOT NULL,
                    input_tokens INTEGER NOT NULL,
                    cached_input_tokens INTEGER NOT NULL,
                    cache_write_input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL,
                    reasoning_output_tokens INTEGER NOT NULL,
                    total_tokens INTEGER NOT NULL,
                    PRIMARY KEY(day, account_id, model_id, attribution, speed, source, rate_revision_id)
                )
                """
            )
            try execute(
                """
                INSERT INTO daily_usage (
                    day, account_id, model_id, attribution, speed, source, rate_revision_id,
                    input_tokens, cached_input_tokens, cache_write_input_tokens,
                    output_tokens, reasoning_output_tokens, total_tokens
                )
                SELECT day, account_id, model_id, attribution, speed, 'localRollout', '',
                       input_tokens, cached_input_tokens, cache_write_input_tokens,
                       output_tokens, reasoning_output_tokens, total_tokens
                FROM daily_usage_v7
                """
            )
            try execute("DROP TABLE daily_usage_v7")
            try execute("PRAGMA user_version = 8")
        }
    }

    private func migrateSchemaFromV8() throws {
        try transaction {
            try execute("ALTER TABLE usage_events ADD COLUMN context_breakdown BLOB")
            try execute("ALTER TABLE daily_usage RENAME TO daily_usage_v8")
            try execute(
                """
                CREATE TABLE daily_usage (
                    day REAL NOT NULL,
                    account_id TEXT NOT NULL,
                    model_id TEXT NOT NULL,
                    attribution TEXT NOT NULL,
                    speed TEXT NOT NULL,
                    source TEXT NOT NULL,
                    rate_revision_id TEXT NOT NULL,
                    context_tier TEXT NOT NULL,
                    input_tokens INTEGER NOT NULL,
                    cached_input_tokens INTEGER NOT NULL,
                    cache_write_input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL,
                    reasoning_output_tokens INTEGER NOT NULL,
                    total_tokens INTEGER NOT NULL,
                    PRIMARY KEY(day, account_id, model_id, attribution, speed, source, rate_revision_id, context_tier)
                )
                """
            )
            try execute(
                """
                INSERT INTO daily_usage (
                    day, account_id, model_id, attribution, speed, source, rate_revision_id, context_tier,
                    input_tokens, cached_input_tokens, cache_write_input_tokens,
                    output_tokens, reasoning_output_tokens, total_tokens
                )
                SELECT day, account_id, model_id, attribution, speed, source, rate_revision_id, 'unknown',
                       input_tokens, cached_input_tokens, cache_write_input_tokens,
                       output_tokens, reasoning_output_tokens, total_tokens
                FROM daily_usage_v8
                """
            )
            try execute("DROP TABLE daily_usage_v8")
            try execute("PRAGMA user_version = 9")
        }
    }

    private func migrateSchemaFromV9() throws {
        try transaction {
            try execute(
                """
                CREATE TABLE analytics_epoch (
                    id INTEGER PRIMARY KEY CHECK(id = 1),
                    started_at REAL NOT NULL
                )
                """
            )
            try execute(
                """
                CREATE TABLE account_usage_baselines (
                    account_id TEXT PRIMARY KEY,
                    epoch_started_at REAL NOT NULL,
                    payload BLOB NOT NULL
                )
                """
            )
            try execute("PRAGMA user_version = 10")
        }
    }

    private func migrateSchemaFromV10() throws {
        try transaction {
            try execute("ALTER TABLE import_cursors ADD COLUMN metadata_adapter INTEGER NOT NULL DEFAULT 0")
            try execute(
                """
                CREATE TABLE rollout_contexts (
                    thread_id TEXT NOT NULL,
                    turn_id TEXT NOT NULL,
                    project_id TEXT,
                    project_title TEXT,
                    task_title TEXT,
                    observed_at REAL NOT NULL,
                    PRIMARY KEY(thread_id, turn_id)
                )
                """
            )
            try execute("PRAGMA user_version = \(Self.currentSchemaVersion)")
        }
    }

    private func loadAnalyticsEpochStartedAt() throws -> Date? {
        let statement = try prepare("SELECT started_at FROM analytics_epoch WHERE id = 1")
        defer { sqlite3_finalize(statement) }
        guard try stepRow(statement) else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    private func accountUsageRelativeToAnalyticsEpoch(
        _ snapshot: CodexAccountUsageSnapshot
    ) throws -> CodexAccountUsageSnapshot {
        guard let epoch = try loadAnalyticsEpochStartedAt() else { return snapshot }
        guard let baseline = try accountUsageBaseline(accountID: snapshot.accountID) else {
            try insertAccountUsageBaseline(snapshot, epochStartedAt: epoch)
            return accountUsageDelta(current: snapshot, baseline: snapshot)
        }
        return accountUsageDelta(current: snapshot, baseline: baseline)
    }

    private func accountUsageBaseline(accountID: String) throws -> CodexAccountUsageSnapshot? {
        let statement = try prepare("SELECT payload FROM account_usage_baselines WHERE account_id = ?")
        defer { sqlite3_finalize(statement) }
        bind(accountID, to: 1, in: statement)
        guard try stepRow(statement), let payload = columnData(statement, 0) else { return nil }
        return try JSONDecoder.limits.decode(CodexAccountUsageSnapshot.self, from: payload)
    }

    private func accountUsageObservedAt(accountID: String) throws -> Date? {
        let statement = try prepare("SELECT observed_at FROM account_usage_snapshots WHERE account_id = ?")
        defer { sqlite3_finalize(statement) }
        bind(accountID, to: 1, in: statement)
        guard try stepRow(statement) else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }

    private func insertAccountUsageBaseline(
        _ snapshot: CodexAccountUsageSnapshot,
        epochStartedAt: Date
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO account_usage_baselines (account_id, epoch_started_at, payload)
            VALUES (?, ?, ?)
            ON CONFLICT(account_id) DO UPDATE SET
                epoch_started_at = excluded.epoch_started_at,
                payload = excluded.payload
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(snapshot.accountID, to: 1, in: statement)
        bind(epochStartedAt.timeIntervalSince1970, to: 2, in: statement)
        bind(try JSONEncoder.limits.encode(snapshot), to: 3, in: statement)
        try stepDone(statement)
    }

    private func accountUsageDelta(
        current: CodexAccountUsageSnapshot,
        baseline: CodexAccountUsageSnapshot
    ) -> CodexAccountUsageSnapshot {
        let baselineByDay = baseline.dailyActivity.reduce(into: [Date: Int64]()) { result, bucket in
            let day = Self.startOfUTCDay(bucket.date)
            result[day] = max(result[day] ?? 0, bucket.tokens)
        }
        let daily = current.dailyActivity.compactMap { bucket -> CodexDailyTokenActivity? in
            let day = Self.startOfUTCDay(bucket.date)
            let tokens = max(0, bucket.tokens - (baselineByDay[day] ?? 0))
            return tokens > 0 ? CodexDailyTokenActivity(date: day, tokens: tokens) : nil
        }
        let lifetime: Int64? = {
            guard let current = current.summary.lifetimeTokens,
                  let baseline = baseline.summary.lifetimeTokens else { return nil }
            return max(0, current - baseline)
        }()
        return CodexAccountUsageSnapshot(
            accountID: current.accountID,
            observedAt: current.observedAt,
            summary: CodexAccountUsageSummary(
                lifetimeTokens: lifetime,
                peakDailyTokens: daily.map(\.tokens).max(),
                longestRunningTurnSeconds: nil,
                currentStreakDays: nil,
                longestStreakDays: nil
            ),
            dailyActivity: daily
        )
    }

    private func combinedAccountUsage(
        baseline: CodexAccountUsageSnapshot,
        delta: CodexAccountUsageSnapshot
    ) -> CodexAccountUsageSnapshot {
        var daily = baseline.dailyActivity.reduce(into: [Date: Int64]()) { result, bucket in
            result[Self.startOfUTCDay(bucket.date), default: 0] += bucket.tokens
        }
        for bucket in delta.dailyActivity {
            daily[Self.startOfUTCDay(bucket.date), default: 0] += bucket.tokens
        }
        let lifetime: Int64? = {
            guard let baseline = baseline.summary.lifetimeTokens else { return nil }
            return baseline + (delta.summary.lifetimeTokens ?? 0)
        }()
        let activity = daily.map { CodexDailyTokenActivity(date: $0.key, tokens: $0.value) }
            .sorted { $0.date < $1.date }
        return CodexAccountUsageSnapshot(
            accountID: baseline.accountID,
            observedAt: max(baseline.observedAt, delta.observedAt),
            summary: CodexAccountUsageSummary(
                lifetimeTokens: lifetime,
                peakDailyTokens: activity.map(\.tokens).max(),
                longestRunningTurnSeconds: nil,
                currentStreakDays: nil,
                longestStreakDays: nil
            ),
            dailyActivity: activity
        )
    }

    private func clearAnalyticsTables() throws {
        for table in [
            "usage_events", "daily_usage", "account_usage_snapshots", "account_daily_activity",
            "limit_observations", "latest_limit_snapshots", "endpoint_statuses", "thread_usage_evidence",
        ] {
            try execute("DELETE FROM \(table)")
        }
    }

    private func incrementDailyAggregate(for event: CodexUsageEvent, rateRevisionID: String) throws {
        for (tier, usage) in dailyComponents(for: event) {
            try incrementDailyAggregate(for: event, rateRevisionID: rateRevisionID, tier: tier, usage: usage)
        }
    }

    private func incrementDailyAggregate(
        for event: CodexUsageEvent,
        rateRevisionID: String,
        tier: OpenAIContextTier,
        usage: CodexTokenUsage
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO daily_usage (
                day, account_id, model_id, attribution, speed, source, rate_revision_id, context_tier,
                input_tokens, cached_input_tokens,
                cache_write_input_tokens, output_tokens, reasoning_output_tokens, total_tokens
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(day, account_id, model_id, attribution, speed, source, rate_revision_id, context_tier) DO UPDATE SET
                input_tokens = input_tokens + excluded.input_tokens,
                cached_input_tokens = cached_input_tokens + excluded.cached_input_tokens,
                cache_write_input_tokens = cache_write_input_tokens + excluded.cache_write_input_tokens,
                output_tokens = output_tokens + excluded.output_tokens,
                reasoning_output_tokens = reasoning_output_tokens + excluded.reasoning_output_tokens,
                total_tokens = total_tokens + excluded.total_tokens
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(Self.startOfUTCDay(event.occurredAt).timeIntervalSince1970, to: 1, in: statement)
        bind(event.accountID ?? "", to: 2, in: statement)
        bind(event.resolvedModel ?? "unattributed", to: 3, in: statement)
        bind(event.attribution.rawValue, to: 4, in: statement)
        bind(event.speed ?? "", to: 5, in: statement)
        bind(event.source.rawValue, to: 6, in: statement)
        bind(rateRevisionID, to: 7, in: statement)
        bind(tier.rawValue, to: 8, in: statement)
        bind(usage.inputTokens, to: 9, in: statement)
        bind(usage.cachedInputTokens, to: 10, in: statement)
        bind(usage.cacheWriteInputTokens, to: 11, in: statement)
        bind(usage.outputTokens, to: 12, in: statement)
        bind(usage.reasoningOutputTokens, to: 13, in: statement)
        bind(usage.totalTokens, to: 14, in: statement)
        try stepDone(statement)
    }

    private func decrementDailyAggregate(for event: CodexUsageEvent, rateRevisionID: String) throws {
        for (tier, usage) in dailyComponents(for: event) {
            try decrementDailyAggregate(for: event, rateRevisionID: rateRevisionID, tier: tier, usage: usage)
        }
        try execute("DELETE FROM daily_usage WHERE total_tokens <= 0")
    }

    private func decrementDailyAggregate(
        for event: CodexUsageEvent,
        rateRevisionID: String,
        tier: OpenAIContextTier,
        usage: CodexTokenUsage
    ) throws {
        let statement = try prepare(
            """
            UPDATE daily_usage SET
                input_tokens = input_tokens - ?,
                cached_input_tokens = cached_input_tokens - ?,
                cache_write_input_tokens = cache_write_input_tokens - ?,
                output_tokens = output_tokens - ?,
                reasoning_output_tokens = reasoning_output_tokens - ?,
                total_tokens = total_tokens - ?
            WHERE day = ? AND account_id = ? AND model_id = ? AND attribution = ?
              AND speed = ? AND source = ? AND rate_revision_id = ? AND context_tier = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(usage.inputTokens, to: 1, in: statement)
        bind(usage.cachedInputTokens, to: 2, in: statement)
        bind(usage.cacheWriteInputTokens, to: 3, in: statement)
        bind(usage.outputTokens, to: 4, in: statement)
        bind(usage.reasoningOutputTokens, to: 5, in: statement)
        bind(usage.totalTokens, to: 6, in: statement)
        bind(Self.startOfUTCDay(event.occurredAt).timeIntervalSince1970, to: 7, in: statement)
        bind(event.accountID ?? "", to: 8, in: statement)
        bind(event.resolvedModel ?? "unattributed", to: 9, in: statement)
        bind(event.attribution.rawValue, to: 10, in: statement)
        bind(event.speed ?? "", to: 11, in: statement)
        bind(event.source.rawValue, to: 12, in: statement)
        bind(rateRevisionID, to: 13, in: statement)
        bind(tier.rawValue, to: 14, in: statement)
        try stepDone(statement)
    }

    private func dailyComponents(for event: CodexUsageEvent) -> [(OpenAIContextTier, CodexTokenUsage)] {
        let breakdown: CodexUsageContextBreakdown
        if let candidate = event.contextBreakdown, candidate.total == event.usage {
            breakdown = candidate
        } else {
            breakdown = CodexUsageContextBreakdown(unknown: event.usage)
        }
        return OpenAIContextTier.allCases.compactMap { tier in
            let usage = breakdown.usage(for: tier)
            return usage.totalTokens > 0 ? (tier, usage) : nil
        }
    }

    private func effectiveRateCardRevisionID(at date: Date) throws -> String? {
        let effective = try prepare(
            """
            SELECT id FROM rate_card_revisions
            WHERE observed_at <= ?
            ORDER BY observed_at DESC LIMIT 1
            """
        )
        defer { sqlite3_finalize(effective) }
        bind(date.timeIntervalSince1970, to: 1, in: effective)
        if try stepRow(effective) { return columnString(effective, 0) }

        let earliest = try prepare("SELECT id FROM rate_card_revisions ORDER BY observed_at ASC LIMIT 1")
        defer { sqlite3_finalize(earliest) }
        guard try stepRow(earliest) else { return nil }
        return columnString(earliest, 0)
    }

    private func reconcilableRawUsageEvents(threadID: String) throws -> [StoredRawUsageEvent] {
        let statement = try prepare(
            """
            \(Self.rawUsageEventSelect)
            WHERE thread_id = ? AND attribution IN (?, ?)
            """
        )
        defer { sqlite3_finalize(statement) }
        bind(threadID, to: 1, in: statement)
        bind(CodexUsageAttribution.unattributed.rawValue, to: 2, in: statement)
        bind(CodexUsageAttribution.serverMatched.rawValue, to: 3, in: statement)
        return try decodeRawUsageEvents(statement)
    }

    private func unassignedRateRawUsageEvents() throws -> [StoredRawUsageEvent] {
        let statement = try prepare("\(Self.rawUsageEventSelect) WHERE rate_revision_id = ''")
        defer { sqlite3_finalize(statement) }
        return try decodeRawUsageEvents(statement)
    }

    private func decodeRawUsageEvents(_ statement: OpaquePointer) throws -> [StoredRawUsageEvent] {
        var result: [StoredRawUsageEvent] = []
        while try stepRow(statement) {
            guard let threadID = columnString(statement, 1),
                  let turnID = columnString(statement, 2),
                  let attributionRaw = columnString(statement, 10),
                  let attribution = CodexUsageAttribution(rawValue: attributionRaw),
                  let sourceRaw = columnString(statement, 11),
                  let source = CodexUsageSource(rawValue: sourceRaw),
                  let rateRevisionID = columnString(statement, 12) else { continue }
            result.append(
                StoredRawUsageEvent(
                    event: CodexUsageEvent(
                        threadID: threadID,
                        turnID: turnID,
                        counterEpoch: Int(sqlite3_column_int64(statement, 3)),
                        occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                        accountID: columnString(statement, 5),
                        requestedModel: columnString(statement, 6),
                        billedModel: columnString(statement, 7),
                        reasoningEffort: columnString(statement, 8),
                        speed: columnString(statement, 9),
                        usage: CodexTokenUsage(
                            inputTokens: sqlite3_column_int64(statement, 13),
                            cachedInputTokens: sqlite3_column_int64(statement, 14),
                            cacheWriteInputTokens: sqlite3_column_int64(statement, 15),
                            outputTokens: sqlite3_column_int64(statement, 16),
                            reasoningOutputTokens: sqlite3_column_int64(statement, 17),
                            totalTokens: sqlite3_column_int64(statement, 18)
                        ),
                        contextBreakdown: try columnData(statement, 19).map {
                            try JSONDecoder.limits.decode(CodexUsageContextBreakdown.self, from: $0)
                        },
                        attribution: attribution,
                        source: source
                    ),
                    rateRevisionID: rateRevisionID
                )
            )
        }
        return result
    }

    private static let rawUsageEventSelect = """
        SELECT id, thread_id, turn_id, counter_epoch, occurred_at, account_id,
               requested_model, billed_model, reasoning_effort, speed, attribution,
               source, rate_revision_id, input_tokens, cached_input_tokens,
               cache_write_input_tokens, output_tokens, reasoning_output_tokens, total_tokens,
               context_breakdown
        FROM usage_events
        """

    private func loadAccountUsage() throws -> [String: CodexAccountUsageSnapshot] {
        var summaries: [String: (Date, CodexAccountUsageSummary)] = [:]
        let statement = try prepare("SELECT account_id, observed_at, summary_json FROM account_usage_snapshots")
        defer { sqlite3_finalize(statement) }
        while try stepRow(statement) {
            guard let accountID = columnString(statement, 0), let data = columnData(statement, 2) else { continue }
            let summary = try JSONDecoder.limits.decode(CodexAccountUsageSummary.self, from: data)
            summaries[accountID] = (Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), summary)
        }

        var activity: [String: [CodexDailyTokenActivity]] = [:]
        let daily = try prepare("SELECT account_id, day, tokens FROM account_daily_activity ORDER BY day")
        defer { sqlite3_finalize(daily) }
        while try stepRow(daily) {
            guard let accountID = columnString(daily, 0) else { continue }
            activity[accountID, default: []].append(
                CodexDailyTokenActivity(
                    date: Date(timeIntervalSince1970: sqlite3_column_double(daily, 1)),
                    tokens: sqlite3_column_int64(daily, 2)
                )
            )
        }

        return summaries.reduce(into: [:]) { result, element in
            result[element.key] = CodexAccountUsageSnapshot(
                accountID: element.key,
                observedAt: element.value.0,
                summary: element.value.1,
                dailyActivity: activity[element.key] ?? []
            )
        }
    }

    private func loadDailyUsage() throws -> [CodexStoredDailyUsage] {
        let statement = try prepare(
            """
            SELECT day, account_id, model_id, attribution, speed, source, rate_revision_id, context_tier,
                   input_tokens, cached_input_tokens, cache_write_input_tokens,
                   output_tokens, reasoning_output_tokens, total_tokens
            FROM daily_usage ORDER BY day, model_id
            """
        )
        defer { sqlite3_finalize(statement) }
        var result: [CodexStoredDailyUsage] = []
        while try stepRow(statement) {
            guard
                let model = columnString(statement, 2),
                let attributionRaw = columnString(statement, 3),
                let attribution = CodexUsageAttribution(rawValue: attributionRaw),
                let speedValue = columnString(statement, 4),
                let sourceRaw = columnString(statement, 5),
                let source = CodexUsageSource(rawValue: sourceRaw),
                let rateRevisionID = columnString(statement, 6),
                let contextTierRaw = columnString(statement, 7),
                let contextTier = OpenAIContextTier(rawValue: contextTierRaw)
            else { continue }
            let account = columnString(statement, 1).flatMap { $0.isEmpty ? nil : $0 }
            result.append(
                CodexStoredDailyUsage(
                    date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    accountID: account,
                    modelID: model,
                    attribution: attribution,
                    speed: speedValue.isEmpty ? nil : speedValue,
                    source: source,
                    rateRevisionID: rateRevisionID.isEmpty ? nil : rateRevisionID,
                    contextTier: contextTier,
                    usage: CodexTokenUsage(
                        inputTokens: sqlite3_column_int64(statement, 8),
                        cachedInputTokens: sqlite3_column_int64(statement, 9),
                        cacheWriteInputTokens: sqlite3_column_int64(statement, 10),
                        outputTokens: sqlite3_column_int64(statement, 11),
                        reasoningOutputTokens: sqlite3_column_int64(statement, 12),
                        totalTokens: sqlite3_column_int64(statement, 13)
                    )
                )
            )
        }
        return result
    }

    private func loadWorkUsage() throws -> [CodexStoredWorkUsage] {
        let statement = try prepare(
            """
            SELECT
                CAST(events.occurred_at / 86400 AS INTEGER) * 86400 AS day,
                events.account_id,
                events.thread_id,
                COALESCE(turn_context.project_id, thread_context.project_id),
                COALESCE(turn_context.project_title, thread_context.project_title),
                COALESCE(turn_context.task_title, thread_context.task_title),
                SUM(events.input_tokens),
                SUM(events.cached_input_tokens),
                SUM(events.cache_write_input_tokens),
                SUM(events.output_tokens),
                SUM(events.reasoning_output_tokens),
                SUM(events.total_tokens)
            FROM usage_events AS events
            LEFT JOIN rollout_contexts AS turn_context
              ON turn_context.thread_id = events.thread_id
             AND turn_context.turn_id = events.turn_id
            LEFT JOIN rollout_contexts AS thread_context
              ON thread_context.thread_id = events.thread_id
             AND thread_context.turn_id = ''
            GROUP BY day, events.account_id, events.thread_id,
                     COALESCE(turn_context.project_id, thread_context.project_id),
                     COALESCE(turn_context.project_title, thread_context.project_title),
                     COALESCE(turn_context.task_title, thread_context.task_title)
            ORDER BY day, events.thread_id
            """
        )
        defer { sqlite3_finalize(statement) }
        var result: [CodexStoredWorkUsage] = []
        while try stepRow(statement) {
            guard let threadID = columnString(statement, 2) else { continue }
            let accountID = columnString(statement, 1).flatMap { $0.isEmpty ? nil : $0 }
            result.append(
                CodexStoredWorkUsage(
                    date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    accountID: accountID,
                    threadID: threadID,
                    projectID: columnString(statement, 3),
                    projectTitle: columnString(statement, 4),
                    taskTitle: columnString(statement, 5),
                    usage: CodexTokenUsage(
                        inputTokens: sqlite3_column_int64(statement, 6),
                        cachedInputTokens: sqlite3_column_int64(statement, 7),
                        cacheWriteInputTokens: sqlite3_column_int64(statement, 8),
                        outputTokens: sqlite3_column_int64(statement, 9),
                        reasoningOutputTokens: sqlite3_column_int64(statement, 10),
                        totalTokens: sqlite3_column_int64(statement, 11)
                    )
                )
            )
        }
        return result
    }

    private func loadLimitObservations() throws -> [String: [CodexLimitObservation]] {
        let statement = try prepare(
            """
            SELECT account_id, limit_id, window_kind, observed_at,
                   used_percent, resets_at, window_duration_minutes
            FROM limit_observations ORDER BY observed_at
            """
        )
        defer { sqlite3_finalize(statement) }
        var result: [String: [CodexLimitObservation]] = [:]
        while try stepRow(statement) {
            guard
                let accountID = columnString(statement, 0),
                let limitID = columnString(statement, 1),
                let windowRaw = columnString(statement, 2),
                let window = CodexLimitWindowKind(rawValue: windowRaw)
            else { continue }
            let reset: Date? = sqlite3_column_type(statement, 5) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            let duration: Int64? = sqlite3_column_type(statement, 6) == SQLITE_NULL
                ? nil
                : sqlite3_column_int64(statement, 6)
            result[accountID, default: []].append(
                CodexLimitObservation(
                    accountID: accountID,
                    limitID: limitID,
                    window: window,
                    observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    usedPercent: Int(sqlite3_column_int64(statement, 4)),
                    resetsAt: reset,
                    windowDurationMinutes: duration
                )
            )
        }
        return result
    }

    private func loadLatestLimits() throws -> [String: CodexRateLimitsSnapshot] {
        let statement = try prepare("SELECT account_id, payload FROM latest_limit_snapshots")
        defer { sqlite3_finalize(statement) }
        var result: [String: CodexRateLimitsSnapshot] = [:]
        while try stepRow(statement) {
            guard let accountID = columnString(statement, 0), let data = columnData(statement, 1) else { continue }
            result[accountID] = try JSONDecoder.limits.decode(CodexRateLimitsSnapshot.self, from: data)
        }
        return result
    }

    private func loadEndpointStatuses() throws -> [String: [CodexUsageEndpointKind: CodexUsageEndpointStatus]] {
        let statement = try prepare(
            "SELECT account_id, endpoint, attempted_at, successful_at, error_message FROM endpoint_statuses"
        )
        defer { sqlite3_finalize(statement) }
        var result: [String: [CodexUsageEndpointKind: CodexUsageEndpointStatus]] = [:]
        while try stepRow(statement) {
            guard let accountID = columnString(statement, 0),
                  let endpointRaw = columnString(statement, 1),
                  let endpoint = CodexUsageEndpointKind(rawValue: endpointRaw) else { continue }
            let successfulAt = sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            result[accountID, default: [:]][endpoint] = CodexUsageEndpointStatus(
                accountID: accountID,
                endpoint: endpoint,
                attemptedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                successfulAt: successfulAt,
                errorMessage: columnString(statement, 4)
            )
        }
        return result
    }

    private func loadThreadUsageEvidence() throws -> [String: CodexThreadUsageEvidence] {
        let statement = try prepare("SELECT thread_id, payload FROM thread_usage_evidence")
        defer { sqlite3_finalize(statement) }
        var result: [String: CodexThreadUsageEvidence] = [:]
        while try stepRow(statement) {
            guard let threadID = columnString(statement, 0), let data = columnData(statement, 1) else { continue }
            result[threadID] = try JSONDecoder.limits.decode(CodexThreadUsageEvidence.self, from: data)
        }
        return result
    }

    private func threadUsageEvidence(threadID: String) throws -> CodexThreadUsageEvidence? {
        let statement = try prepare("SELECT payload FROM thread_usage_evidence WHERE thread_id = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bind(threadID, to: 1, in: statement)
        guard try stepRow(statement), let data = columnData(statement, 0) else { return nil }
        return try JSONDecoder.limits.decode(CodexThreadUsageEvidence.self, from: data)
    }

    private func threadEvidenceAccountID(threadID: String) throws -> String? {
        let statement = try prepare("SELECT account_id FROM thread_usage_evidence WHERE thread_id = ?")
        defer { sqlite3_finalize(statement) }
        bind(threadID, to: 1, in: statement)
        guard try stepRow(statement) else { return nil }
        return columnString(statement, 0)
    }

    private func loadRateCardRevisions() throws -> [OpenAIRateCardRevision] {
        let statement = try prepare(
            "SELECT payload FROM rate_card_revisions ORDER BY observed_at"
        )
        defer { sqlite3_finalize(statement) }
        var result: [OpenAIRateCardRevision] = []
        while try stepRow(statement) {
            guard let data = columnData(statement, 0) else { continue }
            result.append(try JSONDecoder.limits.decode(OpenAIRateCardRevision.self, from: data))
        }
        return result
    }

    private func rateCardRevision(id: String) throws -> OpenAIRateCardRevision? {
        let statement = try prepare("SELECT payload FROM rate_card_revisions WHERE id = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bind(id, to: 1, in: statement)
        guard try stepRow(statement), let data = columnData(statement, 0) else { return nil }
        return try JSONDecoder.limits.decode(OpenAIRateCardRevision.self, from: data)
    }

    private func transaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try operation()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func requireOpen() throws {
        guard access != nil else { throw CodexUsageRepositoryError.notOpened }
    }

    private func requireWritable() throws {
        try requireOpen()
        if case .readOnlyRecovery(let version) = access {
            throw CodexUsageRepositoryError.readOnlyRecovery(schemaVersion: version)
        }
    }

    private func handle() throws -> OpaquePointer {
        guard let connection else { throw CodexUsageRepositoryError.notOpened }
        return connection.handle
    }

    private func execute(_ sql: String) throws {
        let database = try handle()
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorPointer)
            throw CodexUsageRepositoryError.statementFailed(message)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard try stepRow(statement) else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        let database = try handle()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CodexUsageRepositoryError.statementFailed(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw CodexUsageRepositoryError.statementFailed(String(cString: sqlite3_errmsg(try handle())))
        }
    }

    private func stepRow(_ statement: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw CodexUsageRepositoryError.statementFailed(String(cString: sqlite3_errmsg(try handle())))
    }

    private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
    }

    private func bind(_ value: Int64?, to index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, value)
    }

    private func bind(_ value: Double?, to index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, value)
    }

    private func bind(_ value: Data, to index: Int32, in statement: OpaquePointer) {
        _ = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Self.sqliteTransient)
        }
    }

    private func columnString(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func columnData(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public static func startOfUTCDay(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.startOfDay(for: date)
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(_ handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close_v2(handle)
    }
}

private struct StoredRawUsageEvent {
    let event: CodexUsageEvent
    let rateRevisionID: String
}
