import Foundation

@frozen public enum CodexUsageAttribution: String, Codable, Hashable, Sendable {
    case confirmed
    case serverMatched
    case unattributed
}

@frozen public enum CodexUsageSource: String, Codable, Hashable, Sendable {
    case appServer
    case localRollout
}

@frozen public enum OpenAIContextTier: String, CaseIterable, Codable, Hashable, Sendable {
    case standard
    case long
    case unknown
}

public struct CodexTokenUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int64
    public var cachedInputTokens: Int64
    public var cacheWriteInputTokens: Int64
    public var outputTokens: Int64
    public var reasoningOutputTokens: Int64
    public var totalTokens: Int64

    public init(
        inputTokens: Int64 = 0,
        cachedInputTokens: Int64 = 0,
        cacheWriteInputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        reasoningOutputTokens: Int64 = 0,
        totalTokens: Int64 = 0
    ) {
        self.inputTokens = max(0, inputTokens)
        self.cachedInputTokens = max(0, cachedInputTokens)
        self.cacheWriteInputTokens = max(0, cacheWriteInputTokens)
        self.outputTokens = max(0, outputTokens)
        self.reasoningOutputTokens = max(0, reasoningOutputTokens)
        self.totalTokens = max(0, totalTokens)
    }

    public static let zero = CodexTokenUsage()

    public var billableInputTokens: Int64 {
        max(0, inputTokens - cachedInputTokens - cacheWriteInputTokens)
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            cacheWriteInputTokens: lhs.cacheWriteInputTokens + rhs.cacheWriteInputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            reasoningOutputTokens: lhs.reasoningOutputTokens + rhs.reasoningOutputTokens,
            totalTokens: lhs.totalTokens + rhs.totalTokens
        )
    }

    public func monotonicDelta(from previous: Self) -> Self? {
        let values = [
            inputTokens - previous.inputTokens,
            cachedInputTokens - previous.cachedInputTokens,
            cacheWriteInputTokens - previous.cacheWriteInputTokens,
            outputTokens - previous.outputTokens,
            reasoningOutputTokens - previous.reasoningOutputTokens,
            totalTokens - previous.totalTokens,
        ]
        guard values.allSatisfy({ $0 >= 0 }) else { return nil }
        return Self(
            inputTokens: values[0],
            cachedInputTokens: values[1],
            cacheWriteInputTokens: values[2],
            outputTokens: values[3],
            reasoningOutputTokens: values[4],
            totalTokens: values[5]
        )
    }
}

public struct CodexUsageContextBreakdown: Codable, Hashable, Sendable {
    public let standard: CodexTokenUsage
    public let long: CodexTokenUsage
    public let unknown: CodexTokenUsage

    public init(
        standard: CodexTokenUsage = .zero,
        long: CodexTokenUsage = .zero,
        unknown: CodexTokenUsage = .zero
    ) {
        self.standard = standard
        self.long = long
        self.unknown = unknown
    }

    public var total: CodexTokenUsage { standard + long + unknown }

    public func usage(for tier: OpenAIContextTier) -> CodexTokenUsage {
        switch tier {
        case .standard: standard
        case .long: long
        case .unknown: unknown
        }
    }
}

public struct CodexUsageEvent: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let threadID: String
    public let turnID: String
    public let counterEpoch: Int
    public let occurredAt: Date
    public let accountID: String?
    public let requestedModel: String?
    public let billedModel: String?
    public let reasoningEffort: String?
    public let speed: String?
    public let usage: CodexTokenUsage
    public let contextBreakdown: CodexUsageContextBreakdown?
    public let attribution: CodexUsageAttribution
    public let source: CodexUsageSource

    public init(
        threadID: String,
        turnID: String,
        counterEpoch: Int,
        occurredAt: Date,
        accountID: String?,
        requestedModel: String?,
        billedModel: String?,
        reasoningEffort: String?,
        speed: String?,
        usage: CodexTokenUsage,
        contextBreakdown: CodexUsageContextBreakdown? = nil,
        attribution: CodexUsageAttribution,
        source: CodexUsageSource
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.counterEpoch = counterEpoch
        self.id = "\(threadID)|\(turnID)|\(counterEpoch)"
        self.occurredAt = occurredAt
        self.accountID = accountID
        self.requestedModel = requestedModel
        self.billedModel = billedModel
        self.reasoningEffort = reasoningEffort
        self.speed = speed
        self.usage = usage
        self.contextBreakdown = contextBreakdown
        self.attribution = attribution
        self.source = source
    }

    public var resolvedModel: String? { billedModel ?? requestedModel }
}

public struct CodexAccountUsageSummary: Codable, Hashable, Sendable {
    public let lifetimeTokens: Int64?
    public let peakDailyTokens: Int64?
    public let longestRunningTurnSeconds: Int64?
    public let currentStreakDays: Int64?
    public let longestStreakDays: Int64?

    public init(
        lifetimeTokens: Int64?,
        peakDailyTokens: Int64?,
        longestRunningTurnSeconds: Int64?,
        currentStreakDays: Int64?,
        longestStreakDays: Int64?
    ) {
        self.lifetimeTokens = lifetimeTokens
        self.peakDailyTokens = peakDailyTokens
        self.longestRunningTurnSeconds = longestRunningTurnSeconds
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
    }
}

