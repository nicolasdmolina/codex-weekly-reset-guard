import Foundation
import Darwin
import Testing
@testable import CodexWeeklyResetGuardCore

@Test func preventsTwoGuardsFromOwningTheSameLock() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("guard.lock")

    let first = try SingleInstanceLock(url: url)
    #expect(throws: SingleInstanceError.self) {
        _ = try SingleInstanceLock(url: url)
    }
    _ = first

    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
}

@Test func lockRefusesSymlinkAndKeepsTargetUntouched() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("target")
    let lock = directory.appendingPathComponent("guard.lock")
    try Data("do-not-truncate".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)

    #expect(throws: (any Error).self) {
        _ = try SingleInstanceLock(url: lock)
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == "do-not-truncate")
}

@Test func lockParentDirectoryIsPrivate() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let lock = try SingleInstanceLock(url: directory.appendingPathComponent("guard.lock"))
    _ = lock

    let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
        as? NSNumber
    #expect(permissions?.intValue == 0o700)
}
