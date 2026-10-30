import Foundation

public struct ClaudeCommandOutput: Sendable, Equatable {
    public var status: Int32
    public var standardOutput: Data

    public init(status: Int32, standardOutput: Data) {
        self.status = status
        self.standardOutput = standardOutput
    }
}

public enum ClaudeCLIError: Error, Equatable, Sendable, LocalizedError {
    case executableNotFound
    case launchFailed
    case timedOut
    case outputTooLarge
    case unreadableAuthStatus
    case loginFailed
    case loginCancelled

    public var errorDescription: String? {
        switch self {
        case .executableNotFound: "Claude Code is not installed. Install it, then try again."
        case .launchFailed: "Claude Code could not be started."
        case .timedOut: "Claude Code did not answer in time."
        case .outputTooLarge: "Claude Code returned more output than expected."
        case .unreadableAuthStatus: "Claude Code returned sign-in status Second Wind does not recognize."
        case .loginFailed: "Claude sign-in did not finish."
        case .loginCancelled: "Claude sign-in was cancelled."
        }
    }
}

/// Runs one Claude Code command against an app-owned configuration directory.
public protocol ClaudeCommandRunning: Sendable {
    func run(arguments: [String], configDirectory: URL, timeout: Duration) async throws -> ClaudeCommandOutput
}

/// Launches the official `claude` executable.
///
/// Every child gets a scrubbed environment: inherited `ANTHROPIC_*` and `CLAUDE_*` values are
/// removed so an API key or another config directory in the user's shell can never leak in, and
/// `CLAUDE_CONFIG_DIR` points at the profile's own directory. Claude Code keys its Keychain item
/// by that directory, so each profile signs in separately from the user's main Claude Code.
public struct ProcessClaudeCommandRunner: ClaudeCommandRunning {
    public var executableURL: URL
    public var maximumOutputBytes: Int

    public init(executableURL: URL, maximumOutputBytes: Int = 1_024 * 1_024) {
        self.executableURL = executableURL.standardizedFileURL
        self.maximumOutputBytes = maximumOutputBytes
    }

    public static var defaultExecutableURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/claude", isDirectory: false),
            home.appendingPathComponent(".claude/local/claude", isDirectory: false),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) } ?? candidates[0]
    }

    public static func environment(
        configDirectory: URL,
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = inherited.filter { key, _ in
            let normalized = key.uppercased()
            return !normalized.hasPrefix("ANTHROPIC_") && !normalized.hasPrefix("CLAUDE_")
        }
        environment["CLAUDE_CONFIG_DIR"] = configDirectory.standardizedFileURL.path
        environment["DISABLE_AUTOUPDATER"] = "1"
        return environment
    }

    func makeProcess(arguments: [String], configDirectory: URL) throws -> Process {
        guard executableURL.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executableURL.path)
        else { throw ClaudeCLIError.executableNotFound }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = configDirectory
        process.environment = Self.environment(configDirectory: configDirectory)
        process.standardError = FileHandle.nullDevice
        return process
    }

    public func run(arguments: [String], configDirectory: URL, timeout: Duration) async throws -> ClaudeCommandOutput {
        let process = try makeProcess(arguments: arguments, configDirectory: configDirectory)
        let output = Pipe()
        process.standardOutput = output
        process.standardInput = FileHandle.nullDevice
        let collector = OutputCollector(limit: maximumOutputBytes)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                collector.finish()
            } else if !collector.append(data) {
                process.terminate()
            }
        }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    output.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: ClaudeCLIError.launchFailed)
                    return
                }
                let deadline = DispatchTime.now() + .milliseconds(Int(timeout.components.seconds * 1_000))
                DispatchQueue.global().asyncAfter(deadline: deadline) {
                    if process.isRunning {
                        collector.markTimedOut()
                        process.terminate()
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        // A helper that outlives Claude Code could hold the pipe open; stop waiting shortly after exit.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { collector.finish() }
        let data = await collector.waitForEnd()
        if collector.didTimeOut { throw ClaudeCLIError.timedOut }
        if collector.didOverflow { throw ClaudeCLIError.outputTooLarge }
        try Task.checkCancellation()
        return ClaudeCommandOutput(status: status, standardOutput: data)
    }
}

/// Thread-safe output buffer shared between the pipe handler and the awaiting task.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var ended = false
    private var waiters: [CheckedContinuation<Data, Never>] = []
    private(set) var didOverflow = false
    private var timedOut = false

    init(limit: Int) { self.limit = limit }

    var didTimeOut: Bool { lock.withLock { timedOut } }

    func markTimedOut() { lock.withLock { timedOut = true } }

    /// Returns false once the limit is exceeded.
    func append(_ chunk: Data) -> Bool {
        lock.withLock {
            guard !didOverflow else { return false }
            data.append(chunk)
            if data.count > limit {
                didOverflow = true
                data.removeAll()
                return false
            }
            return true
        }
    }

    func snapshot() -> Data { lock.withLock { data } }

    func finish() {
        let pending: [CheckedContinuation<Data, Never>] = lock.withLock {
            ended = true
            defer { waiters.removeAll() }
            return waiters
        }
        let result = snapshot()
        for waiter in pending { waiter.resume(returning: result) }
    }

    func waitForEnd() async -> Data {
        await withCheckedContinuation { continuation in
            let result: Data? = lock.withLock {
                if ended { return data }
                waiters.append(continuation)
                return nil
            }
            if let result { continuation.resume(returning: result) }
        }
    }
}