public struct CodexDailyTokenActivity: Codable, Hashable, Identifiable, Sendable {
    public let date: Date
    public let tokens: Int64

    public init(date: Date, tokens: Int64) {
        self.date = date
        self.tokens = max(0, tokens)
    }

    public var id: Date { date }
}

public struct CodexAccountUsageSnapshot: Codable, Hashable, Sendable {
    public let accountID: String
    public let observedAt: Date
    public let summary: CodexAccountUsageSummary
    public let dailyActivity: [CodexDailyTokenActivity]

    public init(
        accountID: String,
        observedAt: Date,
        summary: CodexAccountUsageSummary,
        dailyActivity: [CodexDailyTokenActivity]
    ) {
        self.accountID = accountID
        self.observedAt = observedAt
        self.summary = summary
        self.dailyActivity = dailyActivity.sorted { $0.date < $1.date }
    }
}

public struct CodexThreadUsageEvidence: Codable, Hashable, Identifiable, Sendable {
    public struct Group: Codable, Hashable, Sendable {
        public let model: String?
        public let reasoningEffort: String?
        public let speed: String?
        public let usage: CodexTokenUsage
        public let estimatedCreditsMicros: Int64

        public init(
            model: String?,
            reasoningEffort: String?,
            speed: String?,
            usage: CodexTokenUsage,
            estimatedCreditsMicros: Int64
        ) {
            self.model = model
            self.reasoningEffort = reasoningEffort
            self.speed = speed
            self.usage = usage
            self.estimatedCreditsMicros = estimatedCreditsMicros
        }
    }

    public let threadID: String
    public let accountID: String
    public let observedAt: Date
    public let estimatedCreditsMicros: Int64
    public let estimatedUSDMicros: Int64?
    public let groups: [Group]

    public init(
        threadID: String,
        accountID: String,
        observedAt: Date,
        estimatedCreditsMicros: Int64,
        estimatedUSDMicros: Int64?,
        groups: [Group]
    ) {
        self.threadID = threadID
        self.accountID = accountID
        self.observedAt = observedAt
        self.estimatedCreditsMicros = estimatedCreditsMicros
        self.estimatedUSDMicros = estimatedUSDMicros
        self.groups = groups
    }

    public var id: String { threadID }
}

@frozen public enum CodexLimitWindowKind: String, Codable, Hashable, Sendable {
    case primary
    case secondary
    case individual
}

public struct CodexLimitObservation: Codable, Hashable, Identifiable, Sendable {
    public let accountID: String
    public let limitID: String
    public let window: CodexLimitWindowKind
    public let observedAt: Date
    public let usedPercent: Int
    public let resetsAt: Date?
    public let windowDurationMinutes: Int64?

    public init(
        accountID: String,
        limitID: String,
        window: CodexLimitWindowKind,
        observedAt: Date,
        usedPercent: Int,
        resetsAt: Date?,
        windowDurationMinutes: Int64?
    ) {
        self.accountID = accountID
        self.limitID = limitID
        self.window = window
        self.observedAt = observedAt
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetsAt = resetsAt
        self.windowDurationMinutes = windowDurationMinutes
    }

    public var id: String {
        "\(accountID)|\(limitID)|\(window.rawValue)|\(Int64(observedAt.timeIntervalSince1970 * 1_000))"
    }
}

/// The latest complete server response for one account. Historical burn uses
/// `CodexLimitObservation`; this record preserves presentation-only fields such
/// as credits and individual spend controls without putting them in state.json.
public struct CodexRateLimitsSnapshot: Codable, Hashable, Sendable {
    public let accountID: String
    public let observedAt: Date
    public let successfulObservedAt: Date?
    public let primary: RateLimitSnapshotModel?
    public let byLimitID: [String: RateLimitSnapshotModel]?
    public let errorMessage: String?

    public init(
        accountID: String,
        observedAt: Date,
        successfulObservedAt: Date? = nil,
        primary: RateLimitSnapshotModel?,
        byLimitID: [String: RateLimitSnapshotModel]?,
        errorMessage: String?
    ) {
        self.accountID = accountID
        self.observedAt = observedAt
        self.successfulObservedAt = successfulObservedAt ?? (errorMessage == nil ? observedAt : nil)
        self.primary = primary
        self.byLimitID = byLimitID
        self.errorMessage = errorMessage
    }

    public var limitsObservedAt: Date? { successfulObservedAt }

    public var observations: [CodexLimitObservation] {
        guard errorMessage == nil else { return [] }
        let snapshots: [(String, RateLimitSnapshotModel)]
        if let byLimitID, !byLimitID.isEmpty {
            snapshots = byLimitID.sorted { $0.key < $1.key }
        } else if let primary {
            snapshots = [(primary.limitId ?? "codex", primary)]
        } else {
            snapshots = []
        }
        return snapshots.flatMap { limitID, snapshot in
            var result: [CodexLimitObservation] = []
            if let window = snapshot.primary {
                result.append(observation(limitID: limitID, kind: .primary, window: window))
            }
            if let window = snapshot.secondary {
                result.append(observation(limitID: limitID, kind: .secondary, window: window))
            }
            if let individual = snapshot.individualLimit {
                result.append(
                    CodexLimitObservation(
                        accountID: accountID,
                        limitID: limitID,
                        window: .individual,
                        observedAt: observedAt,
                        usedPercent: max(0, 100 - individual.remainingPercent),
                        resetsAt: Date(timeIntervalSince1970: TimeInterval(individual.resetsAt)),
                        windowDurationMinutes: nil
                    )
                )
            }
            return result
        }
    }

