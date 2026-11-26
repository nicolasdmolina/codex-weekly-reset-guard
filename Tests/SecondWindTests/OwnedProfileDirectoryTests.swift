import Foundation
import Testing
@testable import SecondWindCore

private struct DirectoryFixture {
    let base: URL
    let root: URL
    let outside: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("owned-directory-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("profiles", isDirectory: true)
        outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("sentinel"))
    }

    func folder(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    func makeProfile(_ id: UUID) throws -> URL {
        let folder = folder(id)
        let nested = folder.appendingPathComponent("sessions/2026/11", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: folder.appendingPathComponent("auth.json"))
        try Data("x".utf8).write(to: nested.appendingPathComponent("log.jsonl"))
        return folder
    }

    func exists(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }

    var sentinelIntact: Bool {
        (try? String(contentsOf: outside.appendingPathComponent("sentinel"), encoding: .utf8)) == "keep"
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}

@Test func discardDeletesTheWholeFolderAndLeavesSiblings() throws {
    let fixture = try DirectoryFixture()
    defer { fixture.remove() }
    let target = UUID()
    let sibling = UUID()
    _ = try fixture.makeProfile(target)
    let siblingFolder = try fixture.makeProfile(sibling)

    try OwnedProfileDirectory.discard(profileID: target, root: fixture.root)

    #expect(!fixture.exists(fixture.folder(target)))
    #expect(!fixture.exists(fixture.root.appendingPathComponent(".discard-\(target.uuidString.lowercased())")))
    #expect(fixture.exists(siblingFolder.appendingPathComponent("auth.json")))
    #expect(fixture.exists(siblingFolder.appendingPathComponent("sessions/2026/11/log.jsonl")))
    // Already gone is success.
    try OwnedProfileDirectory.discard(profileID: target, root: fixture.root)
}

@Test func discardUnlinksLinksInsideTheFolderWithoutFollowingThem() throws {
    let fixture = try DirectoryFixture()
    defer { fixture.remove() }
    let target = UUID()
    let folder = try fixture.makeProfile(target)
    try FileManager.default.createSymbolicLink(
        at: folder.appendingPathComponent("escape-dir"),
        withDestinationURL: fixture.outside
    )
    try FileManager.default.createSymbolicLink(
        at: folder.appendingPathComponent("sessions/escape-file"),
        withDestinationURL: fixture.outside.appendingPathComponent("sentinel")
    )

    try OwnedProfileDirectory.discard(profileID: target, root: fixture.root)

    #expect(!fixture.exists(folder))
    #expect(fixture.sentinelIntact)
}

@Test func aFolderReplacedByALinkIsUnlinkedNotFollowed() throws {
    let fixture = try DirectoryFixture()
    defer { fixture.remove() }
    let target = UUID()
    try FileManager.default.createSymbolicLink(at: fixture.folder(target), withDestinationURL: fixture.outside)

    try OwnedProfileDirectory.discard(profileID: target, root: fixture.root)

    #expect(!fixture.exists(fixture.folder(target)))
    #expect(fixture.sentinelIntact)
}

@Test func aLinkedRootIsRefused() throws {
    let fixture = try DirectoryFixture()
    defer { fixture.remove() }
    let target = UUID()
    let realRoot = fixture.base.appendingPathComponent("real", isDirectory: true)
    try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
    let victim = realRoot.appendingPathComponent(target.uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
    let linkedRoot = fixture.base.appendingPathComponent("linked", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)

    #expect(throws: OwnedProfileDirectoryError.rootNotDirectory(linkedRoot)) {
        try OwnedProfileDirectory.discard(profileID: target, root: linkedRoot)
    }
    #expect(fixture.exists(victim))
}

@Test func aMissingRootOrFolderIsNothingToDo() throws {
    let fixture = try DirectoryFixture()
    defer { fixture.remove() }
    try OwnedProfileDirectory.discard(
        profileID: UUID(),
        root: fixture.base.appendingPathComponent("never-created", isDirectory: true)
    )
    try OwnedProfileDirectory.discard(profileID: UUID(), root: fixture.root)
    #expect(try OwnedProfileDirectory.isolate(profileID: UUID(), root: fixture.root) == false)
}

@Test func isolateCanBeUndoneAndReplacesAnOldLeftover() throws {
    let fixture = try DirectoryFixture()
    defer { fixture.remove() }
    let target = UUID()
    let folder = try fixture.makeProfile(target)
    let isolated = fixture.root.appendingPathComponent(".discard-\(target.uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
    try Data("stale".utf8).write(to: isolated.appendingPathComponent("old"))

    #expect(try OwnedProfileDirectory.isolate(profileID: target, root: fixture.root))
    #expect(!fixture.exists(folder))
    #expect(fixture.exists(isolated.appendingPathComponent("auth.json")))
    #expect(!fixture.exists(isolated.appendingPathComponent("old")))

    #expect(try OwnedProfileDirectory.restoreIsolated(profileID: target, root: fixture.root))
    #expect(fixture.exists(folder.appendingPathComponent("auth.json")))
    #expect(!fixture.exists(isolated))
}

private func contents(of folder: URL) -> [String: String] {
    let paths = FileManager.default.enumerator(atPath: folder.path)?.allObjects as? [String] ?? []
    var result: [String: String] = [:]
    for path in paths {
        let url = folder.appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            result[path] = (try? String(contentsOf: url, encoding: .utf8)) ?? "<unreadable>"
        }
    }
    return result
}

@Test func recoveryRestoresUncommittedRemovalsAndDeletesCommittedOnes() throws {
    let fixture = try DirectoryFixture()
    defer { fixture.remove() }
    let enrolled = UUID()
    let removed = UUID()
    let bystander = try fixture.makeProfile(UUID())
    let enrolledFiles = contents(of: try fixture.makeProfile(enrolled))
    _ = try fixture.makeProfile(removed)
    try OwnedProfileDirectory.isolate(profileID: enrolled, root: fixture.root)
    try OwnedProfileDirectory.isolate(profileID: removed, root: fixture.root)
    let lookalike = fixture.root.appendingPathComponent(".discard-not-a-profile", isDirectory: true)
    try FileManager.default.createDirectory(at: lookalike, withIntermediateDirectories: true)
    let uppercase = fixture.root.appendingPathComponent(".discard-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: uppercase, withIntermediateDirectories: true)
    let bystanderFiles = contents(of: bystander)

    let recovery = try OwnedProfileDirectory.recoverInterruptedDiscards(
        root: fixture.root,
        enrolledIDs: [enrolled, UUID()]
    )

    #expect(recovery == OwnedProfileDirectory.Recovery(restored: [enrolled], discarded: [removed]))
    #expect(contents(of: fixture.folder(enrolled)) == enrolledFiles)
    #expect(!fixture.exists(fixture.root.appendingPathComponent(".discard-\(enrolled.uuidString.lowercased())")))
    #expect(!fixture.exists(fixture.folder(removed)))
    #expect(!fixture.exists(fixture.root.appendingPathComponent(".discard-\(removed.uuidString.lowercased())")))
    #expect(contents(of: bystander) == bystanderFiles)
    #expect(fixture.exists(lookalike))
    #expect(fixture.exists(uppercase))

    // A second launch finds nothing left to do and changes nothing.
    let again = try OwnedProfileDirectory.recoverInterruptedDiscards(
        root: fixture.root,
        enrolledIDs: [enrolled, UUID()]
    )
    #expect(again.isEmpty)
    #expect(contents(of: fixture.folder(enrolled)) == enrolledFiles)
}

@Test func recoveryNeverOverwritesAnOccupiedLivePath() throws {
    let fixture = try DirectoryFixture()
    defer { fixture.remove() }
    let enrolled = UUID()
    let stagedFiles = contents(of: try fixture.makeProfile(enrolled))
    try OwnedProfileDirectory.isolate(profileID: enrolled, root: fixture.root)
    // A fresh sign-in recreated the live folder before recovery ran.
    try FileManager.default.createDirectory(at: fixture.folder(enrolled), withIntermediateDirectories: true)
    try Data("newer".utf8).write(to: fixture.folder(enrolled).appendingPathComponent("auth.json"))
    let staged = fixture.root.appendingPathComponent(".discard-\(enrolled.uuidString.lowercased())", isDirectory: true)

    for _ in 0..<2 {
        let recovery = try OwnedProfileDirectory.recoverInterruptedDiscards(root: fixture.root, enrolledIDs: [enrolled])
        #expect(recovery == OwnedProfileDirectory.Recovery(retained: [enrolled]))
        #expect(contents(of: fixture.folder(enrolled)) == ["auth.json": "newer"])
        #expect(contents(of: staged) == stagedFiles)
    }
    #expect(try OwnedProfileDirectory.restoreIsolated(profileID: enrolled, root: fixture.root) == false)
    #expect(contents(of: fixture.folder(enrolled)) == ["auth.json": "newer"])

    // An empty live folder is still occupied; nothing replaces it either.
    let other = UUID()
    _ = try fixture.makeProfile(other)
    try OwnedProfileDirectory.isolate(profileID: other, root: fixture.root)
    try FileManager.default.createDirectory(at: fixture.folder(other), withIntermediateDirectories: true)
    let recovery = try OwnedProfileDirectory.recoverInterruptedDiscards(root: fixture.root, enrolledIDs: [enrolled, other])
    #expect(recovery.retained == [enrolled, other].sorted { $0.uuidString < $1.uuidString })
    #expect(contents(of: fixture.folder(other)).isEmpty)
}

@Test func recoveryUnlinksAStagedLinkEvenForAnEnrolledAccount() throws {
    let fixture = try DirectoryFixture()
    defer { fixture.remove() }
    let enrolled = UUID()
    let staged = fixture.root.appendingPathComponent(".discard-\(enrolled.uuidString.lowercased())")
    try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: fixture.outside)

    let recovery = try OwnedProfileDirectory.recoverInterruptedDiscards(root: fixture.root, enrolledIDs: [enrolled])

    #expect(recovery == OwnedProfileDirectory.Recovery(discarded: [enrolled]))
    #expect(!fixture.exists(staged))
    #expect(!fixture.exists(fixture.folder(enrolled)))
    #expect(fixture.sentinelIntact)
}

@Test func recoveryWithoutARootDoesNothing() throws {
    let fixture = try DirectoryFixture()
    defer { fixture.remove() }
    let recovery = try OwnedProfileDirectory.recoverInterruptedDiscards(
        root: fixture.base.appendingPathComponent("missing", isDirectory: true),
        enrolledIDs: []
    )
    #expect(recovery.isEmpty)
}

@Test func onlyARealOwnedFolderCountsAsTheProfileFolder() throws {
    let fixture = try DirectoryFixture()
    defer { fixture.remove() }
    let real = UUID()
    let linked = UUID()
    _ = try fixture.makeProfile(real)
    try FileManager.default.createSymbolicLink(at: fixture.folder(linked), withDestinationURL: fixture.outside)

    #expect(OwnedProfileDirectory.isOwnedRealDirectory(profileID: real, root: fixture.root))
    #expect(!OwnedProfileDirectory.isOwnedRealDirectory(profileID: linked, root: fixture.root))
    #expect(!OwnedProfileDirectory.isOwnedRealDirectory(profileID: UUID(), root: fixture.root))
    #expect(!OwnedProfileDirectory.isOwnedRealDirectory(
        profileID: real,
        root: fixture.base.appendingPathComponent("missing", isDirectory: true)
    ))
}
