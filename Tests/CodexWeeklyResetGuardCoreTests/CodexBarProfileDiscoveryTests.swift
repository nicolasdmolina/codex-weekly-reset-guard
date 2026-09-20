import Foundation
import Testing
@testable import CodexWeeklyResetGuardCore

@Test func discoversDistinctCodexBarIdentitiesWithoutAuthMaterial() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = directory.appendingPathComponent("managed-codex-accounts.json")
    let json = #"{"version":3,"accounts":[{"id":"one","email":"first.user@example.com","providerAccountID":"account-1"},{"id":"duplicate","email":"FIRST.USER@example.com","providerAccountID":"account-1-copy"},{"id":"two","email":"second@example.com","providerAccountID":"account-2"}]}"#
    try Data(json.utf8).write(to: registry)

    let profiles = try CodexBarProfileDiscovery.discover(from: registry)

    #expect(profiles.count == 2)
    #expect(profiles.map(\.id) == ["account-1", "account-2"])
    #expect(profiles.map(\.displayName) == ["First User", "Second"])
}