    private func observation(
        limitID: String,
        kind: CodexLimitWindowKind,
        window: RateLimitWindowSnapshot
    ) -> CodexLimitObservation {
        CodexLimitObservation(
            accountID: accountID,
            limitID: limitID,
            window: kind,
            observedAt: observedAt,
            usedPercent: window.usedPercent,
            resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            windowDurationMinutes: window.windowDurationMins
        )
    }
}

public struct UsageCoverage: Codable, Hashable, Sendable {
    public let observedTokens: Int64
    public let serverTokens: Int64

    public init(observedTokens: Int64, serverTokens: Int64) {
        self.observedTokens = max(0, observedTokens)
        self.serverTokens = max(0, serverTokens)
    }

    public var fraction: Double? {
        guard serverTokens > 0 else { return nil }
        return Double(observedTokens) / Double(serverTokens)
    }

    public var hasInconsistentTotals: Bool { observedTokens > serverTokens && serverTokens > 0 }
}

@frozen public enum CodexUsageEndpointKind: String, Codable, Hashable, Sendable {
    case limits
    case usage
}

public struct CodexUsageEndpointStatus: Codable, Hashable, Sendable {
    public let accountID: String
    public let endpoint: CodexUsageEndpointKind
    public let attemptedAt: Date
    public let successfulAt: Date?
    public let errorMessage: String?

    public init(
        accountID: String,
        endpoint: CodexUsageEndpointKind,
        attemptedAt: Date,
        successfulAt: Date?,
        errorMessage: String?
    ) {
        self.accountID = accountID
        self.endpoint = endpoint
        self.attemptedAt = attemptedAt
        self.successfulAt = successfulAt
        self.errorMessage = errorMessage
    }
}

public struct OpenAIModelRate: Codable, Hashable, Sendable {
    public let modelID: String
    public let creditsPerMillionInput: Decimal?
    public let creditsPerMillionCachedInput: Decimal?
    public let creditsPerMillionOutput: Decimal?
    public let usdPerMillionInput: Decimal?
    public let usdPerMillionCachedInput: Decimal?
    public let usdPerMillionCacheWrite: Decimal?
    public let usdPerMillionOutput: Decimal?
    public let longContextThreshold: Int64?
    public let longContextInputMultiplier: Decimal?
    public let longContextCachedInputMultiplier: Decimal?
    public let longContextCacheWriteMultiplier: Decimal?
    public let longContextOutputMultiplier: Decimal?
    public let creditsFastMultiplier: Decimal?
    public let fastInputMultiplier: Decimal?
    public let fastCachedInputMultiplier: Decimal?
    public let fastCacheWriteMultiplier: Decimal?
    public let fastOutputMultiplier: Decimal?
    public let fastLongContextInputMultiplier: Decimal?
    public let fastLongContextCachedInputMultiplier: Decimal?
    public let fastLongContextCacheWriteMultiplier: Decimal?
    public let fastLongContextOutputMultiplier: Decimal?

    public init(
        modelID: String,
        creditsPerMillionInput: Decimal?,
        creditsPerMillionCachedInput: Decimal?,
        creditsPerMillionOutput: Decimal?,
        usdPerMillionInput: Decimal?,
        usdPerMillionCachedInput: Decimal?,
        usdPerMillionCacheWrite: Decimal?,
        usdPerMillionOutput: Decimal?,
        longContextThreshold: Int64? = nil,
        longContextInputMultiplier: Decimal? = nil,
        longContextCachedInputMultiplier: Decimal? = nil,
        longContextCacheWriteMultiplier: Decimal? = nil,
        longContextOutputMultiplier: Decimal? = nil,
        creditsFastMultiplier: Decimal? = nil,
        fastInputMultiplier: Decimal? = nil,
        fastCachedInputMultiplier: Decimal? = nil,
        fastCacheWriteMultiplier: Decimal? = nil,
        fastOutputMultiplier: Decimal? = nil,
        fastLongContextInputMultiplier: Decimal? = nil,
        fastLongContextCachedInputMultiplier: Decimal? = nil,
        fastLongContextCacheWriteMultiplier: Decimal? = nil,
        fastLongContextOutputMultiplier: Decimal? = nil
    ) {
        self.modelID = modelID
        self.creditsPerMillionInput = creditsPerMillionInput
        self.creditsPerMillionCachedInput = creditsPerMillionCachedInput
        self.creditsPerMillionOutput = creditsPerMillionOutput
        self.usdPerMillionInput = usdPerMillionInput
        self.usdPerMillionCachedInput = usdPerMillionCachedInput
        self.usdPerMillionCacheWrite = usdPerMillionCacheWrite
        self.usdPerMillionOutput = usdPerMillionOutput
        self.longContextThreshold = longContextThreshold
        self.longContextInputMultiplier = longContextInputMultiplier
        self.longContextCachedInputMultiplier = longContextCachedInputMultiplier
        self.longContextCacheWriteMultiplier = longContextCacheWriteMultiplier
        self.longContextOutputMultiplier = longContextOutputMultiplier
        self.creditsFastMultiplier = creditsFastMultiplier
        self.fastInputMultiplier = fastInputMultiplier
        self.fastCachedInputMultiplier = fastCachedInputMultiplier
        self.fastCacheWriteMultiplier = fastCacheWriteMultiplier
        self.fastOutputMultiplier = fastOutputMultiplier
        self.fastLongContextInputMultiplier = fastLongContextInputMultiplier
        self.fastLongContextCachedInputMultiplier = fastLongContextCachedInputMultiplier
        self.fastLongContextCacheWriteMultiplier = fastLongContextCacheWriteMultiplier
        self.fastLongContextOutputMultiplier = fastLongContextOutputMultiplier
    }
}

