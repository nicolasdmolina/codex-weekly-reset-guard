import Darwin
import Foundation
import Testing
@testable import CodexWeeklyResetGuardCore

@Test func secureStateStoreRoundTripsAtomicallyAtPrivatePermissions() async throws {
    struct State: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let value: String
    }

    let directory = try temporaryDirectory()
    let fileURL = directory.appendingPathComponent("state.json")
    let store = SecureStateStore<State>(fileURL: fileURL)

    try await store.save(State(schemaVersion: 1, value: "first"))
    try await store.save(State(schemaVersion: 1, value: "second"))
    let loaded = try await store.load()

    #expect(loaded == State(schemaVersion: 1, value: "second"))
    #expect(try permissions(of: fileURL) == 0o600)
    #expect(try permissions(of: directory) == 0o700)
    let siblings = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    #expect(siblings.map(\.lastPathComponent) == ["state.json"])
}

@Test func secureStateStoreRefusesWorldReadableState() async throws {
    struct State: Codable, Sendable { let value: String }

    let directory = try temporaryDirectory()
    let fileURL = directory.appendingPathComponent("state.json")
    let store = SecureStateStore<State>(fileURL: fileURL)
    try await store.save(State(value: "private"))
    #expect(chmod(fileURL.path, mode_t(0o644)) == 0)

    do {
        _ = try await store.load()
        Issue.record("Expected insecure permissions to be rejected")
    } catch let error as SecureStateStoreError {
        #expect(error == .insecurePermissions(fileURL, mode: 0o644))
    }
}

