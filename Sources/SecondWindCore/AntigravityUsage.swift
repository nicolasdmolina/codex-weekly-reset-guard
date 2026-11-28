import Foundation

public enum AntigravityUsageError: Error, Equatable, Sendable {
    case missingCLI
    case unavailable
    case unreadable
    /// The result did not prove the CLI handled the command without inference.
    case unverifiedCommand
}

public enum AntigravityCLI {
    /// Override the user's print-mode setting so /usage is always a built-in slash command.
    static let arguments = ["--settings", #"{"disableSlashCommands":false}"#, "--print-timeout", "20s",
                            "--output-format", "json", "--print", "/usage"]

    public static func usage(in directory: URL) async throws -> QuotaObservation {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/bin/agy"), URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
                          URL(fileURLWithPath: "/usr/local/bin/agy")]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw AntigravityUsageError.missingCLI
        }
        try PrivateFileIO.ensurePrivateDirectory(directory)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        process.standardError = FileHandle.nullDevice
        let output: CLICommandOutput
        do {
            output = try await BoundedCommand.run(process, maximumOutputBytes: 256 * 1024, timeout: .seconds(30))
        } catch BoundedCommand.Failure.launchFailed {
            throw AntigravityUsageError.unavailable
        } catch {
            // A timeout or truncated reply cannot establish that the CLI stayed in its local command.
            throw AntigravityUsageError.unverifiedCommand
        }
        let observation = try parse(output.standardOutput, at: Date())
        guard output.status == 0 else { throw AntigravityUsageError.unavailable }
        return observation
    }

    private struct Envelope: Decodable {
        struct Command: Decodable { let name: String }
        let status: String
        let num_turns: Int
        let usage: [String: Int]
        let command: Command?
    }

    private struct Report: Decodable {
        struct Command: Decodable {
            struct Payload: Decodable {
                struct Group: Decodable {
                    struct Bucket: Decodable {
                        let window: String
                        let remaining_fraction: Double?
                        let reset_time: String?
                        let disabled: Bool?
                    }
                    let name: String
                    let buckets: [Bucket]
                }
                let groups: [Group]
            }
            let data: Payload
        }
        let command: Command
    }

    public static func parse(_ data: Data, at now: Date) throws -> QuotaObservation {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.num_turns == 0, envelope.usage["total_tokens"] == 0,
              envelope.usage.values.allSatisfy({ $0 == 0 }) else { throw AntigravityUsageError.unverifiedCommand }
        guard envelope.status == "SUCCESS" else { throw AntigravityUsageError.unavailable }
        guard envelope.command?.name == "usage" else { throw AntigravityUsageError.unverifiedCommand }
        guard let groups = try? decoder.decode(Report.self, from: data).command.data.groups else {
            throw AntigravityUsageError.unreadable
        }
        var seen = Set<QuotaWindowKind>()
        var windows: [QuotaWindow] = []
        var unknown: [QuotaWindowKind] = []
        for group in groups {
            let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 100, name.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw AntigravityUsageError.unreadable
            }
            for bucket in group.buckets where bucket.disabled != true {
                let period: PreflightWindow
                switch bucket.window {
                case "5h": period = .session
                case "weekly": period = .weekly
                default: throw AntigravityUsageError.unreadable
                }
                let kind = QuotaWindowKind.group(period, name)
                guard seen.insert(kind).inserted else { throw AntigravityUsageError.unreadable }
                var reset: Date?
                if let raw = bucket.reset_time {
                    guard let date = (try? Date(raw, strategy: .iso8601))
                            ?? (try? Date(raw, strategy: .iso8601.time(includingFractionalSeconds: true))) else {
                        unknown.append(kind)
                        continue
                    }
                    // agy uses the Unix epoch when it has no refill date.
                    if date.timeIntervalSince1970 > 0 { reset = date }
                }
                guard let fraction = bucket.remaining_fraction, (0...1).contains(fraction) else {
                    unknown.append(kind)
                    continue
                }
                windows.append(QuotaWindow(kind: kind, usedPercent: 100 - 100 * fraction, resetsAt: reset))
            }
        }
        guard !seen.isEmpty else { throw AntigravityUsageError.unreadable }
        return QuotaObservation(observedAt: now, windows: windows, unreportedWindows: unknown, inventory: .notTracked)
    }
}