public struct OpenAIRateCardRevision: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let observedAt: Date
    public let checkedAt: Date?
    public let sourceHashes: [String: String]
    public let rates: [String: OpenAIModelRate]

    public init(
        id: String,
        observedAt: Date,
        checkedAt: Date? = nil,
        sourceHashes: [String: String],
        rates: [String: OpenAIModelRate]
    ) {
        self.id = id
        self.observedAt = observedAt
        self.checkedAt = checkedAt
        self.sourceHashes = sourceHashes
        self.rates = rates
    }

    public var lastCheckedAt: Date { checkedAt ?? observedAt }
}

@frozen public enum CodexUsagePeriod: String, Codable, Hashable, Sendable, CaseIterable {
    case currentWeek
    case last30Days
    case last6Months
    case lastYear
    case custom
    case all
}

public struct CodexUsageTotals: Codable, Hashable, Sendable {
    public let usage: CodexTokenUsage
    public let credits: Decimal?
    public let apiEquivalentUSD: Decimal?

    public init(usage: CodexTokenUsage, credits: Decimal?, apiEquivalentUSD: Decimal?) {
        self.usage = usage
        self.credits = credits
        self.apiEquivalentUSD = apiEquivalentUSD
    }
}

public struct CodexModelUsage: Codable, Hashable, Identifiable, Sendable {
    public let modelID: String
    public let totals: CodexUsageTotals

    public init(modelID: String, totals: CodexUsageTotals) {
        self.modelID = modelID
        self.totals = totals
    }

    public var id: String { modelID }
}

public struct CodexDailyUsage: Codable, Hashable, Identifiable, Sendable {
    public let date: Date
    public let totals: CodexUsageTotals
    public let models: [CodexModelUsage]

    public init(date: Date, totals: CodexUsageTotals, models: [CodexModelUsage] = []) {
        self.date = date
        self.totals = totals
        self.models = models
    }

    public var id: Date { date }
    public var modelAttributedTokens: Int64 {
        models.reduce(0) { $0 + $1.totals.usage.totalTokens }
    }
}

@frozen public enum TokenActivityIntensity: Int, CaseIterable, Codable, Hashable, Sendable {
    case none
    case firstQuartile
    case secondQuartile
    case thirdQuartile
    case fourthQuartile
}

/// Assigns every non-zero day to a quartile relative to the other visible days.
public struct TokenActivityIntensityScale: Hashable, Sendable {
    private let firstUpperBound: Int64
    private let secondUpperBound: Int64
    private let thirdUpperBound: Int64
    private let maximumTokens: Int64

    public init(tokens: [Int64]) {
        let positive = tokens.filter { $0 > 0 }.sorted()
        guard let maximum = positive.last else {
            firstUpperBound = 0
            secondUpperBound = 0
            thirdUpperBound = 0
            maximumTokens = 0
            return
        }
        firstUpperBound = Self.quartileUpperBound(1, in: positive)
        secondUpperBound = Self.quartileUpperBound(2, in: positive)
        thirdUpperBound = Self.quartileUpperBound(3, in: positive)
        maximumTokens = maximum
    }

    public func intensity(for tokens: Int64) -> TokenActivityIntensity {
        guard tokens > 0, maximumTokens > 0 else { return .none }
        if tokens >= maximumTokens { return .fourthQuartile }
        if tokens <= firstUpperBound { return .firstQuartile }
        if tokens <= secondUpperBound { return .secondQuartile }
        if tokens <= thirdUpperBound { return .thirdQuartile }
        return .fourthQuartile
    }

    private static func quartileUpperBound(_ quartile: Int, in sorted: [Int64]) -> Int64 {
        let rank = (sorted.count * quartile + 3) / 4
        return sorted[max(0, rank - 1)]
    }
}

/// Local evidence that explains which Codex thread and project produced usage.
/// The importer derives it from rollout metadata and the first user message;
/// semantic labels are never guessed from prompt wording.
public struct CodexRolloutContext: Codable, Hashable, Identifiable, Sendable {
    public let threadID: String
    public let turnID: String?
    public let projectID: String?
    public let projectTitle: String?
    public let taskTitle: String?
    public let observedAt: Date

    public init(
        threadID: String,
        turnID: String? = nil,
        projectID: String?,
        projectTitle: String?,
        taskTitle: String?,
        observedAt: Date
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.projectID = projectID
        self.projectTitle = projectTitle
        self.taskTitle = taskTitle
        self.observedAt = observedAt
    }

