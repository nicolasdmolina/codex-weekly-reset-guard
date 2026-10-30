import Foundation

/// One Claude plan-limit window as reported by Claude Code's `/usage` command.
public struct ClaudeUsageWindow: Codable, Sendable, Equatable {
    public enum Scope: Codable, Sendable, Equatable, Hashable {
        /// The rolling five-hour session limit.
        case session
        /// The weekly limit shared by all models.
        case weekly
        /// A weekly limit for one model family, such as "Sonnet only" or "Fable".
        case modelWeekly(String)

        /// Stable key used to remember which windows already produced an alert.
        public var key: String {
            switch self {
            case .session: "session"
            case .weekly: "weekly"
            case let .modelWeekly(name): "weekly:\(name)"
            }
        }
    }

    public var scope: Scope
    public var usedPercent: Double
    public var resetsAt: Date?

    public var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }

    public init(scope: Scope, usedPercent: Double, resetsAt: Date?) {
        self.scope = scope
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct ClaudeUsageReport: Codable, Sendable, Equatable {
    public var session: ClaudeUsageWindow?
    public var weekly: ClaudeUsageWindow?
    public var modelWeekly: [ClaudeUsageWindow]
    public var observedAt: Date

    public init(
        session: ClaudeUsageWindow?,
        weekly: ClaudeUsageWindow?,
        modelWeekly: [ClaudeUsageWindow] = [],
        observedAt: Date
    ) {
        self.session = session
        self.weekly = weekly
        self.modelWeekly = modelWeekly
        self.observedAt = observedAt
    }

    public var allWindows: [ClaudeUsageWindow] {
        [session, weekly].compactMap { $0 } + modelWeekly
    }

    /// The window with the least room left. Session and all-model weekly limits win ties,
    /// because they block every model.
    public var tightestWindow: ClaudeUsageWindow? {
        allWindows.min { $0.remainingPercent < $1.remainingPercent }
    }
}

public enum ClaudeUsageParseError: Error, Equatable, Sendable, LocalizedError {
    case malformedOutput
    /// Claude Code answered with a model turn instead of its local `/usage` command. Polling
    /// must stop, because every further poll could spend plan usage.
    case notLocalCommand
    case commandFailed
    case noPlanLimits

    public var errorDescription: String? {
        switch self {
        case .malformedOutput:
            "Claude Code returned usage in a format Second Wind does not recognize."
        case .notLocalCommand:
            "This Claude Code version no longer answers /usage locally. Monitoring stopped so it cannot spend usage."
        case .commandFailed:
            "Claude Code could not read plan usage."
        case .noPlanLimits:
            "Claude Code did not report plan limits for this account."
        }
    }
}

/// Parses `claude -p /usage --output-format json`.
///
/// The text lines come from Claude Code's formatter, for example
/// `Current session: 31% used · resets Oct 29 at 9:40pm (America/New_York)`.
/// Unknown lines are ignored; a recognised line with an unreadable reset time keeps its
/// percentage and drops the time rather than guessing.
public enum ClaudeUsageParser {
    private struct Envelope: Decodable {
        var type: String?
        var subtype: String?
        var is_error: Bool?
        var result: String?
        var local_command: String?
        var num_turns: Int?
    }

    public static func parse(
        _ data: Data,
        observedAt: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) throws -> ClaudeUsageReport {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw ClaudeUsageParseError.malformedOutput
        }
        guard envelope.local_command == "usage", (envelope.num_turns ?? 0) == 0 else {
            throw ClaudeUsageParseError.notLocalCommand
        }
        guard envelope.is_error != true, let text = envelope.result else {
            throw ClaudeUsageParseError.commandFailed
        }
        return try parseText(text, observedAt: observedAt, calendar: calendar)
    }

    public static func parseText(
        _ text: String,
        observedAt: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) throws -> ClaudeUsageReport {
        var session: ClaudeUsageWindow?
        var weekly: ClaudeUsageWindow?
        var models: [ClaudeUsageWindow] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let window = parseLine(line, now: observedAt, calendar: calendar) else { continue }
            switch window.scope {
            case .session:
                guard session == nil else { throw ClaudeUsageParseError.malformedOutput }
                session = window
            case .weekly:
                guard weekly == nil else { throw ClaudeUsageParseError.malformedOutput }
                weekly = window
            case .modelWeekly:
                guard !models.contains(where: { $0.scope == window.scope }) else {
                    throw ClaudeUsageParseError.malformedOutput
                }
                models.append(window)
            }
        }
        guard session != nil || weekly != nil || !models.isEmpty else {
            throw ClaudeUsageParseError.noPlanLimits
        }
        return ClaudeUsageReport(session: session, weekly: weekly, modelWeekly: models, observedAt: observedAt)
    }

    static func parseLine(_ line: String, now: Date, calendar: Calendar) -> ClaudeUsageWindow? {
        guard let colon = line.range(of: ": ") else { return nil }
        let title = String(line[..<colon.lowerBound])
        let scope: ClaudeUsageWindow.Scope
        if title == "Current session" {
            scope = .session
        } else if title == "Current week (all models)" {
            scope = .weekly
        } else if title.hasPrefix("Current week ("), title.hasSuffix(")") {
            let name = title.dropFirst("Current week (".count).dropLast()
            guard !name.isEmpty else { return nil }
            scope = .modelWeekly(String(name))
        } else {
            return nil
        }

        let rest = line[colon.upperBound...]
        let parts = rest.components(separatedBy: " \u{B7} ")
        guard let usage = parts.first, usage.hasSuffix("% used"),
              let percent = Double(usage.dropLast("% used".count)),
              percent.isFinite, (0...100).contains(percent)
        else { return nil }

        var resetsAt: Date?
        if let resetPart = parts.dropFirst().first(where: { $0.hasPrefix("resets ") }) {
            resetsAt = parseResetTime(String(resetPart.dropFirst("resets ".count)), now: now, calendar: calendar)
        }
        return ClaudeUsageWindow(scope: scope, usedPercent: percent, resetsAt: resetsAt)
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// Reads `Oct 29 at 9:40pm (America/New_York)`, `Jan 2, 2027 at 3am (UTC)` or `9:40pm (UTC)`.
    static func parseResetTime(_ text: String, now: Date, calendar baseCalendar: Calendar) -> Date? {
        guard text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return nil }
        let zoneName = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
        guard let zone = TimeZone(identifier: zoneName) else { return nil }
        var calendar = baseCalendar
        calendar.timeZone = zone
        let body = text[..<open].trimmingCharacters(in: .whitespaces)

        let datePart: Substring?
        let timePart: Substring
        if let at = body.range(of: " at ") {
            datePart = body[..<at.lowerBound]
            timePart = body[at.upperBound...]
        } else if let comma = body.lastIndex(of: ","), body[body.index(after: comma)...].contains(where: { $0 == "m" }) {
            datePart = body[..<comma]
            timePart = body[body.index(after: comma)...].drop(while: { $0 == " " })
        } else {
            datePart = nil
            timePart = Substring(body)
        }
        guard let (hour, minute) = parseClock(timePart) else { return nil }

        guard let datePart else {
            let today = calendar.dateComponents([.year, .month, .day], from: now)
            for offset in 0...1 {
                var components = today
                components.hour = hour
                components.minute = minute
                guard let base = calendar.date(from: components),
                      let candidate = calendar.date(byAdding: .day, value: offset, to: base)
                else { return nil }
                if candidate > now.addingTimeInterval(-3_600) { return candidate }
            }
            return nil
        }

        let pieces = datePart.replacingOccurrences(of: ",", with: "").split(separator: " ")
        guard pieces.count == 2 || pieces.count == 3,
              let monthIndex = months.firstIndex(of: String(pieces[0])),
              let day = Int(pieces[1]), (1...31).contains(day)
        else { return nil }

        func make(year: Int) -> Date? {
            var components = DateComponents()
            components.year = year
            components.month = monthIndex + 1
            components.day = day
            components.hour = hour
            components.minute = minute
            guard let date = calendar.date(from: components),
                  calendar.component(.day, from: date) == day
            else { return nil }
            return date
        }

        if pieces.count == 3 {
            guard let year = Int(pieces[2]) else { return nil }
            return make(year: year)
        }
        // Claude Code omits the year when it matches the current one. Choose the candidate
        // nearest to now so a reset just after New Year still lands in January.
        let currentYear = calendar.component(.year, from: now)
        return [currentYear - 1, currentYear, currentYear + 1]
            .compactMap(make(year:))
            .min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
    }

    private static func parseClock(_ text: Substring) -> (Int, Int)? {
        let lower = text.lowercased()
        let isPM: Bool
        if lower.hasSuffix("pm") { isPM = true } else if lower.hasSuffix("am") { isPM = false } else { return nil }
        let digits = lower.dropLast(2)
        let parts = digits.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              let hour12 = Int(parts[0]), (1...12).contains(hour12)
        else { return nil }
        let minute = parts.count == 2 ? Int(parts[1]) : 0
        guard let minute, (0...59).contains(minute), parts.count == 1 || parts[1].count == 2 else { return nil }
        let hour = (hour12 % 12) + (isPM ? 12 : 0)
        return (hour, minute)
    }
}

