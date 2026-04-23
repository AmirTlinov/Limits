import Foundation

extension RateLimitSnapshotModel {
    func compactUsageSummary() -> String? {
        var parts: [String] = []

        if let primary {
            parts.append("\(windowLabel(minutes: primary.windowDurationMins, fallback: "Window")) \(primary.usedPercent)%")
        }

        if let secondary {
            parts.append("\(windowLabel(minutes: secondary.windowDurationMins, fallback: "Limit")) \(secondary.usedPercent)%")
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
            return "1h"
        case 300:
            return "5h"
        case 1440:
            return "24h"
        case 10080:
            return "Weekly"
        default:
            return Self.durationLabel(minutes: minutes)
        }
    }

    private static func durationLabel(minutes: Int64) -> String {
        if minutes % 1440 == 0 {
            return "\(minutes / 1440)d"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60)h"
        }
        return "\(minutes)m"
    }

    private static func countdown(until timestamp: Int64?, now: Date) -> String? {
        guard let timestamp else { return nil }

        let remaining = max(0, Int(Date(timeIntervalSince1970: TimeInterval(timestamp)).timeIntervalSince(now)))
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60

        if days > 0 {
            if hours > 0 {
                return "\(days)d \(hours)h"
            }
            return "\(days)d"
        }

        if hours > 0 {
            if minutes > 0 {
                return "\(hours)h \(minutes)m"
            }
            return "\(hours)h"
        }

        return "\(max(minutes, 1))m"
    }
}