    public var id: String { "\(threadID)|\(turnID ?? "")" }
}

/// One UTC day of recent raw rollout usage, grouped by its real thread.
/// This is queried from `usage_events`; it is not a second persisted token total.
public struct CodexStoredWorkUsage: Hashable, Identifiable, Sendable {
    public let date: Date
    public let accountID: String?
    public let threadID: String
    public let projectID: String?
    public let projectTitle: String?
    public let taskTitle: String?
    public let usage: CodexTokenUsage

    public init(
        date: Date,
        accountID: String?,
        threadID: String,
        projectID: String?,
        projectTitle: String?,
        taskTitle: String?,
        usage: CodexTokenUsage
    ) {
        self.date = date
        self.accountID = accountID
        self.threadID = threadID
        self.projectID = projectID
        self.projectTitle = projectTitle
        self.taskTitle = taskTitle
        self.usage = usage
    }

    public var id: String {
        "\(Int64(date.timeIntervalSince1970))|\(accountID ?? "-")|\(threadID)"
    }
}

public struct CodexWorkUsageItem: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String?
    public let subtitle: String?
    public let tokens: Int64

    public init(id: String, title: String?, subtitle: String?, tokens: Int64) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.tokens = tokens
    }
}

/// Best-effort local explanation of recent usage. Its window is explicit
/// because raw rollout events have a shorter retention than headline totals.
public struct CodexWorkInsights: Codable, Hashable, Sendable {
    public let window: CodexUsageWindow
    public let observedTokens: Int64
    public let projects: [CodexWorkUsageItem]
    public let tasks: [CodexWorkUsageItem]
    public let isRetentionLimited: Bool

    public init(
        window: CodexUsageWindow,
        observedTokens: Int64,
        projects: [CodexWorkUsageItem],
        tasks: [CodexWorkUsageItem],
        isRetentionLimited: Bool
    ) {
        self.window = window
        self.observedTokens = observedTokens
        self.projects = projects
        self.tasks = tasks
        self.isRetentionLimited = isRetentionLimited
    }
}

@frozen public enum LimitBurnForecastState: String, Codable, Hashable, Sendable {
    case collecting
    case stable
    case exhaustsBeforeReset
    case lastsUntilReset
    case stale
}

public struct LimitBurnForecast: Codable, Hashable, Sendable {
    public let state: LimitBurnForecastState
    public let predictedExhaustionAt: Date?
    public let resetAt: Date?
    public let remainingPercent: Int?
    public let percentPerHour: Double?
    public let latestObservationAt: Date?

    public init(
        state: LimitBurnForecastState,
        predictedExhaustionAt: Date?,
        resetAt: Date?,
        remainingPercent: Int?,
        percentPerHour: Double?,
        latestObservationAt: Date? = nil
    ) {
        self.state = state
        self.predictedExhaustionAt = predictedExhaustionAt
        self.resetAt = resetAt
        self.remainingPercent = remainingPercent
        self.percentPerHour = percentPerHour
        self.latestObservationAt = latestObservationAt
    }
}

/// Stable identity of one server quota window. A model quota and the base
/// Codex quota are different even when their resets happen at the same time.
public struct CodexQuotaKey: Codable, Hashable, Sendable {
    public let limitID: String
    public let windowKind: CodexLimitWindowKind

    public init(limitID: String, windowKind: CodexLimitWindowKind) {
        self.limitID = limitID
        self.windowKind = windowKind
    }
}

/// The exact period used by both local daily rows and server daily rows.
public struct CodexUsageWindow: Codable, Hashable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        precondition(end >= start, "A usage window must end after it starts")
        self.start = start
        self.end = end
    }

    public func containsUTCDay(_ date: Date, calendar: Calendar = Self.utcCalendar) -> Bool {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        return dayStart < end && dayEnd > start
    }

    /// Builds a half-open UTC window that includes both selected calendar days.
    public static func inclusiveUTCDays(
        from firstDate: Date,
        through secondDate: Date,
        calendar: Calendar = Self.utcCalendar
    ) -> Self {
        let lower = min(firstDate, secondDate)
        let upper = max(firstDate, secondDate)
        let start = calendar.startOfDay(for: lower)
        let lastDay = calendar.startOfDay(for: upper)
        let end = calendar.date(byAdding: .day, value: 1, to: lastDay)
            ?? lastDay.addingTimeInterval(24 * 60 * 60)
        return Self(start: start, end: end)
    }

    public var firstUTCDay: Date {
        Self.utcCalendar.startOfDay(for: start)
    }

    public var lastIncludedUTCDay: Date {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return firstUTCDay }
        let instantInsideWindow = end.addingTimeInterval(-min(1, duration / 2))
        return Self.utcCalendar.startOfDay(for: instantInsideWindow)
    }

    /// Turns an analytical window into the finite UTC-day range shown by charts and calendars.
    public func visibleUTCDayRange(observedDates: [Date], through now: Date) -> ClosedRange<Date> {
        let calendar = Self.utcCalendar
        let today = calendar.startOfDay(for: now)
        let upperBound = min(lastIncludedUTCDay, today)
        let requestedLowerBound: Date
        if start == .distantPast {
            requestedLowerBound = observedDates.map { calendar.startOfDay(for: $0) }.min() ?? upperBound
        } else {
            requestedLowerBound = firstUTCDay
        }
        return min(requestedLowerBound, upperBound)...upperBound
    }

    public static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