/// Reads Claude plan usage through Claude Code's own commands. It never reads Claude
/// credentials and never contacts Anthropic directly.
public struct ClaudeCLI: Sendable {
    public var runner: any ClaudeCommandRunning
    public var commandTimeout: Duration

    public init(runner: any ClaudeCommandRunning, commandTimeout: Duration = .seconds(45)) {
        self.runner = runner
        self.commandTimeout = commandTimeout
    }

    public func authStatus(configDirectory: URL) async throws -> ClaudeAuthStatus {
        // `auth status` exits 1 when signed out but still prints JSON.
        let output = try await runner.run(
            arguments: ["auth", "status", "--json"],
            configDirectory: configDirectory,
            timeout: commandTimeout
        )
        guard let status = try? JSONDecoder().decode(ClaudeAuthStatus.self, from: output.standardOutput) else {
            throw ClaudeCLIError.unreadableAuthStatus
        }
        return status
    }

    public func usage(configDirectory: URL, observedAt: Date = Date()) async throws -> ClaudeUsageReport {
        let output = try await runner.run(
            arguments: ["-p", "/usage", "--output-format", "json", "--no-session-persistence"],
            configDirectory: configDirectory,
            timeout: commandTimeout
        )
        return try ClaudeUsageParser.parse(output.standardOutput, observedAt: observedAt)
    }
}

/// One interactive `claude auth login --claudeai` run. Claude Code opens the browser itself and
/// waits for its localhost callback; the printed fallback URL is captured so the app can offer it
/// again if the browser window was closed.
public final class ClaudeLoginSession: @unchecked Sendable {
    private let runner: ProcessClaudeCommandRunner
    private let configDirectory: URL
    private let email: String?
    private let lock = NSLock()
    private var process: Process?
    private var input: Pipe?
    private var cancelled = false

    public init(executableURL: URL, configDirectory: URL, email: String?) {
        self.runner = ProcessClaudeCommandRunner(executableURL: executableURL)
        self.configDirectory = configDirectory
        self.email = email
    }

    static func arguments(email: String?) -> [String] {
        var arguments = ["auth", "login", "--claudeai"]
        if let email, !email.isEmpty { arguments += ["--email", email] }
        return arguments
    }

    static func firstURL(in text: String) -> URL? {
        for token in text.split(whereSeparator: { $0.isWhitespace }) where token.hasPrefix("https://") {
            if let url = URL(string: String(token)), url.host != nil { return url }
        }
        return nil
    }

    /// Runs until Claude Code exits. `onURL` fires at most once with the sign-in page.
    public func run(timeout: Duration = .seconds(600), onURL: @escaping @Sendable (URL) -> Void) async throws {
        let process = try runner.makeProcess(arguments: Self.arguments(email: email), configDirectory: configDirectory)
        let output = Pipe()
        // Keep stdin open: Claude Code waits on it for a pasted code if the callback fails.
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        let collector = OutputCollector(limit: 64 * 1_024)
        let reported = LockedFlag()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                collector.finish()
                return
            }
            _ = collector.append(data)
            if !reported.isSet,
               let url = Self.firstURL(in: String(decoding: collector.snapshot(), as: UTF8.self)),
               reported.set() {
                onURL(url)
            }
        }

        let alreadyCancelled: Bool = lock.withLock {
            self.process = process
            self.input = input
            return cancelled
        }
        guard !alreadyCancelled else { throw ClaudeCLIError.loginCancelled }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    output.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: ClaudeCLIError.launchFailed)
                    return
                }
                let deadline = DispatchTime.now() + .seconds(Int(timeout.components.seconds))
                DispatchQueue.global().asyncAfter(deadline: deadline) {
                    if process.isRunning {
                        collector.markTimedOut()
                        process.terminate()
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { collector.finish() }
        _ = await collector.waitForEnd()
        try? input.fileHandleForWriting.close()
        if lock.withLock({ cancelled }) || Task.isCancelled { throw ClaudeCLIError.loginCancelled }
        if collector.didTimeOut { throw ClaudeCLIError.timedOut }
        guard status == 0 else { throw ClaudeCLIError.loginFailed }
    }

    public func cancel() {
        let running: Process? = lock.withLock {
            cancelled = true
            return process
        }
        if let running, running.isRunning { running.terminate() }
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    /// Returns true only for the caller that flipped the flag.
    func set() -> Bool {
        lock.withLock {
            guard !value else { return false }
            value = true
            return true
        }
    }
}
