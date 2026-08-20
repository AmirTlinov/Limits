import Foundation
import LimitsShared

public enum CodexRefreshPolicy {
    public static let currentSnapshotTTL = LimitsFreshnessPolicy.defaultTTL
    public static let currentFailureRetryInterval: TimeInterval = 5 * 60
    public static let storedPresentationTTL = LimitsFreshnessPolicy.defaultTTL

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
        currentAccountID: UUID?,
        lastAttempts: [UUID: Date],
        now: Date,
        retryInterval: TimeInterval,
        maximumAge: TimeInterval? = nil
    ) -> UUID? {
        accounts
            .filter { account in
                guard account.id != currentAccountID, account.status != .needsReauth else { return false }
                guard accountNeedsRefresh(account, now: now, maximumAge: maximumAge) else { return false }
                return canAttemptRefresh(
                    lastAttempt: lastAttempts[account.id],
                    now: now,
                    retryInterval: retryInterval
                )
            }
            .sorted { lhs, rhs in
                let lhsPriority = refreshPriority(for: lhs, now: now)
                let rhsPriority = refreshPriority(for: rhs, now: now)
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }

                let lhsObserved = lhs.rateLimitObservedAt ?? .distantPast
                let rhsObserved = rhs.rateLimitObservedAt ?? .distantPast
                if lhsObserved != rhsObserved { return lhsObserved < rhsObserved }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
            .first?.id
    }

    public static func accountNeedsRefresh(
        _ account: StoredAccount,
        now: Date,
        maximumAge: TimeInterval? = nil
    ) -> Bool {
        let hasSnapshot = account.lastRateLimit != nil || account.lastRateLimitsByLimitId?.isEmpty == false
        guard hasSnapshot else { return true }

        if snapshotHasPassedReset(
            primary: account.lastRateLimit,
            byLimitId: account.lastRateLimitsByLimitId,
            now: now
        ) {
            return true
        }

        guard let maximumAge else { return false }
        guard let observedAt = account.rateLimitObservedAt else { return true }
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

    private static func refreshPriority(for account: StoredAccount, now: Date) -> Int {
        let hasSnapshot = account.lastRateLimit != nil || account.lastRateLimitsByLimitId?.isEmpty == false
        if !hasSnapshot { return 0 }
        if snapshotHasPassedReset(primary: account.lastRateLimit, byLimitId: account.lastRateLimitsByLimitId, now: now) {
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