public struct CodexQuotaForecast: Codable, Hashable, Identifiable, Sendable {
    public let key: CodexQuotaKey
    public let title: String
    public let isBaseQuota: Bool
    public let forecast: LimitBurnForecast

    public init(
        key: CodexQuotaKey,
        title: String,
        isBaseQuota: Bool,
        forecast: LimitBurnForecast
    ) {
        self.key = key
        self.title = title
        self.isBaseQuota = isBaseQuota
        self.forecast = forecast
    }

    public var id: String { "\(key.limitID)|\(key.windowKind.rawValue)" }
}

public struct CodexQuotaRisk: Codable, Hashable, Sendable {
    public let accountID: String
    public let quotaKey: CodexQuotaKey

    public init(accountID: String, quotaKey: CodexQuotaKey) {
        self.accountID = accountID
        self.quotaKey = quotaKey
    }
}

public struct CodexAccountInsights: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let window: CodexUsageWindow
    public let localAccountID: UUID?
    public let label: String
    public let email: String
    public let planTitle: String
    public let monthlyPriceUSD: Decimal?
    public let quotaForecasts: [CodexQuotaForecast]
    public let totals: CodexUsageTotals
    public let effectiveSubscriptionUSDPerMillionTokens: Decimal?
    public let models: [CodexModelUsage]
    public let daily: [CodexDailyUsage]
    public let coverage: UsageCoverage?
    public let observedAt: Date?

    public init(
        id: String,
        window: CodexUsageWindow,
        localAccountID: UUID?,
        label: String,
        email: String,
        planTitle: String,
        monthlyPriceUSD: Decimal?,
        quotaForecasts: [CodexQuotaForecast],
        totals: CodexUsageTotals,
        effectiveSubscriptionUSDPerMillionTokens: Decimal?,
        models: [CodexModelUsage],
        daily: [CodexDailyUsage],
        coverage: UsageCoverage?,
        observedAt: Date?
    ) {
        self.id = id
        self.window = window
        self.localAccountID = localAccountID
        self.label = label
        self.email = email
        self.planTitle = planTitle
        self.monthlyPriceUSD = monthlyPriceUSD
        self.quotaForecasts = quotaForecasts
        self.totals = totals
        self.effectiveSubscriptionUSDPerMillionTokens = effectiveSubscriptionUSDPerMillionTokens
        self.models = models
        self.daily = daily
        self.coverage = coverage
        self.observedAt = observedAt
    }

    public var baseQuotaForecast: CodexQuotaForecast? {
        quotaForecasts.first(where: \.isBaseQuota)
    }

    public var riskiestQuotaForecast: CodexQuotaForecast? {
        quotaForecasts.min(by: CodexQuotaForecast.riskOrder)
    }
}

@frozen public enum OpenAIPriceMetric: String, CaseIterable, Codable, Hashable, Sendable {
    case creditsInput
    case creditsCachedInput
    case creditsOutput
    case creditsFastMultiplier
    case apiInput
    case apiCachedInput
    case apiCacheWrite
    case apiOutput
    case apiLongInput
    case apiLongCachedInput
    case apiLongCacheWrite
    case apiLongOutput
    case apiFastInput
    case apiFastCachedInput
    case apiFastCacheWrite
    case apiFastOutput
    case apiFastLongInput
    case apiFastLongCachedInput
    case apiFastLongCacheWrite
    case apiFastLongOutput

    public var usesUSD: Bool {
        switch self {
        case .apiInput, .apiCachedInput, .apiCacheWrite, .apiOutput,
             .apiLongInput, .apiLongCachedInput, .apiLongCacheWrite, .apiLongOutput,
             .apiFastInput, .apiFastCachedInput, .apiFastCacheWrite, .apiFastOutput,
             .apiFastLongInput, .apiFastLongCachedInput, .apiFastLongCacheWrite, .apiFastLongOutput:
            true
        case .creditsInput, .creditsCachedInput, .creditsOutput, .creditsFastMultiplier:
            false
        }
    }

    public var usesMultiplier: Bool { self == .creditsFastMultiplier }
}

public struct OpenAIPriceChange: Codable, Hashable, Identifiable, Sendable {
    public let modelID: String
    public let metric: OpenAIPriceMetric
    public let previousRevisionID: String
    public let currentRevisionID: String
    public let previousValue: Decimal
    public let currentValue: Decimal
    public let maximumPercentChange: Decimal

    public init(
        modelID: String,
        metric: OpenAIPriceMetric,
        previousRevisionID: String,
        currentRevisionID: String,
        previousValue: Decimal,
        currentValue: Decimal,
        maximumPercentChange: Decimal
    ) {
        self.modelID = modelID
        self.metric = metric
        self.previousRevisionID = previousRevisionID
        self.currentRevisionID = currentRevisionID
        self.previousValue = previousValue
        self.currentValue = currentValue
        self.maximumPercentChange = maximumPercentChange
    }

    public var id: String { "\(currentRevisionID)|\(modelID)" }
}

