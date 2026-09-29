import Testing
import Foundation
import CodexWeeklyResetGuardCore
@testable import CodexWeeklyResetGuard

@Suite struct GuardCommandLineTests {
    @Test func noArgumentsSelectProduction() throws {
        #expect(try GuardCommandLine.parse([]) == .production)
    }

    @Test func privateProcessTemporaryDirectoryAllowsDiagnosticOutsideSystemTemporaryRoots() throws {
        let fixture = try DiagnosticDirectories()
        defer { fixture.remove() }
        #expect(
            try GuardCommandLine.parse(
                [],
                bundledDiagnosticDirectory: fixture.diagnostic.path,
                environment: ["TMPDIR": fixture.temporary.path],
                systemTemporaryRoots: [fixture.systemTemporary],
                productionDirectory: fixture.production
            ) == .diagnosticUI(supportDirectory: fixture.diagnostic)
        )
    }

    @Test func nonexistentProcessTemporaryDirectoryCannotBecomeValidByStandardization() throws {
        let fixture = try DiagnosticDirectories()
        defer { fixture.remove() }
        #expect(throws: GuardCommandLineError.invalidDiagnosticDirectory) {
            try GuardCommandLine.parse(
                [],
                bundledDiagnosticDirectory: fixture.diagnostic.path,
                environment: ["TMPDIR": fixture.temporary.path + "/missing/.."],
                systemTemporaryRoots: [fixture.systemTemporary],
                productionDirectory: fixture.production
            )
        }
    }

    @Test func previewBundleIsSyntheticWithoutArgumentsAndRejectsLiveModes() throws {
        #expect(try GuardCommandLine.parse([], bundledPreviewKind: "onboarding") == .preview(.onboarding))
        #expect(
            try GuardCommandLine.parse(["--preview", "healthy"], bundledPreviewKind: "onboarding")
                == .preview(.healthy)
        )
        #expect(throws: GuardCommandLineError.liveModeInPreviewBundle) {
            try GuardCommandLine.parse(["--doctor"], bundledPreviewKind: "onboarding")
        }
    }

    @Test func malformedPreviewBundleMarkerCannotResolveToProduction() {
        for marker in ["", "typo", "1"] {
            #expect(throws: GuardCommandLineError.invalidPreviewKind(marker)) {
                try GuardCommandLine.parse([], bundledPreviewKind: marker)
            }
        }
    }

    @Test func diagnosticBundleStaysInItsIsolatedDirectoryAndRejectsEveryArgument() throws {
        let fixture = try DiagnosticDirectories()
        defer { fixture.remove() }
        let path = fixture.diagnostic.path
        #expect(try fixture.parse(path) == .diagnosticUI(supportDirectory: fixture.diagnostic))
        for arguments in [["--doctor"], ["--self-test"], ["--preview", "healthy"], ["--unknown"], ["junk"]] {
            #expect(throws: GuardCommandLineError.argumentsInDiagnosticBundle) {
                try fixture.parse(path, arguments: arguments)
            }
        }
        #expect(throws: GuardCommandLineError.conflictingBundleModes) {
            try GuardCommandLine.parse([], bundledPreviewKind: "healthy", bundledDiagnosticDirectory: path)
        }
    }

    @Test func unsafeDiagnosticDirectoriesFailClosed() {
        for path in ["", "relative/path", "/", "/tmp", "/tmp/../Library", "/tmp-other/test",
                     "/tmp/nonexistent-\(UUID().uuidString)", FileManager.default.temporaryDirectory.path,
                     FileManager.default.homeDirectoryForCurrentUser.path,
                     ProfileConfiguration.defaultApplicationSupportDirectory.path] {
            #expect(throws: GuardCommandLineError.invalidDiagnosticDirectory) {
                try GuardCommandLine.parse([], bundledDiagnosticDirectory: path)
            }
        }
    }

    @Test func diagnosticDirectoryRejectsSymlinkEscape() throws {
        let fixture = try DiagnosticDirectories()
        defer { fixture.remove() }
        let outside = try fixture.createDirectory("outside")
        _ = try fixture.createDirectory("outside/diagnostic")
        let link = fixture.temporary.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        for path in [link.path, link.appendingPathComponent("diagnostic").path,
                     link.appendingPathComponent("missing").path] {
            #expect(throws: GuardCommandLineError.invalidDiagnosticDirectory) {
                try fixture.parse(path)
            }
        }
    }

    @Test func symlinkFollowedByParentTraversalCannotChangeTheSelectedDirectory() throws {
        let fixture = try DiagnosticDirectories()
        defer { fixture.remove() }
        _ = try fixture.createDirectory("outside")
        let branch = try fixture.createDirectory("outside/branch")
        _ = try fixture.createDirectory("outside/diagnostic")
        let link = fixture.temporary.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: branch)
        #expect(throws: GuardCommandLineError.invalidDiagnosticDirectory) {
            try fixture.parse(link.path + "/../diagnostic")
        }
        #expect(throws: GuardCommandLineError.invalidDiagnosticDirectory) {
            try fixture.parse(fixture.diagnostic.path, environment: ["TMPDIR": link.path + "/.."])
        }
    }

    @Test func absentOrInvalidProcessTemporaryDirectoryDoesNotExpandAcceptedRoots() throws {
        let fixture = try DiagnosticDirectories()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        for environment in [[:], ["TMPDIR": ""], ["TMPDIR": "relative/path"],
                            ["TMPDIR": fixture.root.appendingPathComponent("missing").path],
                            ["TMPDIR": file.path], ["TMPDIR": "/"]] {
            #expect(throws: GuardCommandLineError.invalidDiagnosticDirectory) {
                try fixture.parse(fixture.diagnostic.path, environment: environment)
            }
        }
    }

    @Test(arguments: [0o755, 0o770, 0o707, 0o500])
    func insecureProcessTemporaryDirectoryDoesNotExpandAcceptedRoots(permissions: Int) throws {
        let fixture = try DiagnosticDirectories()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.temporary.path)
            fixture.remove()
        }
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: fixture.temporary.path)
        #expect(throws: GuardCommandLineError.invalidDiagnosticDirectory) {
            try fixture.parse(fixture.diagnostic.path)
        }
    }

    @Test(arguments: [0o755, 0o770, 0o707, 0o500])
    func insecureDiagnosticDirectoryFailsClosed(permissions: Int) throws {
        let fixture = try DiagnosticDirectories()
        defer { fixture.remove() }
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: fixture.diagnostic.path)
        #expect(throws: GuardCommandLineError.invalidDiagnosticDirectory) {
            try fixture.parse(fixture.diagnostic.path)
        }
    }

    @Test func diagnosticRequiresExistingStrictDescendantNotSiblingOrFile() throws {
        let fixture = try DiagnosticDirectories()
        defer { fixture.remove() }
        let sibling = try fixture.createDirectory("private-temp-other")
        let file = fixture.temporary.appendingPathComponent("file")
        try Data().write(to: file)
        for path in ["", "relative/path", fixture.temporary.path,
                     fixture.temporary.appendingPathComponent("missing").path,
                     fixture.temporary.path + "/missing/../diagnostic", sibling.path,
                     fixture.temporary.path + "/../private-temp-other", file.path] {
            #expect(throws: GuardCommandLineError.invalidDiagnosticDirectory) {
                try fixture.parse(path)
            }
        }
    }

    @Test func temporaryRootCannotBeSelectedThroughAnOverlappingAcceptedRoot() throws {
        let fixture = try DiagnosticDirectories()
        defer { fixture.remove() }
        #expect(throws: GuardCommandLineError.invalidDiagnosticDirectory) {
            try GuardCommandLine.parse(
                [],
                bundledDiagnosticDirectory: fixture.temporary.path,
                environment: ["TMPDIR": fixture.temporary.path],
                systemTemporaryRoots: [fixture.root],
                productionDirectory: fixture.production
            )
        }
    }

    @Test func canonicalTemporaryAliasesStayContainedAndCannotSelectTheRoot() throws {
        let fixture = try DiagnosticDirectories()
        defer { fixture.remove() }
        let rootAlias = fixture.root.appendingPathComponent("temporary-alias")
        let childAlias = fixture.temporary.appendingPathComponent("diagnostic-alias")
        try FileManager.default.createSymbolicLink(at: rootAlias, withDestinationURL: fixture.temporary)
        try FileManager.default.createSymbolicLink(at: childAlias, withDestinationURL: fixture.diagnostic)
        #expect(
            try fixture.parse(childAlias.path, environment: ["TMPDIR": rootAlias.path])
                == .diagnosticUI(supportDirectory: fixture.diagnostic)
        )
        #expect(throws: GuardCommandLineError.invalidDiagnosticDirectory) {
            try fixture.parse(rootAlias.path, environment: ["TMPDIR": rootAlias.path])
        }
    }

    @Test func productionDirectoryItsDescendantsAndAncestorsRemainForbidden() throws {
        let fixture = try DiagnosticDirectories()
        defer { fixture.remove() }
        let descendant = fixture.production.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: descendant, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        let alias = fixture.temporary.appendingPathComponent("production-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.production)
        for path in [fixture.production.path, descendant.path,
                     fixture.production.deletingLastPathComponent().path, alias.path] {
            #expect(throws: GuardCommandLineError.invalidDiagnosticDirectory) {
                try fixture.parse(path, environment: ["TMPDIR": fixture.root.path])
            }
        }
    }

    @Test func missingProductionDirectoryStillExcludesItsSymlinkedAncestors() throws {
        let fixture = try DiagnosticDirectories()
        defer { fixture.remove() }
        let directory = try fixture.createDirectory("private-temp/production-parent")
        let alias = fixture.root.appendingPathComponent("production-parent-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        for missingPath in ["not-created-yet", "missing/intermediate/not-created-yet"] {
            #expect(throws: GuardCommandLineError.invalidDiagnosticDirectory) {
                try GuardCommandLine.parse(
                    [],
                    bundledDiagnosticDirectory: directory.path,
                    environment: ["TMPDIR": fixture.temporary.path],
                    systemTemporaryRoots: [fixture.systemTemporary],
                    productionDirectory: alias.appendingPathComponent(missingPath, isDirectory: true)
                )
            }
            #expect(
                try GuardCommandLine.parse(
                    [],
                    bundledDiagnosticDirectory: fixture.diagnostic.path,
                    environment: ["TMPDIR": fixture.temporary.path],
                    systemTemporaryRoots: [fixture.systemTemporary],
                    productionDirectory: alias.appendingPathComponent(missingPath, isDirectory: true)
                ) == .diagnosticUI(supportDirectory: fixture.diagnostic)
            )
        }
    }

    @Test func systemTemporaryRouteStillWorksWithAbsentOrUnsafeProcessTemporaryDirectory() throws {
        let fixture = try DiagnosticDirectories()
        defer { fixture.remove() }
        let directory = try fixture.createDirectory("system-temp/diagnostic")
        for environment in [[:], ["TMPDIR": "relative"], ["TMPDIR": "/"],
                            ["TMPDIR": fixture.root.appendingPathComponent("missing").path]] {
            #expect(
                try fixture.parse(directory.path, environment: environment)
                    == .diagnosticUI(supportDirectory: directory)
            )
            #expect(throws: GuardCommandLineError.invalidDiagnosticDirectory) {
                try fixture.parse(fixture.systemTemporary.path, environment: environment)
            }
        }
    }

    @Test func processTemporaryDirectoryCannotEnableDiagnosticsOrChangePreviewMode() throws {
        let fixture = try DiagnosticDirectories()
        defer { fixture.remove() }
        for environment in [["TMPDIR": fixture.temporary.path], ["TMPDIR": "relative"], ["TMPDIR": "/"]] {
            #expect(try GuardCommandLine.parse([], environment: environment) == .production)
            #expect(
                try GuardCommandLine.parse([], bundledPreviewKind: "healthy", environment: environment)
                    == .preview(.healthy)
            )
            #expect(throws: GuardCommandLineError.liveModeInPreviewBundle) {
                try GuardCommandLine.parse(["--doctor"], bundledPreviewKind: "healthy", environment: environment)
            }
        }
    }

    @Test func validModesParseExactly() throws {
        #expect(try GuardCommandLine.parse(["--preview", "onboarding"]) == .preview(.onboarding))
        #expect(try GuardCommandLine.parse(["--preview", "near"]) == .preview(.near))
        #expect(
            try GuardCommandLine.parse(["--render-preview", "healthy", "/tmp/healthy.png"])
                == .renderPreview(kind: .healthy, destinationPath: "/tmp/healthy.png")
        )
        #expect(
            try GuardCommandLine.parse(["--render-all-previews", "/tmp/previews"])
                == .renderAllPreviews(directoryPath: "/tmp/previews")
        )
        #expect(try GuardCommandLine.parse(["--self-test"]) == .selfTest)
        #expect(try GuardCommandLine.parse(["--doctor"]) == .doctor)
    }

    @Test func previewTypoCannotResolveToProduction() {
        assertParseError(["--preview", "typo"], equals: .invalidPreviewKind("typo"))
    }

    @Test func missingAndInvalidPreviewValuesAreRejected() {
        assertParseError(["--preview"], equals: .missingValue(option: "--preview"))
        assertParseError(["--preview", ""], equals: .invalidPreviewKind(""))
        assertParseError(["--render-preview", "typo", "/tmp/out.png"], equals: .invalidPreviewKind("typo"))
    }

    @Test func malformedRenderArgumentsAreRejected() {
        assertParseError(["--render-preview"], equals: .missingValue(option: "--render-preview"))
        assertParseError(["--render-preview", "healthy"], equals: .missingValue(option: "--render-preview"))
        assertParseFails(["--render-preview", "healthy", "/tmp/out.png", "junk"])
        assertParseError(["--render-all-previews"], equals: .missingValue(option: "--render-all-previews"))
        assertParseFails(["--render-all-previews", "/tmp/previews", "junk"])
    }

    @Test func unknownFlagsAndPositionalJunkAreRejected() {
        assertParseError(["--unknown"], equals: .unknownOption("--unknown"))
        assertParseError(["junk"], equals: .unexpectedArgument("junk"))
        assertParseError(["junk", "--doctor"], equals: .unexpectedArgument("junk"))
        assertParseFails(["--self-test", "junk"])
        assertParseFails(["--preview", "healthy", "junk"])
    }

    @Test func conflictingModesAreRejected() {
        assertParseError(
            ["--preview", "healthy", "--doctor"],
            equals: .conflictingModes(["--preview", "--doctor"])
        )
        assertParseError(
            ["--self-test", "--self-test"],
            equals: .conflictingModes(["--self-test", "--self-test"])
        )
        assertParseFails(["--render-all-previews", "/tmp/previews", "--preview", "healthy"])
    }

    private func assertParseError(
        _ arguments: [String],
        equals expected: GuardCommandLineError,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            let command = try GuardCommandLine.parse(arguments)
            Issue.record("Expected parsing to fail, got \(command)", sourceLocation: sourceLocation)
        } catch let error as GuardCommandLineError {
            #expect(error == expected, sourceLocation: sourceLocation)
        } catch {
            Issue.record("Unexpected error type: \(error)", sourceLocation: sourceLocation)
        }
    }

    private func assertParseFails(
        _ arguments: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            let command = try GuardCommandLine.parse(arguments)
            Issue.record("Expected parsing to fail, got \(command)", sourceLocation: sourceLocation)
        } catch is GuardCommandLineError {
            // Expected.
        } catch {
            Issue.record("Unexpected error type: \(error)", sourceLocation: sourceLocation)
        }
    }
}

private struct DiagnosticDirectories {
    let root: URL
    let temporary: URL
    let systemTemporary: URL
    let production: URL
    let diagnostic: URL

    init() throws {
        let base = try #require(ProcessInfo.processInfo.environment["TMPDIR"])
        try #require(base.hasPrefix("/"))
        root = URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("guard-command-line-tests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        temporary = root.appendingPathComponent("private-temp", isDirectory: true)
        systemTemporary = root.appendingPathComponent("system-temp", isDirectory: true)
        let productionParent = root.appendingPathComponent("production-parent", isDirectory: true)
        production = productionParent.appendingPathComponent("production", isDirectory: true)
        diagnostic = temporary.appendingPathComponent("diagnostic", isDirectory: true)
        for directory in [root, temporary, systemTemporary, productionParent, production, diagnostic] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    func createDirectory(_ path: String) throws -> URL {
        let directory = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    func parse(_ path: String, arguments: [String] = [], environment: [String: String]? = nil) throws -> GuardLaunchCommand {
        try GuardCommandLine.parse(
            arguments,
            bundledDiagnosticDirectory: path,
            environment: environment ?? ["TMPDIR": temporary.path],
            systemTemporaryRoots: [systemTemporary],
            productionDirectory: production
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