@Test func secureStateStoreRefusesSymbolicLink() async throws {
    struct State: Codable, Sendable { let value: String }

    let directory = try temporaryDirectory()
    let targetURL = directory.appendingPathComponent("target.json")
    let linkURL = directory.appendingPathComponent("state.json")
    try Data(#"{"value":"elsewhere"}"#.utf8).write(to: targetURL)
    #expect(chmod(targetURL.path, mode_t(0o600)) == 0)
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

    let store = SecureStateStore<State>(fileURL: linkURL)
    do {
        _ = try await store.load()
        Issue.record("Expected symbolic-link state to be rejected")
    } catch let error as SecureStateStoreError {
        #expect(error == .symbolicLink(linkURL))
    }
}

@Test func privateReadDescriptorsCannotLeakIntoAppServerChildren() throws {
    let directory = try temporaryDirectory()
    let fileURL = directory.appendingPathComponent("state.json")
    try Data("{}".utf8).write(to: fileURL)
    #expect(chmod(fileURL.path, mode_t(0o600)) == 0)

    let descriptor = PrivateFileIO.openReadDescriptor(for: fileURL)
    #expect(descriptor >= 0)
    defer { if descriptor >= 0 { close(descriptor) } }
    #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC == FD_CLOEXEC)
}

@Test func secureStateStoreSaveFailsWhenFullFileSyncFails() async throws {
    struct State: Codable, Equatable, Sendable { let value: String }

    let directory = try temporaryDirectory()
    let fileURL = directory.appendingPathComponent("state.json")
    let store = SecureStateStore<State>(
        fileURL: fileURL,
        testingFaultInjector: PrivateFileIOFaultInjector(operation: .syncFile)
    )
    var callerObservedSuccess = false

    do {
        try await store.save(State(value: "must be durable"))
        callerObservedSuccess = true
        Issue.record("Expected the injected full-file-sync failure")
    } catch let error as SecureStateStoreError {
        #expect(error == .ioFailure(operation: "full-fsync-file", code: EIO))
    }

    #expect(!callerObservedSuccess)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
}

@Test func secureStateStoreSaveFailsWhenDirectoryCannotBeOpened() async throws {
    struct State: Codable, Equatable, Sendable { let value: String }

    let directory = try temporaryDirectory()
    let fileURL = directory.appendingPathComponent("state.json")
    let store = SecureStateStore<State>(
        fileURL: fileURL,
        testingFaultInjector: PrivateFileIOFaultInjector(operation: .openDirectory)
    )
    var callerObservedSuccess = false

    do {
        try await store.save(State(value: "renamed but not directory-synced"))
        callerObservedSuccess = true
        Issue.record("Expected the injected directory-open failure")
    } catch let error as SecureStateStoreError {
        #expect(error == .ioFailure(operation: "open-directory", code: EIO))
    }

    #expect(!callerObservedSuccess)
}

@Test func secureStateStoreUpdateDoesNotReturnWhenDirectorySyncFails() async throws {
    struct State: Codable, Equatable, Sendable { var value: String }

    let directory = try temporaryDirectory()
    let fileURL = directory.appendingPathComponent("state.json")
    let healthyStore = SecureStateStore<State>(fileURL: fileURL)
    try await healthyStore.save(State(value: "before"))

    let failingStore = SecureStateStore<State>(
        fileURL: fileURL,
        testingFaultInjector: PrivateFileIOFaultInjector(operation: .syncDirectory)
    )
    var callerObservedResult: String?

    do {
        callerObservedResult = try await failingStore.update(defaultValue: State(value: "default")) {
            $0.value = "after"
            return $0.value
        }
        Issue.record("Expected the injected directory-sync failure")
    } catch let error as SecureStateStoreError {
        #expect(error == .ioFailure(operation: "fsync-directory", code: EIO))
    }

    #expect(callerObservedResult == nil)
}

@Test func eventLedgerRedactsEmailsTokensAndCreditIdentifiers() async throws {
    let directory = try temporaryDirectory()
    let fileURL = directory.appendingPathComponent("events.json")
    let log = RedactedEventLog(fileURL: fileURL)

    try await log.append(
        profileID: UUID(),
        kind: .redemptionFailed,
        message: "user@example.com Bearer abc.def.ghi sk-secretvalue RateLimitResetCredit_123",
        fields: [
            "idempotencyKey": UUID().uuidString,
            "creditId": "RateLimitResetCredit_123",
            "safeStatus": "failed for other@example.com"
        ],
        at: Date(timeIntervalSince1970: 100)
    )

    let raw = try String(decoding: Data(contentsOf: fileURL), as: UTF8.self)
    #expect(!raw.contains("user@example.com"))
    #expect(!raw.contains("other@example.com"))
    #expect(!raw.contains("sk-secretvalue"))
    #expect(!raw.contains("RateLimitResetCredit_123"))
    #expect(!raw.contains("idempotencyKey"))
    #expect(!raw.contains("creditId"))
    #expect(raw.contains("<redacted-email>"))
    #expect(try permissions(of: fileURL) == 0o600)
}

@Test func eventLedgerDoesNotLoseConcurrentProfileEvents() async throws {
    let directory = try temporaryDirectory()
    let log = RedactedEventLog(fileURL: directory.appendingPathComponent("events.json"))

    await withTaskGroup(of: Void.self) { group in
        for index in 0..<40 {
            group.addTask {
                _ = try? await log.append(
                    profileID: nil,
                    kind: .checkSucceeded,
                    message: "concurrent check \(index)"
                )
            }
        }
    }

    let entries = try await log.entries()
    #expect(entries.count == 40)
    #expect(Set(entries.compactMap(\.message)).count == 40)
}

@Test func profileConfigurationCreatesOnlyAnIsolatedCodexHome() throws {
    let profilesDirectory = try temporaryDirectory().appendingPathComponent("profiles")
    let profile = ProfileConfiguration(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        displayName: "Primary",
        expectedEmail: "person@example.com"
    )

    let codexHome = try profile.prepareCodexHome(profilesDirectory: profilesDirectory)
    let configURL = codexHome.appendingPathComponent("config.toml")
    let config = try String(contentsOf: configURL, encoding: .utf8)

    #expect(codexHome.lastPathComponent == "00000000-0000-0000-0000-000000000001")
    #expect(config.contains(#"cli_auth_credentials_store = "file""#))
    #expect(config.contains(#"persistence = "none""#))
    #expect(!FileManager.default.fileExists(atPath: codexHome.appendingPathComponent("auth.json").path))
    #expect(try permissions(of: codexHome) == 0o700)
    #expect(try permissions(of: configURL) == 0o600)
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexWeeklyResetGuardTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
