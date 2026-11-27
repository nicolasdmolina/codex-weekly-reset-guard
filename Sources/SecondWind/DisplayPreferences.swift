import Foundation

/// Whether quota figures count what is left or what is used. Every figure carries the word.
enum QuotaConvention: String, CaseIterable, Sendable {
    case remaining
    case used

    var word: String {
        switch self {
        case .remaining: "left"
        case .used: "used"
        }
    }

    var title: String {
        switch self {
        case .remaining: "Left"
        case .used: "Used"
        }
    }

    /// Whole percent shown for a window. Used is derived from the floored remaining figure so
    /// the two conventions always add up to 100.
    func percent(remaining: Double) -> Int {
        let left = Int(max(0, min(100, remaining)).rounded(.down))
        return self == .remaining ? left : 100 - left
    }

    func text(remaining: Double) -> String {
        "\(percent(remaining: remaining))% \(word)"
    }
}

/// Whether reset times read as a countdown or as a clock time.
enum ResetTimeStyle: String, CaseIterable, Sendable {
    case relative
    case exact

    var title: String {
        switch self {
        case .relative: "Countdown"
        case .exact: "Clock time"
        }
    }

    var toggled: ResetTimeStyle { self == .relative ? .exact : .relative }
}

struct DisplayPreferences: Equatable, Sendable {
    var quota: QuotaConvention = .remaining
    var resetTimes: ResetTimeStyle = .relative

    private static let quotaKey = "display.quotaConvention"
    private static let resetTimesKey = "display.resetTimeStyle"

    /// Unknown or missing stored values fall back to the defaults.
    static func load(from defaults: UserDefaults?) -> DisplayPreferences {
        var preferences = DisplayPreferences()
        if let raw = defaults?.string(forKey: quotaKey), let value = QuotaConvention(rawValue: raw) {
            preferences.quota = value
        }
        if let raw = defaults?.string(forKey: resetTimesKey), let value = ResetTimeStyle(rawValue: raw) {
            preferences.resetTimes = value
        }
        return preferences
    }

    func save(to defaults: UserDefaults?) {
        defaults?.set(quota.rawValue, forKey: Self.quotaKey)
        defaults?.set(resetTimes.rawValue, forKey: Self.resetTimesKey)
    }
}

/// Deterministic, compact date wording for the popover. Every function takes the reference
/// clock so synthetic previews and tests never depend on the real time.
enum QuotaTimeFormat {
    /// "in 40m", "in 3h 40m", "in 5d 9h", "in 12d". Past times return nil; the caller decides
    /// what an overdue reset means.
    static func countdown(to date: Date, from reference: Date) -> String? {
        let seconds = date.timeIntervalSince(reference)
        guard seconds > 0 else { return nil }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "in \(hours)h" : "in \(hours)h \(rest)m"
        }
        let days = hours / 24
        let restHours = hours % 24
        if days >= 7 || restHours == 0 { return "in \(days)d" }
        return "in \(days)d \(restHours)h"
    }

    /// "3:40 PM" today, "Tue 9:00 AM" within a week, "Dec 10" beyond.
    static func clock(_ date: Date, reference: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var calendar = calendar
        calendar.locale = locale
        let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: reference) {
            return date.formatted(time)
        }
        let interval = date.timeIntervalSince(reference)
        if interval > 0, interval < 6 * 86_400 {
            let weekday = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated)
            return "\(date.formatted(weekday)) \(date.formatted(time))"
        }
        let day = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
        return date.formatted(day)
    }

    static func resetText(_ date: Date, reference: Date, style: ResetTimeStyle, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        switch style {
        case .relative: countdown(to: date, from: reference)
        case .exact: date > reference ? clock(date, reference: reference, calendar: calendar, locale: locale) : nil
        }
    }

    /// "just now", "4 min ago", "3h ago", "2 days ago".
    static func age(of date: Date, reference: Date) -> String {
        let seconds = max(0, reference.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours)h ago" }
        return "\(hours / 24) days ago"
    }

    /// Saved-reset expiry is a deadline, so it always reads as a time or date, never a countdown:
    /// "today 3:40 PM", "tomorrow 9:00 AM", "Sat 9:00 AM" within a week, "Aug 15" beyond.
    static func expiry(_ date: Date, reference: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var calendar = calendar
        calendar.locale = locale
        let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let interval = date.timeIntervalSince(reference)
        if interval > 0, interval < 86_400 {
            let prefix = calendar.isDate(date, inSameDayAs: reference) ? "today" : "tomorrow"
            return "\(prefix) \(date.formatted(time))"
        }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if interval > 0, interval < 6 * 86_400 {
            return "\(date.formatted(style.weekday(.abbreviated))) \(date.formatted(time))"
        }
        return date.formatted(style.month(.abbreviated).day())
    }

    /// "Tue, Aug 11, 9:40 PM" for the full list of saved-reset expiries.
    static func fullDate(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var calendar = calendar
        calendar.locale = locale
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        return date.formatted(style.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
}
