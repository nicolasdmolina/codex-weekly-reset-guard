import Foundation
import SecondWindCore

enum PreflightOutputFormat: Equatable, Sendable {
    case plain
    case json
}

struct PreflightInvocation: Equatable, Sendable {
    var request: PreflightRequest
    var format: PreflightOutputFormat
    var snapshotURL: URL
}

/// `SecondWind --preflight`: a read-only quota check for scripts that are about to start a
/// long job. It reads only the snapshot the running app publishes.
enum PreflightCommandLine {
    static let usage = "--preflight [--session <0-100>] [--weekly <0-100>] [--provider codex|claude|antigravity] [--account <uuid>] [--json] [--snapshot <absolute-path>]"
    static let usageExitCode: Int32 = 64

    private static let options: Set<String> = [
        "--session", "--weekly", "--provider", "--account", "--json", "--snapshot",
    ]

    /// Parses the arguments after `--preflight`. Decides from the arguments alone.
    static func parse(
        _ arguments: [String],
        defaultSnapshotURL: URL = PreflightSnapshotFile.url()
    ) throws -> PreflightInvocation {
        var session: Int?
        var weekly: Int?
        var provider: QuotaProvider?
        var accountID: UUID?
        var format = PreflightOutputFormat.plain
        var snapshotURL = defaultSnapshotURL
        var seen = Set<String>()

        var index = arguments.startIndex
        while index < arguments.endIndex {
            let option = arguments[index]
            guard option.hasPrefix("--") else {
                throw GuardCommandLineError.unexpectedArgument(option)
            }
            guard options.contains(option) else {
                throw GuardCommandLineError.unknownOption(option)
            }
            guard seen.insert(option).inserted else {
                throw GuardCommandLineError.invalidPreflight("\(option) was given more than once.")
            }
            if option == "--json" {
                format = .json
                index += 1
                continue
            }
            guard index + 1 < arguments.endIndex else {
                throw GuardCommandLineError.missingValue(option: option)
            }
            let value = arguments[index + 1]
            switch option {
            case "--session":
                session = try percent(value, option: option)
            case "--weekly":
                weekly = try percent(value, option: option)
            case "--provider":
                guard let parsed = QuotaProvider(rawValue: value) else {
                    throw GuardCommandLineError.invalidPreflight("--provider must be codex, claude or antigravity.")
                }
                provider = parsed
            case "--account":
                guard let parsed = UUID(uuidString: value) else {
                    throw GuardCommandLineError.invalidPreflight("--account must be an account ID (a UUID).")
                }
                accountID = parsed
            case "--snapshot":
                guard value.hasPrefix("/") else {
                    throw GuardCommandLineError.invalidPreflight("--snapshot must be an absolute path.")
                }
                snapshotURL = URL(fileURLWithPath: value, isDirectory: false)
            default:
                throw GuardCommandLineError.unknownOption(option)
            }
            index += 2
        }

        guard let request = PreflightRequest(
            minimumSessionPercent: session,
            minimumWeeklyPercent: weekly,
            provider: provider,
            accountID: accountID
        ) else {
            throw GuardCommandLineError.invalidPreflight("Give --session, --weekly or both.")
        }
        return PreflightInvocation(request: request, format: format, snapshotURL: snapshotURL)
    }

    private static func percent(_ value: String, option: String) throws -> Int {
        guard value.allSatisfy(\.isASCII), let number = Int(value), (0...100).contains(number) else {
            throw GuardCommandLineError.invalidPreflight("\(option) must be a whole number from 0 to 100.")
        }
        return number
    }

    /// Prints the result to standard output and returns the exit code.
    static func execute(_ invocation: PreflightInvocation, now: Date = Date()) -> Int32 {
        let (output, code) = run(invocation, now: now)
        FileHandle.standardOutput.write(Data((output + "\n").utf8))
        return code
    }

    static func run(_ invocation: PreflightInvocation, now: Date) -> (output: String, exitCode: Int32) {
        let outcome = PreflightEvaluator.evaluate(
            invocation.request,
            snapshot: PreflightSnapshotFile.read(from: invocation.snapshotURL),
            now: now
        )
        let output = switch invocation.format {
        case .plain: plain(outcome, now: now)
        case .json: json(outcome)
        }
        return (output, outcome.result.exitCode)
    }

    /// Usage errors are plain text on standard error, even when `--json` was requested.
    static func reportUsageError(_ error: any Error) -> Int32 {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        FileHandle.standardError.write(Data("Second Wind preflight: \(message)\nUsage: SecondWind \(usage)\n".utf8))
        return usageExitCode
    }

    static func suggestedCommand(executablePath: String, provider: QuotaProvider, accountID: UUID) -> String {
        let quoted = "'" + executablePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "\(quoted) --preflight --provider \(provider.rawValue) --account \(accountID.uuidString.lowercased()) --session 10 --weekly 10"
    }

    // MARK: Plain text

    static func plain(_ outcome: PreflightOutcome, now: Date) -> String {
        guard let account = outcome.account else {
            var lines = ["Quota unknown (\(outcome.reason?.rawValue ?? "unknown")). \(sentence(for: outcome.reason))"]
            lines += outcome.candidates.map { "\($0.provider.rawValue) \($0.accountID.uuidString.lowercased())" }
            return lines.joined(separator: "\n")
        }
        let name = "\(account.provider.rawValue) account \(account.accountID.uuidString.lowercased())"
        let header = switch outcome.result {
        case .enough: "Enough quota on \(name)."
        case .low: outcome.reason == .usageBlocked ? "Usage blocked on \(name)." : "Low quota on \(name)."
        case .unknown: "Quota unknown on \(name)."
        }
        return ([header] + outcome.checks.map { checkLine($0, now: now) }).joined(separator: "\n")
    }

