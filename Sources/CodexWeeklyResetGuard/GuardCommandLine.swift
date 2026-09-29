import Foundation
import Darwin
import CodexWeeklyResetGuardCore

enum GuardLaunchCommand: Equatable {
    case production
    case diagnosticUI(supportDirectory: URL)
    case preview(PreviewKind)
    case renderPreview(kind: PreviewKind, destinationPath: String)
    case renderAllPreviews(directoryPath: String)
    case selfTest
    case doctor
}

enum GuardCommandLineError: Error, Equatable, LocalizedError {
    case unknownOption(String)
    case unexpectedArgument(String)
    case conflictingModes([String])
    case missingValue(option: String)
    case invalidPreviewKind(String)
    case liveModeInPreviewBundle
    case conflictingBundleModes
    case invalidDiagnosticDirectory
    case argumentsInDiagnosticBundle
    case malformedArguments(option: String, usage: String)

    var errorDescription: String? {
        switch self {
        case let .unknownOption(option):
            "Unknown option: \(option)"
        case let .unexpectedArgument(argument):
            "Unexpected argument: \(argument)"
        case let .conflictingModes(options):
            "Conflicting modes: \(options.joined(separator: ", "))"
        case let .missingValue(option):
            "Missing value for \(option)."
        case let .invalidPreviewKind(value):
            "Invalid preview kind '\(value)'. Expected one of: \(PreviewKind.allCases.map(\.rawValue).joined(separator: ", "))."
        case .liveModeInPreviewBundle:
            "A preview-only bundle cannot run live account services."
        case .conflictingBundleModes:
            "A bundle cannot enable both preview and live diagnostic modes."
        case .invalidDiagnosticDirectory:
            "The diagnostic directory must be an existing private, user-owned directory strictly inside a system temporary directory or a private, user-owned TMPDIR."
        case .argumentsInDiagnosticBundle:
            "A diagnostic bundle must be launched without command-line arguments."
        case let .malformedArguments(_, usage):
            "Usage: \(usage)"
        }
    }
}

enum GuardCommandLine {
    private static var previewKindsUsage: String {
        "<\(PreviewKind.allCases.map(\.rawValue).joined(separator: "|"))>"
    }

    private static let modeOptions: Set<String> = [
        "--preview",
        "--render-preview",
        "--render-all-previews",
        "--self-test",
        "--doctor",
    ]

    /// Parses arguments after the executable name. Invalid input always throws; it can never
    /// silently degrade into the production runtime.
    static func parse(
        _ arguments: [String],
        bundledPreviewKind: String? = nil,
        bundledDiagnosticDirectory: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        systemTemporaryRoots: [URL] = [FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/tmp")],
        productionDirectory: URL = ProfileConfiguration.defaultApplicationSupportDirectory
    ) throws -> GuardLaunchCommand {
        guard bundledPreviewKind == nil || bundledDiagnosticDirectory == nil else {
            throw GuardCommandLineError.conflictingBundleModes
        }
        if let bundledDiagnosticDirectory {
            let directory = try diagnosticDirectory(
                bundledDiagnosticDirectory,
                processTemporaryDirectory: environment["TMPDIR"],
                systemTemporaryRoots: systemTemporaryRoots,
                productionDirectory: productionDirectory
            )
            guard arguments.isEmpty else { throw GuardCommandLineError.argumentsInDiagnosticBundle }
            return .diagnosticUI(supportDirectory: directory)
        }
        if let bundledPreviewKind {
            // QA bundles must stay synthetic even when a UI tool reopens them without args.
            // Validate the marker first so malformed metadata can never launch production.
            let kind = try parsePreviewKind(bundledPreviewKind)
            guard !arguments.isEmpty else { return .preview(kind) }
            let command = try parseArguments(arguments)
            guard command != .production, command != .doctor else {
                throw GuardCommandLineError.liveModeInPreviewBundle
            }
            return command
        }
        return try parseArguments(arguments)
    }

    private static func diagnosticDirectory(
        _ path: String,
        processTemporaryDirectory: String?,
        systemTemporaryRoots: [URL],
        productionDirectory: URL
    ) throws -> URL {
        guard path.hasPrefix("/") else { throw GuardCommandLineError.invalidDiagnosticDirectory }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GuardCommandLineError.invalidDiagnosticDirectory
        }
        // Foundation does not resolve ancestor symlinks reliably for a nonexistent leaf. The
        // caller must create this isolated directory first (for example with mktemp -d).
        let directory = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        var temporaryRoots = systemTemporaryRoots
            .map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        if let processTemporaryDirectory, processTemporaryDirectory.hasPrefix("/"),
           FileManager.default.fileExists(atPath: processTemporaryDirectory, isDirectory: &isDirectory),
           isDirectory.boolValue {
            let root = URL(fileURLWithPath: processTemporaryDirectory, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
            if isPrivateOwnedDirectory(root) {
                temporaryRoots.append(root.path)
            }
        }
        let production = try resolvingMissingDirectory(productionDirectory).path
        guard isPrivateOwnedDirectory(directory),
              !temporaryRoots.contains(directory.path),
              temporaryRoots.contains(where: { directory.path.hasPrefix($0 + "/") }),
              directory.path != production,
              !directory.path.hasPrefix(production + "/"),
              !production.hasPrefix(directory.path + "/") else {
            throw GuardCommandLineError.invalidDiagnosticDirectory
        }
        return directory
    }

    private static func resolvingMissingDirectory(_ directory: URL) throws -> URL {
        var ancestor = directory.standardizedFileURL
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path,
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) == nil else {
                throw GuardCommandLineError.invalidDiagnosticDirectory
            }
            missingComponents.append(ancestor.lastPathComponent)
            ancestor = parent
        }
        return missingComponents.reversed().reduce(ancestor.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
    }

