import Foundation

public enum L10n {
    public static let supportedLocalizations = ["en", "ru", "zh-Hans", "fr", "es"]
    public static let languageOverrideStorageKey = "limits.language.override"
    public static let languageDidChangeNotification = Notification.Name("LimitsLanguageDidChange")

    #if DEBUG
    @TaskLocal public static var languageOverride: String?

    public static func withLanguage<T>(_ language: String, _ body: () throws -> T) rethrows -> T {
        try $languageOverride.withValue(language) {
            try body()
        }
    }
    #endif

    public static var locale: Locale {
        Locale(identifier: resolvedLanguage)
    }

    public static var resolvedLanguage: String {
        #if DEBUG
        if let languageOverride {
            return canonicalLanguage(languageOverride)
        }
        #endif

        if let languageOverride = sharedDefaults.string(forKey: languageOverrideStorageKey)
            ?? UserDefaults.standard.string(forKey: languageOverrideStorageKey),
           !languageOverride.isEmpty {
            return canonicalLanguage(languageOverride)
        }

        let preferred = Bundle.preferredLocalizations(
            from: supportedLocalizations,
            forPreferences: Locale.preferredLanguages
        )
        return canonicalLanguage(preferred.first ?? "en")
    }

    public static var selectedLanguageOverride: String? {
        let value = sharedDefaults.string(forKey: languageOverrideStorageKey)
            ?? UserDefaults.standard.string(forKey: languageOverrideStorageKey)
        return value?.isEmpty == false ? value : nil
    }

    public static func setLanguageOverride(_ language: String?) {
        let normalized = language.flatMap { $0.isEmpty ? nil : canonicalLanguage($0) }
        if let normalized {
            sharedDefaults.set(normalized, forKey: languageOverrideStorageKey)
            UserDefaults.standard.removeObject(forKey: languageOverrideStorageKey)
        } else {
            sharedDefaults.removeObject(forKey: languageOverrideStorageKey)
            UserDefaults.standard.removeObject(forKey: languageOverrideStorageKey)
        }
        NotificationCenter.default.post(name: languageDidChangeNotification, object: nil)
    }

    public static func displayName(for language: String) -> String {
        switch canonicalLanguage(language) {
        case "en": return "English"
        case "ru": return "Русский"
        case "zh-Hans": return "简体中文"
        case "fr": return "Français"
        case "es": return "Español"
        default: return language
        }
    }

