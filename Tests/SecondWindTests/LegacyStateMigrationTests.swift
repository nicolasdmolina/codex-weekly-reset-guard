import Foundation
import Testing
@testable import SecondWindCore

private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("migration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func movesLegacyStateWithPendingAttemptIntact() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("CodexWeeklyResetGuard", isDirectory: true)
    let current = root.appendingPathComponent("SecondWind", isDirectory: true)
    let profile = legacy.appendingPathComponent("profiles/abc", isDirectory: true)
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    let state = Data(#"{"idempotencyKey":"weekly-reset-keep-me"}"#.utf8)
    try state.write(to: legacy.appendingPathComponent("state.json"))
    try Data("auth".utf8).write(to: profile.appendingPathComponent("config.toml"))

    let outcome = try LegacyStateMigration.migrateIfNeeded(
        legacyDirectory: legacy,
        currentDirectory: current
    )

    #expect(outcome == .migrated)
    #expect(try Data(contentsOf: current.appendingPathComponent("state.json")) == state)
    #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("profiles/abc/config.toml").path))
    var isDirectory: ObjCBool = true
    #expect(FileManager.default.fileExists(atPath: legacy.path, isDirectory: &isDirectory))
    #expect(!isDirectory.boolValue)
    // A second launch finds the new directory and leaves everything alone.
    #expect(try LegacyStateMigration.migrateIfNeeded(legacyDirectory: legacy, currentDirectory: current) == .notNeeded)
}

@Test func neverMergesIntoAnExistingDirectory() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("legacy", isDirectory: true)
    let current = root.appendingPathComponent("current", isDirectory: true)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: legacy.appendingPathComponent("state.json"))

    #expect(try LegacyStateMigration.migrateIfNeeded(legacyDirectory: legacy, currentDirectory: current) == .notNeeded)
    #expect(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("state.json").path))
    #expect(!FileManager.default.fileExists(atPath: current.appendingPathComponent("state.json").path))
}

@Test func waitsWhileTheLegacyAppHoldsItsLock() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = root.appendingPathComponent("legacy", isDirectory: true)
    let current = root.appendingPathComponent("current", isDirectory: true)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    let running = try SingleInstanceLock(url: legacy.appendingPathComponent("guard.lock"))

    let outcome = try LegacyStateMigration.migrateIfNeeded(legacyDirectory: legacy, currentDirectory: current)

    #expect(outcome == .legacyAppRunning)
    #expect(!FileManager.default.fileExists(atPath: current.path))
    withExtendedLifetime(running) {}
}

@Test func ignoresSymlinkedLegacyDirectory() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("elsewhere", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let legacy = root.appendingPathComponent("legacy", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: target)
    let current = root.appendingPathComponent("current", isDirectory: true)

    #expect(try LegacyStateMigration.migrateIfNeeded(legacyDirectory: legacy, currentDirectory: current) == .notNeeded)
    #expect(!FileManager.default.fileExists(atPath: current.path))
}