    private static func checkLine(_ check: PreflightCheck, now: Date) -> String {
        var label = check.requirement.window == .session ? "Session" : "Weekly"
        if let model = check.window?.kind.modelScope {
            label += " (\(model))"
        }
        let minimum = check.requirement.minimumPercent
        switch check.result {
        case .enough, .low:
            if check.reason == .usageBlocked { return "\(label): \(sentence(for: check.reason))" }
            guard let window = check.window else { return "\(label): no value." }
            let left = displayPercent(window.remainingPercent)
            var line = check.result == .enough
                ? "\(label): \(left) left, at least the \(minimum)% required."
                : window.remainingPercent <= 0
                    ? "\(label): nothing left."
                    : "\(label): \(left) left, below the \(minimum)% required."
            if let resetsAt = window.resetsAt {
                line += " Resets \(relative(resetsAt, now: now))."
            }
            return line
        case .unknown:
            var code = check.reason?.rawValue ?? "unknown"
            if let failure = check.failure {
                code += ": \(failure.preflightCode)"
            }
            return "\(label): unknown (\(code)). \(sentence(for: check.reason))"
        }
    }

    /// Floors so a printed value never contradicts the verdict (19.6 shows as 19, not 20).
    private static func displayPercent(_ value: Double) -> String {
        let floored = Int(value.rounded(.down))
        return floored == 0 && value > 0 ? "under 1%" : "\(floored)%"
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let minutes = Int(date.timeIntervalSince(now) / 60)
        if minutes < 1 { return "in under a minute" }
        if minutes < 60 { return "in \(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return "in \(hours) h \(minutes % 60) min" }
        return "in \(hours / 24) d \(hours % 24) h"
    }

    private static func sentence(for reason: PreflightReason?) -> String {
        switch reason {
        case .snapshotMissing: "Second Wind has not published a quota reading. Open Second Wind and try again."
        case .snapshotUnreadable: "The quota reading file could not be read safely."
        case .snapshotInvalid: "The quota reading file is malformed."
        case .snapshotUnsupportedVersion: "The quota reading file comes from a different Second Wind version."
        case .rosterIncomplete: "Second Wind is still loading its accounts."
        case .accountNotFound: "No account matches."
        case .accountAmbiguous: "More than one account matches. Pass --account with one of these IDs:"
        case .noReading: "There is no reading yet."
        case .refreshFailed: "The last check failed."
        case .readingStale: "The last reading is too old."
        case .readingFromFuture: "The last reading is dated in the future."
        case .windowMissing: "The provider did not report this window."
        case .windowResetPassed: "The window reset after the last reading."
        case .usageBlocked: "Codex reports that ordinary usage is blocked."
        case .usageUnconfirmed: "Codex could not confirm that ordinary usage is available."
        case nil: "No reason was given."
        }
    }

    // MARK: JSON

    static func json(_ outcome: PreflightOutcome) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(OutcomeJSON(outcome)),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"result":"unknown"}"#
        }
        return text
    }

    private struct OutcomeJSON: Encodable {
        let outcome: PreflightOutcome

        init(_ outcome: PreflightOutcome) { self.outcome = outcome }

        enum Keys: String, CodingKey {
            case schemaVersion, result, exitCode, reason, account, checks, candidates
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(1, forKey: .schemaVersion)
            try container.encode(outcome.result.rawValue, forKey: .result)
            try container.encode(outcome.result.exitCode, forKey: .exitCode)
            try container.encode(outcome.reason?.rawValue, forKey: .reason)
            try container.encode(outcome.account.map(AccountJSON.init), forKey: .account)
            try container.encode(outcome.checks.map(CheckJSON.init), forKey: .checks)
            try container.encode(outcome.candidates.map(AccountJSON.init), forKey: .candidates)
        }
    }

    private struct AccountJSON: Encodable {
        let provider: String
        let id: String

        init(_ account: PreflightAccountReference) {
            provider = account.provider.rawValue
            id = account.accountID.uuidString.lowercased()
        }
    }

    private struct CheckJSON: Encodable {
        let check: PreflightCheck

        init(_ check: PreflightCheck) { self.check = check }

        enum Keys: String, CodingKey {
            case window, minimumPercent, result, reason, failure, scope
            case remainingPercent, resetsAt, observedAt, staleAfter
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(check.requirement.window.rawValue, forKey: .window)
            try container.encode(check.requirement.minimumPercent, forKey: .minimumPercent)
            try container.encode(check.result.rawValue, forKey: .result)
            try container.encode(check.reason?.rawValue, forKey: .reason)
            try container.encode(check.failure?.preflightCode, forKey: .failure)
            let scope = check.window?.kind.modelScope
            try container.encode(scope, forKey: .scope)
            try container.encode(check.window?.remainingPercent, forKey: .remainingPercent)
            try container.encode(check.window?.resetsAt, forKey: .resetsAt)
            try container.encode(check.observedAt, forKey: .observedAt)
            try container.encode(check.staleAfter, forKey: .staleAfter)
        }
    }
}