    public static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        let format = activeBundle.localizedString(forKey: key, value: nil, table: nil)
        guard !arguments.isEmpty else {
            return format
        }
        return String(format: format, locale: locale, arguments: arguments)
    }

    public static func accountCount(_ count: Int) -> String {
        switch languageFamily {
        case "ru":
            let mod10 = count % 10
            let mod100 = count % 100
            if mod10 == 1 && mod100 != 11 {
                return tr("accounts.count.one", count)
            }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) {
                return tr("accounts.count.few", count)
            }
            return tr("accounts.count.many", count)
        case "zh", "ja":
            return tr("accounts.count.other", count)
        default:
            return count == 1 ? tr("accounts.count.one", count) : tr("accounts.count.other", count)
        }
    }

    public static func limitAvailability(available: Int, total: Int) -> String {
        tr("tray.availability.with_limits", available, total)
    }

    public static func readyAccountCount(_ count: Int) -> String {
        switch languageFamily {
        case "ru":
            let mod10 = count % 10
            let mod100 = count % 100
            if mod10 == 1 && mod100 != 11 {
                return tr("tray.accessibility.ready_accounts.one", count)
            }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) {
                return tr("tray.accessibility.ready_accounts.few", count)
            }
            return tr("tray.accessibility.ready_accounts.many", count)
        case "zh", "ja":
            return tr("tray.accessibility.ready_accounts.other", count)
        default:
            return count == 1
                ? tr("tray.accessibility.ready_accounts.one", count)
                : tr("tray.accessibility.ready_accounts.other", count)
        }
    }

    public static func updatedAt(_ value: String) -> String {
        tr("time.updated_at", value)
    }

    public static func checkedAt(_ value: String) -> String {
        tr("time.checked_at", value)
    }

    public static func limitsAt(_ value: String) -> String {
        tr("time.limits_at", value)
    }

    public static func usedFiveHours(_ percent: Int) -> String {
        tr("limit.used_five_hours", percent)
    }

    public static func percentRemaining(_ percent: Int) -> String {
        tr("limit.percent_remaining", percent)
    }

    public static func resetExpandedText(for date: Date, now: Date = .now) -> String {
        guard date > now else {
            return tr("reset.stale.expanded")
        }

        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return tr("reset.today.expanded", shortTimeFormatter.string(from: date))
        }
        return tr("reset.other_day.expanded", shortTimeFormatter.string(from: date), dayMonthFormatter.string(from: date))
    }

    public static func resetCompactText(for date: Date, now: Date = .now) -> String {
        guard date > now else {
            return tr("reset.stale.compact")
        }

        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return tr("reset.today.compact", shortTimeFormatter.string(from: date))
        }
        return tr(
            "reset.other_day.compact",
            shortDayMonthFormatter.string(from: date),
            shortTimeFormatter.string(from: date)
        )
    }

    public static func windowLabel(minutes: Int64?, fallback: String) -> String {
        guard let minutes else { return fallback }

        switch minutes {
        case 60:
            return durationHours(1)
        case 300:
            return durationHours(5)
        case 1440:
            return durationHours(24)
        case 10080:
            return tr("duration.week")
        default:
            return durationLabel(minutes: minutes)
        }
    }

    public static func durationLabel(minutes: Int64) -> String {
        if minutes % 1440 == 0 {
            return durationDays(Int(minutes / 1440))
        }
        if minutes % 60 == 0 {
            return durationHours(Int(minutes / 60))
        }
        return durationMinutes(Int(minutes))
    }

    public static func countdown(until timestamp: Int64?, now: Date) -> String? {
        guard let timestamp else { return nil }

        let remaining = max(0, Int(Date(timeIntervalSince1970: TimeInterval(timestamp)).timeIntervalSince(now)))
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60

        if days > 0 {
            if hours > 0 {
                return tr("duration.days_hours", days, hours)
            }
            return durationDays(days)
        }

        if hours > 0 {
            if minutes > 0 {
                return tr("duration.hours_minutes", hours, minutes)
            }
            return durationHours(hours)
        }

        return durationMinutes(max(minutes, 1))
    }

    public static func localizedDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    public static func shortTime(_ date: Date) -> String {
        shortTimeFormatter.string(from: date)
    }

    public static func shortDayTime(_ date: Date) -> String {
        shortDayTimeFormatter.string(from: date)
    }

    public static func updatedAtShort(_ date: Date) -> String {
        updatedAt(shortTime(date))
    }

    private static var activeBundle: Bundle {
        let base = resourceBundle
        let language = resolvedLanguage
        guard let path = base.path(forResource: language, ofType: "lproj")
            ?? base.path(forResource: language.lowercased(), ofType: "lproj")
            ?? base.path(forResource: languageFamily, ofType: "lproj")
            ?? base.path(forResource: languageFamily.lowercased(), ofType: "lproj")
            ?? base.path(forResource: "en", ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            return base
        }
        return bundle
    }

    private static var resourceBundle: Bundle {
        Bundle(for: LocalizationBundleMarker.self)
    }

    private static var sharedDefaults: UserDefaults {
        let identifier = LimitsWidgetSnapshotStore.resolvedAppGroupIdentifier()
        return UserDefaults(suiteName: identifier) ?? .standard
    }

    private static var languageFamily: String {
        let language = resolvedLanguage
        if language.hasPrefix("zh") { return "zh" }
        if let first = language.split(separator: "-").first {
            return String(first)
        }
        return language
    }

    private static func canonicalLanguage(_ language: String) -> String {
        if language.hasPrefix("zh") { return "zh-Hans" }
        if let match = supportedLocalizations.first(where: { language == $0 || language.hasPrefix("\($0)-") }) {
            return match
        }
        return language.split(separator: "-").first.map(String.init).flatMap { short in
            supportedLocalizations.first(where: { $0 == short })
        } ?? "en"
    }

    private static func durationDays(_ value: Int) -> String {
        tr("duration.days.short", value)
    }

    private static func durationHours(_ value: Int) -> String {
        tr("duration.hours.short", value)
    }

    private static func durationMinutes(_ value: Int) -> String {
        tr("duration.minutes.short", value)
    }

    private static var shortTimeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "HH:mm"
        return formatter
    }

    private static var shortDayTimeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter
    }

    private static var dayMonthFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("dMMMM")
        return formatter
    }

    private static var shortDayMonthFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return formatter
    }
}

private final class LocalizationBundleMarker {}
