import Foundation

struct RateLimitDisplayRow: Identifiable, Hashable {
    let id: String
    let title: String
    let usedPercent: Int
    let resetText: String?

    var remainingPercent: Int {
        max(0, 100 - usedPercent)
    }

    var progressValue: Double {
        min(max(Double(usedPercent) / 100, 0), 1)
    }

    var remainingProgressValue: Double {
        min(max(Double(remainingPercent) / 100, 0), 1)
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
            result.append(
                RateLimitDisplayRow(
                    id: "\(snapshot.limitId ?? "limit").primary",
                    title: rowTitle(minutes: primary.windowDurationMins, fallback: "Лимит"),
                    usedPercent: primary.usedPercent,
                    resetText: resetText(for: primary.resetsAt)
                )
            )
        }

        if let secondary = snapshot.secondary {
            result.append(
                RateLimitDisplayRow(
                    id: "\(snapshot.limitId ?? "limit").secondary",
                    title: rowTitle(minutes: secondary.windowDurationMins, fallback: "Лимит"),
                    usedPercent: secondary.usedPercent,
                    resetText: resetText(for: secondary.resetsAt)
                )
            )
        }

        return result
    }

    private static func rowTitle(minutes: Int64?, fallback: String) -> String {
        guard let minutes else { return fallback }

        switch minutes {
        case 300:
            return "5ч лимит"
        case 10080:
            return "Недельный лимит"
        case 60:
            return "1ч лимит"
        case 1440:
            return "Суточный лимит"
        default:
            return "\(durationLabel(minutes: minutes)) лимит"
        }
    }

    private static func resetText(for timestamp: Int64?) -> String? {
        guard let timestamp else { return nil }
        return "Сброс в \(resetDateText(for: Date(timeIntervalSince1970: TimeInterval(timestamp))))"
    }

    private static func resetDateText(for date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return timeFormatter.string(from: date)
        }
        return "\(timeFormatter.string(from: date)), \(dayMonthFormatter.string(from: date))"
    }

    private static func durationLabel(minutes: Int64) -> String {
        if minutes % 1440 == 0 {
            return "\(minutes / 1440)д"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60)ч"
        }
        return "\(minutes)м"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM"
        return formatter
    }()
}

extension RateLimitSnapshotModel {
    func compactUsageSummary() -> String? {
        var parts: [String] = []

        if let primary {
            parts.append("\(windowLabel(minutes: primary.windowDurationMins, fallback: "Окно")) \(primary.usedPercent)%")
        }

        if let secondary {
            parts.append("\(windowLabel(minutes: secondary.windowDurationMins, fallback: "Лимит")) \(secondary.usedPercent)%")
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
        guard let minutes else { return fallback }

        switch minutes {
        case 60:
            return "1ч"
        case 300:
            return "5ч"
        case 1440:
            return "24ч"
        case 10080:
            return "Неделя"
        default:
            return Self.durationLabel(minutes: minutes)
        }
    }

    private static func durationLabel(minutes: Int64) -> String {
        if minutes % 1440 == 0 {
            return "\(minutes / 1440)д"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60)ч"
        }
        return "\(minutes)м"
    }

    private static func countdown(until timestamp: Int64?, now: Date) -> String? {
        guard let timestamp else { return nil }

        let remaining = max(0, Int(Date(timeIntervalSince1970: TimeInterval(timestamp)).timeIntervalSince(now)))
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60

        if days > 0 {
            if hours > 0 {
                return "\(days)д \(hours)ч"
            }
            return "\(days)д"
        }

        if hours > 0 {
            if minutes > 0 {
                return "\(hours)ч \(minutes)м"
            }
            return "\(hours)ч"
        }

        return "\(max(minutes, 1))м"
    }
}