/// The subset of `claude auth status --json` that Second Wind relies on.
public struct ClaudeAuthStatus: Decodable, Sendable, Equatable {
    public var loggedIn: Bool
    public var authMethod: String?
    public var email: String?
    public var subscriptionType: String?

    public init(loggedIn: Bool, authMethod: String?, email: String?, subscriptionType: String?) {
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.email = email
        self.subscriptionType = subscriptionType
    }

    /// Plan limits apply only to a Claude subscription sign-in, not to Console API keys.
    public var usesSubscription: Bool { loggedIn && authMethod == "claude.ai" }

    public var planName: String? {
        guard let subscriptionType, !subscriptionType.isEmpty else { return nil }
        switch subscriptionType.lowercased() {
        case "pro": return "Pro"
        case "max": return "Max"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        default: return subscriptionType.prefix(1).uppercased() + subscriptionType.dropFirst()
        }
    }
}

/// Decides when a Claude window is low enough to notify. Each window alerts at most once per
/// reset cycle, keyed by its scope and reset time, so polling never repeats a notification.
public enum ClaudeAlertPolicy {
    public static let defaultThresholdRemainingPercent: Double = 10

    public struct Alert: Equatable, Sendable {
        public var window: ClaudeUsageWindow
        public var key: String
    }

    public static func key(for window: ClaudeUsageWindow) -> String {
        let reset = window.resetsAt.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "unknown"
        return "\(window.scope.key)@\(reset)"
    }

    public static func newAlerts(
        for report: ClaudeUsageReport,
        alreadySent: Set<String>,
        thresholdRemainingPercent: Double = defaultThresholdRemainingPercent
    ) -> [Alert] {
        report.allWindows
            .filter { $0.remainingPercent <= thresholdRemainingPercent }
            .map { Alert(window: $0, key: key(for: $0)) }
            .filter { !alreadySent.contains($0.key) }
    }
}