    private static func isPrivateOwnedDirectory(_ directory: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
              attributes[.type] as? FileAttributeType == .typeDirectory,
              let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == geteuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber else { return false }
        return permissions.intValue & 0o777 == 0o700
    }

    private static func parseArguments(_ arguments: [String]) throws -> GuardLaunchCommand {
        guard !arguments.isEmpty else { return .production }

        if let unknown = arguments.first(where: { $0.hasPrefix("--") && !modeOptions.contains($0) }) {
            throw GuardCommandLineError.unknownOption(unknown)
        }

        let suppliedModes = arguments.filter { modeOptions.contains($0) }
        if suppliedModes.count > 1 {
            throw GuardCommandLineError.conflictingModes(suppliedModes)
        }

        guard let option = suppliedModes.first else {
            throw GuardCommandLineError.unexpectedArgument(arguments[0])
        }
        guard arguments.first == option else {
            throw GuardCommandLineError.unexpectedArgument(arguments[0])
        }

        switch option {
        case "--preview":
            guard arguments.count >= 2 else {
                throw GuardCommandLineError.missingValue(option: option)
            }
            guard arguments.count == 2 else {
                throw GuardCommandLineError.malformedArguments(
                    option: option,
                    usage: "--preview \(previewKindsUsage)"
                )
            }
            return .preview(try parsePreviewKind(arguments[1]))

        case "--render-preview":
            guard arguments.count >= 2 else {
                throw GuardCommandLineError.missingValue(option: option)
            }
            let kind = try parsePreviewKind(arguments[1])
            guard arguments.count >= 3 else {
                throw GuardCommandLineError.missingValue(option: option)
            }
            guard arguments.count == 3, !arguments[2].isEmpty else {
                throw GuardCommandLineError.malformedArguments(
                    option: option,
                    usage: "--render-preview \(previewKindsUsage) <png-path>"
                )
            }
            return .renderPreview(kind: kind, destinationPath: arguments[2])

        case "--render-all-previews":
            guard arguments.count >= 2 else {
                throw GuardCommandLineError.missingValue(option: option)
            }
            guard arguments.count == 2, !arguments[1].isEmpty else {
                throw GuardCommandLineError.malformedArguments(
                    option: option,
                    usage: "--render-all-previews <directory>"
                )
            }
            return .renderAllPreviews(directoryPath: arguments[1])

        case "--self-test":
            guard arguments.count == 1 else {
                throw GuardCommandLineError.malformedArguments(option: option, usage: "--self-test")
            }
            return .selfTest

        case "--doctor":
            guard arguments.count == 1 else {
                throw GuardCommandLineError.malformedArguments(option: option, usage: "--doctor")
            }
            return .doctor

        default:
            // The option was checked against modeOptions above. Keeping a default makes this
            // parser fail closed if the recognized set and switch ever drift apart.
            throw GuardCommandLineError.unknownOption(option)
        }
    }

    private static func parsePreviewKind(_ value: String) throws -> PreviewKind {
        guard let kind = PreviewKind(rawValue: value) else {
            throw GuardCommandLineError.invalidPreviewKind(value)
        }
        return kind
    }
}