public struct CodexInsightsSnapshot: Codable, Hashable, Sendable {
    public let period: CodexUsagePeriod
    public let window: CodexUsageWindow
    public let generatedAt: Date
    public let accounts: [CodexAccountInsights]
    public let totals: CodexUsageTotals
    public let models: [CodexModelUsage]
    public let daily: [CodexDailyUsage]
    public let nearestRisk: CodexQuotaRisk?
    public let totalMonthlySubscriptionUSD: Decimal?
    public let effectiveSubscriptionUSDPerMillionTokens: Decimal?
    public let coverage: UsageCoverage?
    public let unattributed: CodexUnattributedInsights?
    public let work: CodexWorkInsights?
    public let priceChange: OpenAIPriceChange?

    public init(
        period: CodexUsagePeriod,
        window: CodexUsageWindow,
        generatedAt: Date,
        accounts: [CodexAccountInsights],
        totals: CodexUsageTotals,
        models: [CodexModelUsage],
        daily: [CodexDailyUsage],
        nearestRisk: CodexQuotaRisk?,
        totalMonthlySubscriptionUSD: Decimal?,
        effectiveSubscriptionUSDPerMillionTokens: Decimal?,
        coverage: UsageCoverage?,
        unattributed: CodexUnattributedInsights?,
        work: CodexWorkInsights? = nil,
        priceChange: OpenAIPriceChange?
    ) {
        self.period = period
        self.window = window
        self.generatedAt = generatedAt
        self.accounts = accounts
        self.totals = totals
        self.models = models
        self.daily = daily
        self.nearestRisk = nearestRisk
        self.totalMonthlySubscriptionUSD = totalMonthlySubscriptionUSD
        self.effectiveSubscriptionUSDPerMillionTokens = effectiveSubscriptionUSDPerMillionTokens
        self.coverage = coverage
        self.unattributed = unattributed
        self.work = work
        self.priceChange = priceChange
    }

    public static func empty(
        period: CodexUsagePeriod = .currentWeek,
        window: CodexUsageWindow? = nil,
        now: Date = .now
    ) -> Self {
        Self(
            period: period,
            window: window ?? CodexUsageWindow.inclusiveUTCDays(from: now, through: now),
            generatedAt: now,
            accounts: [],
            totals: CodexUsageTotals(usage: .zero, credits: nil, apiEquivalentUSD: nil),
            models: [],
            daily: [],
            nearestRisk: nil,
            totalMonthlySubscriptionUSD: nil,
            effectiveSubscriptionUSDPerMillionTokens: nil,
            coverage: nil,
            unattributed: nil,
            work: nil,
            priceChange: nil
        )
    }
}

public struct CodexUnattributedInsights: Codable, Hashable, Sendable {
    public let window: CodexUsageWindow
    public let totals: CodexUsageTotals
    public let models: [CodexModelUsage]
    public let daily: [CodexDailyUsage]

    public init(
        window: CodexUsageWindow,
        totals: CodexUsageTotals,
        models: [CodexModelUsage],
        daily: [CodexDailyUsage]
    ) {
        self.window = window
        self.totals = totals
        self.models = models
        self.daily = daily
    }
}

public struct CodexAnalyticsSnapshotSet: Codable, Hashable, Sendable {
    public let currentWeek: CodexInsightsSnapshot
    public let last30Days: CodexInsightsSnapshot
    public let last6Months: CodexInsightsSnapshot
    public let lastYear: CodexInsightsSnapshot
    public let custom: CodexInsightsSnapshot
    public let all: CodexInsightsSnapshot

    public init(
        currentWeek: CodexInsightsSnapshot,
        last30Days: CodexInsightsSnapshot,
        last6Months: CodexInsightsSnapshot,
        lastYear: CodexInsightsSnapshot,
        custom: CodexInsightsSnapshot,
        all: CodexInsightsSnapshot
    ) {
        self.currentWeek = currentWeek
        self.last30Days = last30Days
        self.last6Months = last6Months
        self.lastYear = lastYear
        self.custom = custom
        self.all = all
    }

    public subscript(period: CodexUsagePeriod) -> CodexInsightsSnapshot {
        switch period {
        case .currentWeek: currentWeek
        case .last30Days: last30Days
        case .last6Months: last6Months
        case .lastYear: lastYear
        case .custom: custom
        case .all: all
        }
    }

    public static func empty(now: Date = .now) -> Self {
        Self(
            currentWeek: .empty(period: .currentWeek, now: now),
            last30Days: .empty(period: .last30Days, now: now),
            last6Months: .empty(period: .last6Months, now: now),
            lastYear: .empty(period: .lastYear, now: now),
            custom: .empty(period: .custom, now: now),
            all: .empty(period: .all, now: now)
        )
    }
}

public enum CodexAnalyticsSelection {
    public static func quota(
        in snapshot: CodexInsightsSnapshot
    ) -> (account: CodexAccountInsights, quota: CodexQuotaForecast)? {
        if let risk = snapshot.nearestRisk,
           let account = snapshot.accounts.first(where: { $0.id == risk.accountID }),
           let quota = account.quotaForecasts.first(where: { $0.key == risk.quotaKey }) {
            return (account, quota)
        }
        return snapshot.accounts
            .flatMap { account in account.quotaForecasts.map { (account, $0) } }
            .min { lhs, rhs in
                if CodexQuotaForecast.riskOrder(lhs.1, rhs.1) { return true }
                if CodexQuotaForecast.riskOrder(rhs.1, lhs.1) { return false }
                return lhs.0.id < rhs.0.id
            }
    }
}

