import Foundation
import LimitsShared

public struct RateLimitDisplayRow: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let usedPercent: Int
    public let resetText: String?
    public let resetDate: Date?
    /// Length of the limit window, so surfaces can pick a window without matching localized titles.
    public let windowMinutes: Int64?

    public init(
        id: String,
        title: String,
        usedPercent: Int,
        resetText: String?,
        resetDate: Date? = nil,
        windowMinutes: Int64? = nil
    ) {
        self.id = id
        self.title = title
        self.usedPercent = usedPercent
        self.resetText = resetText
        self.resetDate = resetDate
        self.windowMinutes = windowMinutes
    }

    public var isSessionWindow: Bool {
        windowMinutes == 300
    }

    public var isWeeklyWindow: Bool {
        windowMinutes == 10_080
    }

    public var remainingPercent: Int {
        max(0, 100 - usedPercent)
    }

    public var progressValue: Double {
        min(max(Double(usedPercent) / 100, 0), 1)
    }

    public var remainingProgressValue: Double {
        min(max(Double(remainingPercent) / 100, 0), 1)
    }

    public func compactResetText(now: Date = .now) -> String? {
        guard let resetDate else {
            return resetText
        }
        return RateLimitResetFormatter.compactText(for: resetDate, now: now)
    }

    public func isResetStale(now: Date = .now) -> Bool {
        guard let resetDate else {
            return false
        }
        return resetDate <= now
    }
}

public struct RateLimitDisplaySection: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let rows: [RateLimitDisplayRow]

    public init(id: String, title: String, rows: [RateLimitDisplayRow]) {
        self.id = id
        self.title = title
        self.rows = rows
    }
}

public enum RateLimitDisplayBuilder {
    public static func makeSections(primary: RateLimitSnapshotModel?, byLimitId: [String: RateLimitSnapshotModel]?) -> [RateLimitDisplaySection] {
        makeSections(primary: primary, byLimitId: byLimitId, filteringExpiredRowsAt: nil)
    }

    public static func makeSections(
        primary: RateLimitSnapshotModel?,
        byLimitId: [String: RateLimitSnapshotModel]?,
        excludingExpiredRowsAt now: Date
    ) -> [RateLimitDisplaySection] {
        makeSections(primary: primary, byLimitId: byLimitId, filteringExpiredRowsAt: now)
    }

    private static func makeSections(
        primary: RateLimitSnapshotModel?,
        byLimitId: [String: RateLimitSnapshotModel]?,
        filteringExpiredRowsAt now: Date?
    ) -> [RateLimitDisplaySection] {
        var snapshots = byLimitId ?? [:]

        if let primary {
            snapshots[primary.limitId ?? "codex"] = primary
        }

        return snapshots.values
            .sorted(by: compare)
            .compactMap { makeSection(from: $0, excludingExpiredRowsAt: now) }
    }

    private static func compare(lhs: RateLimitSnapshotModel, rhs: RateLimitSnapshotModel) -> Bool {
        let lhsRank = sortRank(for: lhs)
        let rhsRank = sortRank(for: rhs)

        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }

