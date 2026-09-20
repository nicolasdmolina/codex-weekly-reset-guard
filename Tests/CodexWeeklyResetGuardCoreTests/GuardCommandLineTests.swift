import Testing
import Foundation
import CodexWeeklyResetGuardCore
@testable import CodexWeeklyResetGuard

@Suite struct GuardCommandLineTests {
    @Test func noArgumentsSelectProduction() throws {
        #expect(try GuardCommandLine.parse([]) == .production)
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
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("weekly-reset-guard-diagnostic-\(UUID().uuidString)", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let expected = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        #expect(try GuardCommandLine.parse([], bundledDiagnosticDirectory: path) == .diagnosticUI(supportDirectory: expected))
        for arguments in [["--doctor"], ["--self-test"], ["--preview", "healthy"], ["--unknown"], ["junk"]] {
            #expect(throws: GuardCommandLineError.argumentsInDiagnosticBundle) {
                try GuardCommandLine.parse(arguments, bundledDiagnosticDirectory: path)
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/Library"))
        for path in [link.path, link.appendingPathComponent("diagnostic").path] {
            #expect(throws: GuardCommandLineError.invalidDiagnosticDirectory) {
                try GuardCommandLine.parse([], bundledDiagnosticDirectory: path)
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
