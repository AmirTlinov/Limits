import Foundation
import LimitsShared

public struct SidebarLimitSummary: Hashable, Sendable {
    public let fiveHourRemainingPercent: Int?
    public let weeklyRemainingPercent: Int?
    public let nextResetDate: Date?

    public init(fiveHourRemainingPercent: Int?, weeklyRemainingPercent: Int?, nextResetDate: Date?) {
        self.fiveHourRemainingPercent = fiveHourRemainingPercent
        self.weeklyRemainingPercent = weeklyRemainingPercent
        self.nextResetDate = nextResetDate
    }

    public var hasLimitData: Bool {
        fiveHourRemainingPercent != nil || weeklyRemainingPercent != nil
    }

    public var limitSortScore: Int {
        [fiveHourRemainingPercent, weeklyRemainingPercent].compactMap(\.self).reduce(0, +)
    }

    public func compactLimitText() -> String? {
        var parts: [String] = []
        if let fiveHourRemainingPercent {
            parts.append("\(L10n.windowLabel(minutes: 300, fallback: "5h")) \(fiveHourRemainingPercent)%")
        }
        if let weeklyRemainingPercent {
            parts.append("\(L10n.durationLabel(minutes: 10_080)) \(weeklyRemainingPercent)%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public func compactResetText(now: Date = .now) -> String? {
        nextResetDate.map { RateLimitResetFormatter.compactText(for: $0, now: now) }
    }
}

public enum CodexAccountsPresentationPolicy {
    public static func sortedForSidebar(
        _ accounts: [StoredAccount],
        summaries: [UUID: SidebarLimitSummary?]
    ) -> [StoredAccount] {
        accounts.sorted { lhs, rhs in
            compare(lhs, rhs, summaries: summaries)
        }
    }

    public static func sidebarLimitSummary(
        primary: RateLimitSnapshotModel?,
        byLimitId: [String: RateLimitSnapshotModel]?,
        observedAt: Date?,
        now: Date = .now
    ) -> SidebarLimitSummary? {
        guard LimitsFreshnessPolicy.isFresh(observedAt: observedAt, at: now) else { return nil }
        guard let snapshot = byLimitId?["codex"] ?? primary else { return nil }
        let fiveHour = remainingWindow(from: snapshot, minutes: 300, now: now)
        let weekly = remainingWindow(from: snapshot, minutes: 10_080, now: now)
        guard fiveHour.remainingPercent != nil || weekly.remainingPercent != nil else { return nil }
        return SidebarLimitSummary(
            fiveHourRemainingPercent: fiveHour.remainingPercent,
            weeklyRemainingPercent: weekly.remainingPercent,
            nextResetDate: [fiveHour.resetDate, weekly.resetDate].compactMap(\.self).min()
        )
    }

    public static func currentProbeHasExpiredReset(_ probe: CodexSessionProbe, now: Date = .now) -> Bool {
        storedSnapshotIsStale(primary: probe.rateLimit, byLimitId: probe.rateLimitsByLimitId, now: now)
    }

    public static func canAttemptRefresh(lastAttempt: Date?, now: Date, retryInterval: TimeInterval) -> Bool {
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= retryInterval
    }

    public static func nextAccountIDForAutoRefresh(
        accounts: [StoredAccount],
        currentAccountID: UUID?,
        lastAttempts: [UUID: Date],
        now: Date,
        retryInterval: TimeInterval
    ) -> UUID? {
        accounts
            .filter { account in
                guard account.id != currentAccountID, account.status != .needsReauth else { return false }
                guard accountNeedsAutoRefresh(account, now: now) else { return false }
                if let lastAttempt = lastAttempts[account.id], now.timeIntervalSince(lastAttempt) < retryInterval {
                    return false
                }
                return true
            }
            .sorted { lhs, rhs in
                let lhsReset = staleResetDate(for: lhs) ?? .distantFuture
                let rhsReset = staleResetDate(for: rhs) ?? .distantFuture
                if lhsReset != rhsReset { return lhsReset < rhsReset }
                let lhsValidated = lhs.lastValidatedAt ?? .distantPast
                let rhsValidated = rhs.lastValidatedAt ?? .distantPast
                if lhsValidated != rhsValidated { return lhsValidated < rhsValidated }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
            .first?.id
    }

    public static func accountNeedsAutoRefresh(_ account: StoredAccount, now: Date = .now) -> Bool {
        let hasSnapshot = account.lastRateLimit != nil || account.lastRateLimitsByLimitId?.isEmpty == false
        return !hasSnapshot || storedSnapshotIsStale(
            primary: account.lastRateLimit,
            byLimitId: account.lastRateLimitsByLimitId,
            now: now
        )
    }

    public static func storedRateLimitSections(
        primary: RateLimitSnapshotModel?,
        byLimitId: [String: RateLimitSnapshotModel]?,
        observedAt: Date?,
        now: Date = .now
    ) -> [RateLimitDisplaySection] {
        guard LimitsFreshnessPolicy.isFresh(observedAt: observedAt, at: now) else { return [] }
        let hasExactSnapshots = byLimitId?.isEmpty == false
        return RateLimitDisplayBuilder.makeSections(
            primary: hasExactSnapshots ? nil : primary,
            byLimitId: byLimitId,
            excludingExpiredRowsAt: now
        )
    }

    public static func storedRateLimitSummary(
        primary: RateLimitSnapshotModel?,
        byLimitId: [String: RateLimitSnapshotModel]?,
        observedAt: Date?,
        now: Date = .now
    ) -> String? {
        if !LimitsFreshnessPolicy.isFresh(observedAt: observedAt, at: now)
            || storedSnapshotIsStale(primary: primary, byLimitId: byLimitId, now: now) {
            return L10n.tr("reset.stale.expanded")
        }
        return primary?.compactUsageSummary()
    }

    public static func storedRemainingPercent(
        primary: RateLimitSnapshotModel?,
        byLimitId: [String: RateLimitSnapshotModel]?,
        observedAt: Date?,
        now: Date = .now
    ) -> Int? {
        sidebarLimitSummary(primary: primary, byLimitId: byLimitId, observedAt: observedAt, now: now)?.fiveHourRemainingPercent
    }

    private static func compare(
        _ lhs: StoredAccount,
        _ rhs: StoredAccount,
        summaries: [UUID: SidebarLimitSummary?]
    ) -> Bool {
        let lhsSummary = summaries[lhs.id] ?? nil
        let rhsSummary = summaries[rhs.id] ?? nil
        let lhsHasData = lhsSummary?.hasLimitData == true
        let rhsHasData = rhsSummary?.hasLimitData == true
        if lhsHasData != rhsHasData { return lhsHasData }
        switch (lhsSummary?.nextResetDate, rhsSummary?.nextResetDate) {
        case let (lhsReset?, rhsReset?) where lhsReset != rhsReset: return lhsReset < rhsReset
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
        let lhsScore = lhsSummary?.limitSortScore ?? -1
        let rhsScore = rhsSummary?.limitSortScore ?? -1
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        let lhsRank = statusRank(lhs.status)
        let rhsRank = statusRank(rhs.status)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
    }

    private static func statusRank(_ status: AccountStatus) -> Int {
        switch status {
        case .ok: 0
        case .limitReached: 1
        case .unknown: 2
        case .needsReauth: 3
        case .validationFailed: 4
        }
    }

    private static func remainingWindow(from snapshot: RateLimitSnapshotModel, minutes: Int64, now: Date) -> (remainingPercent: Int?, resetDate: Date?) {
        guard let window = [snapshot.primary, snapshot.secondary].compactMap(\.self).first(where: { $0.windowDurationMins == minutes }) else {
            return (nil, nil)
        }
        let resetDate = window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        if let resetDate, resetDate <= now { return (nil, nil) }
        return (max(0, 100 - window.usedPercent), resetDate)
    }

    private static func staleResetDate(for account: StoredAccount) -> Date? {
        (account.lastRateLimitsByLimitId?["codex"] ?? account.lastRateLimit)?.fiveHourResetDate
    }

    private static func storedSnapshotIsStale(
        primary: RateLimitSnapshotModel?,
        byLimitId: [String: RateLimitSnapshotModel]?,
        now: Date
    ) -> Bool {
        if let codex = byLimitId?["codex"], codex.fiveHourHasReset(now: now) { return true }
        if let primary, primary.fiveHourHasReset(now: now) { return true }
        return false
    }
}