        let lhsName = (lhs.limitName ?? lhs.limitId ?? "").localizedLowercase
        let rhsName = (rhs.limitName ?? rhs.limitId ?? "").localizedLowercase
        return lhsName < rhsName
    }

    private static func sortRank(for snapshot: RateLimitSnapshotModel) -> Int {
        if snapshot.limitId == "codex" {
            return 0
        }
        return 1
    }

    private static func makeSection(from snapshot: RateLimitSnapshotModel, excludingExpiredRowsAt now: Date?) -> RateLimitDisplaySection? {
        let rows = rows(for: snapshot, excludingExpiredRowsAt: now)
        guard !rows.isEmpty else {
            return nil
        }

        return RateLimitDisplaySection(
            id: stableSectionID(for: snapshot),
            title: sectionTitle(for: snapshot),
            rows: rows
        )
    }

    private static func stableSectionID(for snapshot: RateLimitSnapshotModel) -> String {
        if let id = snapshot.limitId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return "limit:\(id)"
        }
        if let name = snapshot.limitName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return "name:\(name.lowercased())"
        }
        if let plan = snapshot.planType?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty {
            return "plan:\(plan.lowercased())"
        }
        return "limit:default"
    }

    private static func sectionTitle(for snapshot: RateLimitSnapshotModel) -> String {
        if let limitName = snapshot.limitName, !limitName.isEmpty {
            return limitName
        }
        return TrayStatusProvider.codex.displayTitle
    }

    private static func rows(for snapshot: RateLimitSnapshotModel, excludingExpiredRowsAt now: Date?) -> [RateLimitDisplayRow] {
        var result: [RateLimitDisplayRow] = []

        if let primary = snapshot.primary,
           let row = makeRow(
                id: "\(snapshot.limitId ?? "limit").primary",
                window: primary,
                excludingExpiredRowsAt: now
           ) {
            result.append(row)
        }

        if let secondary = snapshot.secondary,
           let row = makeRow(
                id: "\(snapshot.limitId ?? "limit").secondary",
                window: secondary,
                excludingExpiredRowsAt: now
           ) {
            result.append(row)
        }

        if let individual = snapshot.individualLimit {
            let resetDate = Date(timeIntervalSince1970: TimeInterval(individual.resetsAt))
            let isCurrent = now.map { resetDate > $0 } ?? true
            if isCurrent {
                result.append(
                    RateLimitDisplayRow(
                        id: "\(snapshot.limitId ?? "limit").individual",
                        title: L10n.tr("limit.individual_spend", individual.limit),
                        usedPercent: min(max(100 - individual.remainingPercent, 0), 100),
                        resetText: RateLimitResetFormatter.expandedText(for: resetDate),
                        resetDate: resetDate
                    )
                )
            }
        }

        return result
    }

    private static func makeRow(
        id: String,
        window: RateLimitWindowSnapshot,
        excludingExpiredRowsAt now: Date?
    ) -> RateLimitDisplayRow? {
        let resetDate = resetDate(for: window.resetsAt)

        if let now, let resetDate, resetDate <= now {
            return nil
        }

        return RateLimitDisplayRow(
            id: id,
            title: rowTitle(minutes: window.windowDurationMins, fallback: L10n.tr("limit.generic")),
            usedPercent: window.usedPercent,
            resetText: resetDate.map { RateLimitResetFormatter.expandedText(for: $0) },
            resetDate: resetDate,
            windowMinutes: window.windowDurationMins
        )
    }

    private static func rowTitle(minutes: Int64?, fallback: String) -> String {
        guard let minutes else { return fallback }

        switch minutes {
        case 300:
            return L10n.tr("limit.five_hour")
        case 10080:
            return L10n.tr("limit.weekly")
        case 60:
            return L10n.tr("limit.one_hour")
        case 1440:
            return L10n.tr("limit.daily")
        default:
            return L10n.tr("limit.duration", durationLabel(minutes: minutes))
        }
    }

    private static func resetDate(for timestamp: Int64?) -> Date? {
        guard let timestamp else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    private static func durationLabel(minutes: Int64) -> String {
        L10n.durationLabel(minutes: minutes)
    }
}

public enum RateLimitResetFormatter {
    public static func expandedText(for date: Date, now: Date = .now) -> String {
        L10n.resetExpandedText(for: date, now: now)
    }

    public static func compactText(for date: Date, now: Date = .now) -> String {
        L10n.resetCompactText(for: date, now: now)
    }
}

extension RateLimitSnapshotModel {
    public func compactUsageSummary() -> String? {
        var parts: [String] = []

        if let primary {
            parts.append("\(windowLabel(minutes: primary.windowDurationMins, fallback: L10n.tr("limit.window"))) \(primary.usedPercent)%")
        }

        if let secondary {
            parts.append("\(windowLabel(minutes: secondary.windowDurationMins, fallback: L10n.tr("limit.generic"))) \(secondary.usedPercent)%")
        }

        if parts.isEmpty, let reached = rateLimitReachedType {
            return reached.replacingOccurrences(of: "_", with: " ").capitalized
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public func compactResetSummary(now: Date = .now) -> String? {
        if let secondary, let summary = Self.countdown(until: secondary.resetsAt, now: now) {
            return summary
        }
        if let primary, let summary = Self.countdown(until: primary.resetsAt, now: now) {
            return summary
        }
        return nil
    }

    public func panelSummary(now: Date = .now) -> String? {
        let usage = compactUsageSummary()
        let reset = compactResetSummary(now: now)

        switch (usage, reset) {
        case let (usage?, reset?):
            return "\(usage) | \(reset)"
        case let (usage?, nil):
            return usage
        case let (nil, reset?):
            return reset
        case (nil, nil):
            return nil
        }
    }

    private func windowLabel(minutes: Int64?, fallback: String) -> String {
        L10n.windowLabel(minutes: minutes, fallback: fallback)
    }

    private static func durationLabel(minutes: Int64) -> String {
        L10n.durationLabel(minutes: minutes)
    }

    private static func countdown(until timestamp: Int64?, now: Date) -> String? {
        L10n.countdown(until: timestamp, now: now)
    }
}

extension RateLimitSnapshotModel {
    public var fiveHourResetDate: Date? {
        guard let primary, primary.windowDurationMins == 300, let resetsAt = primary.resetsAt else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(resetsAt))
    }

    public func fiveHourHasReset(now: Date = .now) -> Bool {
        guard let resetDate = fiveHourResetDate else {
            return false
        }
        return resetDate <= now
    }
}