extension CodexQuotaForecast {
    static func riskOrder(_ lhs: CodexQuotaForecast, _ rhs: CodexQuotaForecast) -> Bool {
        let leftRank = riskRank(lhs.forecast.state)
        let rightRank = riskRank(rhs.forecast.state)
        if leftRank != rightRank { return leftRank < rightRank }
        if lhs.forecast.predictedExhaustionAt != rhs.forecast.predictedExhaustionAt {
            return (lhs.forecast.predictedExhaustionAt ?? .distantFuture)
                < (rhs.forecast.predictedExhaustionAt ?? .distantFuture)
        }
        if lhs.forecast.remainingPercent != rhs.forecast.remainingPercent {
            return (lhs.forecast.remainingPercent ?? 101) < (rhs.forecast.remainingPercent ?? 101)
        }
        if lhs.title != rhs.title { return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending }
        if lhs.key.limitID != rhs.key.limitID { return lhs.key.limitID < rhs.key.limitID }
        return lhs.key.windowKind.rawValue < rhs.key.windowKind.rawValue
    }

    static func riskRank(_ state: LimitBurnForecastState) -> Int {
        switch state {
        case .exhaustsBeforeReset: 0
        case .stable: 1
        case .collecting: 2
        case .stale: 3
        case .lastsUntilReset: 4
        }
    }
}

public struct CodexStoredDailyUsage: Codable, Hashable, Identifiable, Sendable {
    public let date: Date
    public let accountID: String?
    public let modelID: String
    public let attribution: CodexUsageAttribution
    public let speed: String?
    public let source: CodexUsageSource
    public let rateRevisionID: String?
    public let contextTier: OpenAIContextTier
    public let usage: CodexTokenUsage

    public init(
        date: Date,
        accountID: String?,
        modelID: String,
        attribution: CodexUsageAttribution,
        speed: String? = nil,
        source: CodexUsageSource = .localRollout,
        rateRevisionID: String? = nil,
        contextTier: OpenAIContextTier = .unknown,
        usage: CodexTokenUsage
    ) {
        self.date = date
        self.accountID = accountID
        self.modelID = modelID
        self.attribution = attribution
        self.speed = speed
        self.source = source
        self.rateRevisionID = rateRevisionID
        self.contextTier = contextTier
        self.usage = usage
    }

    public var id: String {
        "\(Int64(date.timeIntervalSince1970))|\(accountID ?? "-")|\(modelID)|\(attribution.rawValue)|\(speed ?? "standard")|\(source.rawValue)|\(rateRevisionID ?? "-")|\(contextTier.rawValue)"
    }
}

public struct CodexImportCursor: Codable, Hashable, Sendable {
    public let path: String
    public let inode: UInt64
    public let byteOffset: UInt64
    public let modifiedAt: Date
    public let schemaAdapter: Int
    public let metadataAdapter: Int
    public let parserState: Data?

    public init(
        path: String,
        inode: UInt64,
        byteOffset: UInt64,
        modifiedAt: Date,
        schemaAdapter: Int,
        metadataAdapter: Int = 0,
        parserState: Data? = nil
    ) {
        self.path = path
        self.inode = inode
        self.byteOffset = byteOffset
        self.modifiedAt = modifiedAt
        self.schemaAdapter = schemaAdapter
        self.metadataAdapter = metadataAdapter
        self.parserState = parserState
    }
}

public struct CodexUsageRepositorySnapshot: Sendable {
    public let accountUsage: [String: CodexAccountUsageSnapshot]
    public let dailyUsage: [CodexStoredDailyUsage]
    public let workUsage: [CodexStoredWorkUsage]
    public let limitObservations: [String: [CodexLimitObservation]]
    public let latestLimits: [String: CodexRateLimitsSnapshot]
    public let endpointStatuses: [String: [CodexUsageEndpointKind: CodexUsageEndpointStatus]]
    public let threadUsageEvidence: [String: CodexThreadUsageEvidence]
    public let rateCardRevisions: [OpenAIRateCardRevision]
    public let analyticsEpochStartedAt: Date?

    public init(
        accountUsage: [String: CodexAccountUsageSnapshot],
        dailyUsage: [CodexStoredDailyUsage],
        workUsage: [CodexStoredWorkUsage] = [],
        limitObservations: [String: [CodexLimitObservation]],
        latestLimits: [String: CodexRateLimitsSnapshot],
        endpointStatuses: [String: [CodexUsageEndpointKind: CodexUsageEndpointStatus]] = [:],
        threadUsageEvidence: [String: CodexThreadUsageEvidence] = [:],
        rateCardRevisions: [OpenAIRateCardRevision],
        analyticsEpochStartedAt: Date? = nil
    ) {
        self.accountUsage = accountUsage
        self.dailyUsage = dailyUsage
        self.workUsage = workUsage
        self.limitObservations = limitObservations
        self.latestLimits = latestLimits
        self.endpointStatuses = endpointStatuses
        self.threadUsageEvidence = threadUsageEvidence
        self.rateCardRevisions = rateCardRevisions
        self.analyticsEpochStartedAt = analyticsEpochStartedAt
    }
}
