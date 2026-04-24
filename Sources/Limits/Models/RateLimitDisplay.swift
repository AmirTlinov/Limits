import Foundation

struct RateLimitDisplayRow: Identifiable, Hashable {
    let id: String
    let title: String
    let usedPercent: Int
    let resetText: String?
    let resetDate: Date?

    init(
        id: String,
        title: String,
        usedPercent: Int,
        resetText: String?,
        resetDate: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.usedPercent = usedPercent
        self.resetText = resetText
        self.resetDate = resetDate
    }

    var remainingPercent: Int {
        max(0, 100 - usedPercent)
    }

    var progressValue: Double {
        min(max(Double(usedPercent) / 100, 0), 1)
    }

    var remainingProgressValue: Double {
        min(max(Double(remainingPercent) / 100, 0), 1)
    }

    func compactResetText(now: Date = .now) -> String? {
        guard let resetDate else {
            return resetText
        }
        return RateLimitResetFormatter.compactText(for: resetDate, now: now)
    }

    func isResetStale(now: Date = .now) -> Bool {
        guard let resetDate else {
            return false
        }
        return resetDate <= now
    }
}

struct RateLimitDisplaySection: Identifiable, Hashable {
    let id: String
    let title: String
    let rows: [RateLimitDisplayRow]
}

enum RateLimitDisplayBuilder {
    static func makeSections(primary: RateLimitSnapshotModel?, byLimitId: [String: RateLimitSnapshotModel]?) -> [RateLimitDisplaySection] {
        var snapshots = byLimitId ?? [:]

        if let primary {
            snapshots[primary.limitId ?? "codex"] = primary
        }

        return snapshots.values
            .sorted(by: compare)
            .compactMap(makeSection)
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

    private static func makeSection(from snapshot: RateLimitSnapshotModel) -> RateLimitDisplaySection? {
        let rows = rows(for: snapshot)
        guard !rows.isEmpty else {
            return nil
        }

        return RateLimitDisplaySection(
            id: snapshot.limitId ?? snapshot.limitName ?? UUID().uuidString,
            title: sectionTitle(for: snapshot),
            rows: rows
        )
    }

    private static func sectionTitle(for snapshot: RateLimitSnapshotModel) -> String {
        if let limitName = snapshot.limitName, !limitName.isEmpty {
            return limitName
        }
        return "Codex CLI"
    }

    private static func rows(for snapshot: RateLimitSnapshotModel) -> [RateLimitDisplayRow] {
        var result: [RateLimitDisplayRow] = []

        if let primary = snapshot.primary {
            let resetDate = resetDate(for: primary.resetsAt)
            result.append(
                RateLimitDisplayRow(
                    id: "\(snapshot.limitId ?? "limit").primary",
                    title: rowTitle(minutes: primary.windowDurationMins, fallback: L10n.tr("limit.generic")),
                    usedPercent: primary.usedPercent,
                    resetText: resetDate.map { RateLimitResetFormatter.expandedText(for: $0) },
                    resetDate: resetDate
                )
            )
        }

        if let secondary = snapshot.secondary {
            let resetDate = resetDate(for: secondary.resetsAt)
            result.append(
                RateLimitDisplayRow(
                    id: "\(snapshot.limitId ?? "limit").secondary",
                    title: rowTitle(minutes: secondary.windowDurationMins, fallback: L10n.tr("limit.generic")),
                    usedPercent: secondary.usedPercent,
                    resetText: resetDate.map { RateLimitResetFormatter.expandedText(for: $0) },
                    resetDate: resetDate
                )
            )
        }

        return result
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

enum RateLimitResetFormatter {
    static func expandedText(for date: Date, now: Date = .now) -> String {
        L10n.resetExpandedText(for: date, now: now)
    }

    static func compactText(for date: Date, now: Date = .now) -> String {
        L10n.resetCompactText(for: date, now: now)
    }
}

extension RateLimitSnapshotModel {
    func compactUsageSummary() -> String? {
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

    func compactResetSummary(now: Date = .now) -> String? {
        if let secondary, let summary = Self.countdown(until: secondary.resetsAt, now: now) {
            return summary
        }
        if let primary, let summary = Self.countdown(until: primary.resetsAt, now: now) {
            return summary
        }
        return nil
    }

    func panelSummary(now: Date = .now) -> String? {
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
