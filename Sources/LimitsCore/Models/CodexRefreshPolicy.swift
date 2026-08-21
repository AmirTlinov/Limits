import Foundation
import LimitsShared

public enum CodexRefreshPolicy {
    public static let currentSnapshotTTL = LimitsFreshnessPolicy.defaultTTL
    public static let currentFailureRetryInterval: TimeInterval = 5 * 60
    public static let storedPresentationTTL: TimeInterval = 60 * 60

    public static func canReuse(
        _ probe: CodexSessionProbe,
        expectedFingerprint: String,
        now: Date,
        ttl: TimeInterval = currentSnapshotTTL
    ) -> Bool {
        guard probe.fingerprint == expectedFingerprint else { return false }
        guard probe.rateLimitError == nil else { return false }
        guard let observedAt = probe.limitsObservedAt else { return false }
        guard now.timeIntervalSince(observedAt) >= 0 else { return false }
        guard now.timeIntervalSince(observedAt) < ttl else { return false }
        return !snapshotHasPassedReset(
            primary: probe.rateLimit,
            byLimitId: probe.rateLimitsByLimitId,
            now: now
        )
    }

    public static func canAttemptRefresh(
        lastAttempt: Date?,
        now: Date,
        retryInterval: TimeInterval
    ) -> Bool {
        guard let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        return elapsed < 0 || elapsed >= retryInterval
    }

    public static func nextStoredAccountID(
        accounts: [StoredAccount],
        latestLimits: [String: CodexRateLimitsSnapshot] = [:],
        currentAccountID: UUID?,
        lastAttempts: [UUID: Date],
        now: Date,
        retryInterval: TimeInterval,
        maximumAge: TimeInterval? = nil
    ) -> UUID? {
        accounts
            .filter { account in
                guard account.id != currentAccountID, account.status != .needsReauth else { return false }
                let snapshot = account.accountId.flatMap { latestLimits[$0] }
                guard accountNeedsRefresh(snapshot, now: now, maximumAge: maximumAge) else { return false }
                return canAttemptRefresh(
                    lastAttempt: lastAttempts[account.id],
                    now: now,
                    retryInterval: retryInterval
                )
            }
            .sorted { lhs, rhs in
                let lhsSnapshot = lhs.accountId.flatMap { latestLimits[$0] }
                let rhsSnapshot = rhs.accountId.flatMap { latestLimits[$0] }
                let lhsPriority = refreshPriority(for: lhsSnapshot, now: now)
                let rhsPriority = refreshPriority(for: rhsSnapshot, now: now)
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }

                let lhsObserved = lhsSnapshot?.limitsObservedAt ?? .distantPast
                let rhsObserved = rhsSnapshot?.limitsObservedAt ?? .distantPast
                if lhsObserved != rhsObserved { return lhsObserved < rhsObserved }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
            .first?.id
    }

    public static func accountNeedsRefresh(
        _ snapshot: CodexRateLimitsSnapshot?,
        now: Date,
        maximumAge: TimeInterval? = nil
    ) -> Bool {
        guard let snapshot, snapshot.errorMessage == nil else { return true }
        let hasSnapshot = snapshot.primary != nil || snapshot.byLimitID?.isEmpty == false
        guard hasSnapshot else { return true }

        if snapshotHasPassedReset(
            primary: snapshot.primary,
            byLimitId: snapshot.byLimitID,
            now: now
        ) {
            return true
        }

        guard let maximumAge else { return false }
        let observedAt = snapshot.observedAt
        let age = now.timeIntervalSince(observedAt)
        return age < 0 || age >= maximumAge
    }

    public static func snapshotHasPassedReset(
        primary: RateLimitSnapshotModel?,
        byLimitId: [String: RateLimitSnapshotModel]?,
        now: Date
    ) -> Bool {
        snapshots(primary: primary, byLimitId: byLimitId)
            .flatMap { resetDates(from: $0) }
            .contains { $0 <= now }
    }

    public static func resetDates(
        primary: RateLimitSnapshotModel?,
        byLimitId: [String: RateLimitSnapshotModel]?
    ) -> [Date] {
        snapshots(primary: primary, byLimitId: byLimitId).flatMap { resetDates(from: $0) }
    }

    private static func refreshPriority(for snapshot: CodexRateLimitsSnapshot?, now: Date) -> Int {
        guard let snapshot else { return 0 }
        let hasSnapshot = snapshot.primary != nil || snapshot.byLimitID?.isEmpty == false
        if !hasSnapshot { return 0 }
        if snapshotHasPassedReset(primary: snapshot.primary, byLimitId: snapshot.byLimitID, now: now) {
            return 1
        }
        return 2
    }

    private static func snapshots(
        primary: RateLimitSnapshotModel?,
        byLimitId: [String: RateLimitSnapshotModel]?
    ) -> [RateLimitSnapshotModel] {
        if let byLimitId, !byLimitId.isEmpty {
            return Array(byLimitId.values)
        }
        return primary.map { [$0] } ?? []
    }

    private static func resetDates(from snapshot: RateLimitSnapshotModel) -> [Date] {
        [
            snapshot.primary?.resetsAt,
            snapshot.secondary?.resetsAt,
            snapshot.individualLimit?.resetsAt,
        ]
        .compactMap { $0 }
        .map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}
