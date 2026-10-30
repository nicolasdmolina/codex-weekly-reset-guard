import Foundation
import Testing
@testable import SecondWindCore

private struct FakeRunner: ClaudeCommandRunning {
    var outputs: [String: ClaudeCommandOutput]

    func run(arguments: [String], configDirectory: URL, timeout: Duration) async throws -> ClaudeCommandOutput {
        guard let output = outputs[arguments.joined(separator: " ")] else { throw ClaudeCLIError.launchFailed }
        return output
    }
}

@Test func childEnvironmentDropsInheritedClaudeAndAnthropicValues() {
    let config = URL(fileURLWithPath: "/tmp/sw/claude/abc", isDirectory: true)
    let environment = ProcessClaudeCommandRunner.environment(
        configDirectory: config,
        inherited: [
            "PATH": "/usr/bin",
            "ANTHROPIC_API_KEY": "sk-secret",
            "anthropic_base_url": "http://proxy",
            "CLAUDE_CONFIG_DIR": "/tmp/elsewhere/.claude",
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/tmp/elsewhere/.claude",
            "CLAUDE_CODE_OAUTH_TOKEN": "secret",
        ]
    )
    #expect(environment == [
        "PATH": "/usr/bin",
        "CLAUDE_CONFIG_DIR": "/tmp/sw/claude/abc",
        "DISABLE_AUTOUPDATER": "1",
    ])
}

@Test func processRunnerUsesTheProfileDirectory() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-runner-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = ProcessClaudeCommandRunner(executableURL: URL(fileURLWithPath: "/bin/sh"))
    let output = try await runner.run(
        arguments: ["-c", "printf '%s|%s' \"$CLAUDE_CONFIG_DIR\" \"$(pwd -P)\"; exit 3"],
        configDirectory: directory,
        timeout: .seconds(10)
    )
    let parts = String(decoding: output.standardOutput, as: UTF8.self).split(separator: "|").map(String.init)
    #expect(output.status == 3)
    #expect(parts.first == directory.standardizedFileURL.path)
    #expect(parts.last?.hasSuffix(directory.lastPathComponent) == true)
}

@Test func processRunnerEnforcesTimeoutAndOutputCap() async throws {
    let directory = FileManager.default.temporaryDirectory
    await #expect(throws: ClaudeCLIError.timedOut) {
        try await ProcessClaudeCommandRunner(executableURL: URL(fileURLWithPath: "/bin/sleep"))
            .run(arguments: ["30"], configDirectory: directory, timeout: .seconds(1))
    }
    await #expect(throws: ClaudeCLIError.outputTooLarge) {
        try await ProcessClaudeCommandRunner(executableURL: URL(fileURLWithPath: "/usr/bin/yes"), maximumOutputBytes: 4_096)
            .run(arguments: [], configDirectory: directory, timeout: .seconds(10))
    }
    await #expect(throws: ClaudeCLIError.executableNotFound) {
        try await ProcessClaudeCommandRunner(executableURL: URL(fileURLWithPath: "/nonexistent/claude"))
            .run(arguments: [], configDirectory: directory, timeout: .seconds(1))
    }
}

@Test func cliReadsSignedOutStatusAndUsage() async throws {
    let usage = #"{"type":"result","subtype":"success","is_error":false,"num_turns":0,"local_command":"usage","result":"Current session: 5% used"}"#
    let cli = ClaudeCLI(runner: FakeRunner(outputs: [
        "auth status --json": ClaudeCommandOutput(
            status: 1,
            standardOutput: Data(#"{"loggedIn":false,"authMethod":"none"}"#.utf8)
        ),
        "-p /usage --output-format json --no-session-persistence": ClaudeCommandOutput(
            status: 0,
            standardOutput: Data(usage.utf8)
        ),
    ]))
    let directory = URL(fileURLWithPath: "/tmp")
    #expect(try await cli.authStatus(configDirectory: directory).loggedIn == false)
    #expect(try await cli.usage(configDirectory: directory).session?.usedPercent == 5)
}

@Test func loginArgumentsAndFallbackURL() {
    #expect(ClaudeLoginSession.arguments(email: "a@b.co") == ["auth", "login", "--claudeai", "--email", "a@b.co"])
    #expect(ClaudeLoginSession.arguments(email: nil) == ["auth", "login", "--claudeai"])
    let text = "Opening browser to sign in…\nIf the browser did not open, visit: https://claude.ai/oauth/authorize?code=true&x=1\n"
    #expect(ClaudeLoginSession.firstURL(in: text)?.host == "claude.ai")
    #expect(ClaudeLoginSession.firstURL(in: "no link here") == nil)
}

/// Opt-in check against the installed Claude Code: `SECOND_WIND_LIVE_CLAUDE=1 swift test`.
/// Uses a fresh, signed-out config directory, so it cannot read or spend any account's usage.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SECOND_WIND_LIVE_CLAUDE"] == "1"))
func liveSignedOutProfileReportsNoPlanLimits() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-live-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cli = ClaudeCLI(runner: ProcessClaudeCommandRunner(executableURL: ProcessClaudeCommandRunner.defaultExecutableURL))

    let status = try await cli.authStatus(configDirectory: directory)
    #expect(!status.loggedIn)
    #expect(!status.usesSubscription)
    await #expect(throws: ClaudeUsageParseError.noPlanLimits) {
        try await cli.usage(configDirectory: directory)
    }
}
