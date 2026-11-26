import Foundation
import Testing
@testable import SecondWind
@testable import SecondWindCore

// Synthetic accounts and scripted Codex/Claude tools only. Nothing here signs anyone out.

private let synthetic = Date(timeIntervalSince1970: 2_000_000_000)

private struct LifecycleFixture: @unchecked Sendable {
    let root: URL
    let stateURL: URL
    let profilesURL: URL
    let first: ProfileConfiguration
    let second: ProfileConfiguration

    init(firstEnabled: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-runtime-\(UUID().uuidString)", isDirectory: true)
        stateURL = root.appendingPathComponent("state.json")
        profilesURL = root.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        first = ProfileConfiguration(displayName: "Work", expectedEmail: "first@example.com", isEnabled: firstEnabled)
        second = ProfileConfiguration(displayName: "Personal", expectedEmail: "second@example.com", isEnabled: true)
        let state = GuardPersistentState(
            profiles: [first, second],
            monitorStates: Dictionary(uniqueKeysWithValues: [first, second].map { profile in
                let key = GuardPersistentState.key(for: profile.id)
                return (key, MonitorState(profileID: key, isEnabled: profile.isEnabled))
            }),
            createdAt: synthetic
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    func persistence() -> MonitorPersistence {
        MonitorPersistence(stateFileURL: stateURL, profilesDirectory: profilesURL)
    }

    func home(_ profile: ProfileConfiguration) -> URL {
        profile.codexHomeURL(profilesDirectory: profilesURL)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor LifecycleSession: GuardAppServerSession {
    let email: String
    private var holdReads = false
    private var heldReads: [CheckedContinuation<Void, Never>] = []
    private(set) var accountReads = 0
    private(set) var consumes = 0
    private(set) var shutdowns = 0

    init(email: String) { self.email = email }

    func start() async throws {}
    func shutdown() async {
        shutdowns += 1
        release()
    }
    func notifications() async -> AsyncStream<AppServerNotification> {
        AsyncStream { $0.finish() }
    }
    func accountRead(refreshToken: Bool) async throws -> RPCAccountReadResponse {
        accountReads += 1
        if holdReads { await withCheckedContinuation { heldReads.append($0) } }
        return RPCAccountReadResponse(
            account: RPCAccountSummary(type: "chatgpt", email: email, planType: "pro"),
            requiresOpenaiAuth: true
        )
    }
    func startChatGPTLogin(useHostedLoginSuccessPage: Bool, appBrand: String) async throws
        -> RPCChatGPTLoginStartResponse
    {
        RPCChatGPTLoginStartResponse(loginID: "synthetic", authURL: URL(string: "https://example.com/login")!)
    }
    func readRateLimits() async throws -> RPCRateLimitsReadResponse {
        let snapshot = RPCRateLimitSnapshot(
            limitID: "codex",
            limitName: nil,
            primary: RPCRateLimitWindow(
                usedPercent: 10,
                windowDurationMinutes: 300,
                resetsAt: Int64(synthetic.addingTimeInterval(3_600).timeIntervalSince1970)
            ),
            secondary: RPCRateLimitWindow(
                usedPercent: 40,
                windowDurationMinutes: 10_080,
                resetsAt: Int64(synthetic.addingTimeInterval(3 * 86_400).timeIntervalSince1970)
            )
        )
        return RPCRateLimitsReadResponse(
            rateLimits: snapshot,
            rateLimitsByLimitID: ["codex": snapshot],
            rateLimitResetCredits: RPCResetCreditsSummary(availableCount: 0, credits: [])
        )
    }
    func consumeReset(idempotencyKey: String, creditID: String?) async throws -> RPCConsumeResetOutcome {
        consumes += 1
        return .nothingToReset
    }

    func hold() { holdReads = true }
    func isHolding() -> Bool { !heldReads.isEmpty }
    func release() {
        holdReads = false
        let waiting = heldReads
        heldReads.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

private func makeController(
    _ fixture: LifecycleFixture,
    sessions: [String: LifecycleSession],
    mode: GuardOperationMode = .production,
    persistence: MonitorPersistence? = nil
) -> GuardRuntimeController {
    GuardRuntimeController(
        configuration: GuardRuntimeConfiguration(
            operationMode: mode,
            codexExecutableURL: URL(fileURLWithPath: "/does/not/run/in-this-test"),
            applicationSupportDirectory: fixture.root,
            profilesDirectory: fixture.profilesURL
        ),
        persistence: persistence ?? fixture.persistence(),
        eventLog: RedactedEventLog(fileURL: fixture.root.appendingPathComponent("events.json")),
        sessionFactory: { profile in
            guard let email = profile.expectedEmail, let session = sessions[email] else {
                throw GuardRuntimeError.missingExpectedIdentity
            }
            return session
        },
        now: { synthetic }
    )
}

private func eventually(
    timeout: Duration = .seconds(3),
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

private func signInFile(in folder: URL) -> URL {
    folder.appendingPathComponent("auth.json")
}

// MARK: Codex

@Test func removingOneCodexAccountLeavesTheOtherRunning() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let first = LifecycleSession(email: "first@example.com")
    let second = LifecycleSession(email: "second@example.com")
    let controller = makeController(fixture, sessions: [
        "first@example.com": first, "second@example.com": second,
    ])
    defer { Task { await controller.stop() } }
    _ = try await controller.start()
    try Data("synthetic".utf8).write(to: signInFile(in: fixture.home(fixture.first)))
    try Data("synthetic".utf8).write(to: signInFile(in: fixture.home(fixture.second)))
    let secondState = try await fixture.persistence().snapshot().monitorState(for: fixture.second.id)

    let outcome = try await controller.removeProfile(profileID: fixture.first.id)

    #expect(outcome == .complete)
    #expect(await controller.snapshot().profiles.map(\.id) == [fixture.second.id])
    #expect(await first.shutdowns == 1)
    #expect(await second.shutdowns == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.home(fixture.first).path))
    #expect(FileManager.default.fileExists(atPath: signInFile(in: fixture.home(fixture.second)).path))
    let saved = try await fixture.persistence().snapshot()
    #expect(saved.profiles.map(\.id) == [fixture.second.id])
    #expect(saved.pendingHomeDiscards == nil)
    #expect(saved.monitorState(for: fixture.second.id)?.isEnabled == secondState?.isEnabled)

    let firstReads = await first.accountReads
    let secondReads = await second.accountReads
    #expect(await eventually {
        _ = await controller.checkNow()
        return await second.accountReads > secondReads
    })
    #expect(await first.accountReads == firstReads)
    #expect(await first.consumes == 0)
    #expect(await second.consumes == 0)

    await #expect(throws: AccountLifecycleError.accountNotFound) {
        try await controller.removeProfile(profileID: fixture.first.id)
    }
}

@Test func codexRemovalWaitsForARunningCheckAndBlocksOtherActions() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let first = LifecycleSession(email: "first@example.com")
    let second = LifecycleSession(email: "second@example.com")
    let controller = makeController(fixture, sessions: [
        "first@example.com": first, "second@example.com": second,
    ])
    defer { Task { await controller.stop() } }
    _ = try await controller.start()

    await first.hold()
    let check = Task { await controller.checkNow() }
    #expect(await eventually { await first.isHolding() })

    let removal = Task { try await controller.removeProfile(profileID: fixture.first.id) }
    try await Task.sleep(for: .milliseconds(150))
    #expect(try await fixture.persistence().snapshot().profiles.count == 2)
    await #expect(throws: AccountLifecycleError.busy) {
        try await controller.setEnabled(profileID: fixture.first.id, enabled: false)
    }
    await #expect(throws: AccountLifecycleError.busy) {
        try await controller.renameProfile(profileID: fixture.first.id, displayName: "Later")
    }
    await #expect(throws: AccountLifecycleError.busy) {
        try await controller.removeProfile(profileID: fixture.first.id)
    }

    await first.release()
    _ = await check.value
    #expect(try await removal.value == .complete)
    #expect(try await fixture.persistence().snapshot().profiles.map(\.id) == [fixture.second.id])
}

@Test func codexRemovalGivesUpWithoutChangesWhenACheckHangs() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let first = LifecycleSession(email: "first@example.com")
    let second = LifecycleSession(email: "second@example.com")
    let controller = makeController(fixture, sessions: [
        "first@example.com": first, "second@example.com": second,
    ])
    defer { Task { await controller.stop() } }
    _ = try await controller.start()
    await controller.overrideRemovalDrainTimeoutForTesting(.milliseconds(100))
    let before = try await fixture.persistence().snapshot()

    await first.hold()
    let check = Task { await controller.checkNow() }
    #expect(await eventually { await first.isHolding() })
    await #expect(throws: AccountLifecycleError.busy) {
        try await controller.removeProfile(profileID: fixture.first.id)
    }
    #expect(try await fixture.persistence().snapshot().profiles == before.profiles)
    #expect(await controller.snapshot().profiles.count == 2)
    await first.release()
    _ = await check.value
    #expect(await first.shutdowns == 0)
}

@Test func codexRemovalKeepsAnUncertainResetAndReAddStaysPaused() async throws {
    // A paused account still holding a reset that may have been sent.
    let fixture = try LifecycleFixture(firstEnabled: false)
    defer { fixture.remove() }
    let persistence = fixture.persistence()
    _ = try await persistence.loadOrBootstrap(now: synthetic)
    let key = GuardPersistentState.key(for: fixture.first.id)
    let pending = RedemptionAttempt(
        profileID: key,
        idempotencyKey: "weekly-reset-synthetic-pending",
        creditID: "credit-1",
        weeklyResetAtBefore: synthetic.addingTimeInterval(86_400),
        weeklyUsedPercentBefore: 99,
        availableCreditCountBefore: 1,
        preparedAt: synthetic,
        phase: .retryable
    )
    _ = try await persistence.saveMonitorState(MonitorState(profileID: key, attempt: pending), now: synthetic)

    let first = LifecycleSession(email: "first@example.com")
    let second = LifecycleSession(email: "second@example.com")
    let controller = makeController(
        fixture,
        sessions: ["first@example.com": first, "second@example.com": second],
        persistence: persistence
    )
    defer { Task { await controller.stop() } }
    _ = try await controller.start()
    let row = await controller.snapshot().profiles.first { $0.id == fixture.first.id }
    #expect(row?.removalKeepsResetRecord == true)

    let outcome = try await controller.removeProfile(profileID: fixture.first.id)
    #expect(outcome.keptResetRecord)
    #expect(outcome.notice == nil)

    let readded = try await controller.addProfile(expectedEmail: "First@Example.com", displayName: "Again")
    let newRow = try #require(readded.profiles.first { $0.displayName == "Again" })
    #expect(!newRow.autoResetEnabled)
    #expect(newRow.removalKeepsResetRecord)
    let saved = try await persistence.snapshot()
    #expect(saved.monitorState(for: newRow.id)?.attempt?.idempotencyKey == pending.idempotencyKey)
    #expect(saved.retainedRedemptions == nil)
    #expect(await first.consumes == 0)
}

@Test func codexRenameChangesOnlyThatRow() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let controller = makeController(fixture, sessions: [
        "first@example.com": LifecycleSession(email: "first@example.com"),
        "second@example.com": LifecycleSession(email: "second@example.com"),
    ])
    defer { Task { await controller.stop() } }
    _ = try await controller.start()

    let snapshot = try await controller.renameProfile(profileID: fixture.first.id, displayName: "  Day job ")
    #expect(snapshot.profiles.map(\.displayName) == ["Day job", "Personal"])
    #expect(snapshot.profiles.map(\.autoResetEnabled) == [true, true])
    await #expect(throws: AccountLifecycleError.invalidName) {
        try await controller.renameProfile(profileID: fixture.first.id, displayName: "   ")
    }
    await #expect(throws: AccountLifecycleError.accountNotFound) {
        try await controller.renameProfile(profileID: UUID(), displayName: "Ghost")
    }
    #expect(try await fixture.persistence().snapshot().profiles.map(\.displayName) == ["Day job", "Personal"])
}

@Test func readOnlyCodexRuntimeRefusesAccountChanges() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let controller = makeController(fixture, sessions: [
        "first@example.com": LifecycleSession(email: "first@example.com"),
        "second@example.com": LifecycleSession(email: "second@example.com"),
    ], mode: .readOnly)
    defer { Task { await controller.stop() } }
    _ = try await controller.start()
    await #expect(throws: AccountLifecycleError.readOnly) {
        try await controller.renameProfile(profileID: fixture.first.id, displayName: "X")
    }
    await #expect(throws: AccountLifecycleError.readOnly) {
        try await controller.removeProfile(profileID: fixture.first.id)
    }
    #expect(try await fixture.persistence().snapshot().profiles.count == 2)
}

// MARK: Claude

private final class ScriptedClaudeRunner: ClaudeCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(arguments: [String], directory: URL)] = []
    private var heldDirectory: URL?
    private var held: [CheckedContinuation<Void, Never>] = []
    private let logoutStatus: Int32
    private let failure: ClaudeCLIError?

    init(logoutStatus: Int32 = 0, failure: ClaudeCLIError? = nil) {
        self.logoutStatus = logoutStatus
        self.failure = failure
    }

    var recorded: [(arguments: [String], directory: URL)] { lock.withLock { calls } }
    var isHolding: Bool { lock.withLock { !held.isEmpty } }

    func hold(_ directory: URL) { lock.withLock { heldDirectory = directory.standardizedFileURL } }

    func release() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            heldDirectory = nil
            defer { held.removeAll() }
            return held
        }
        for continuation in waiting { continuation.resume() }
    }

    func run(arguments: [String], configDirectory: URL, timeout: Duration) async throws -> ClaudeCommandOutput {
        lock.withLock { calls.append((arguments, configDirectory.standardizedFileURL)) }
        if let failure { throw failure }
        let shouldHold = lock.withLock { heldDirectory == configDirectory.standardizedFileURL }
        if shouldHold {
            await withCheckedContinuation { continuation in
                lock.withLock { held.append(continuation) }
            }
        }
        if arguments == ["auth", "logout"] {
            return ClaudeCommandOutput(status: logoutStatus, standardOutput: Data())
        }
        return ClaudeCommandOutput(status: 1, standardOutput: Data(#"{"loggedIn":false}"#.utf8))
    }
}

private struct ClaudeFixture: @unchecked Sendable {
    let root: URL
    let configuration: ClaudeMonitorConfiguration
    let first = ClaudeProfileConfiguration(displayName: "Work", expectedEmail: "first@example.com")
    let second = ClaudeProfileConfiguration(displayName: "Home", expectedEmail: "second@example.com")

    init(readOnly: Bool = false) async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-lifecycle-\(UUID().uuidString)", isDirectory: true)
        configuration = ClaudeMonitorConfiguration(
            isReadOnly: readOnly,
            executableURL: URL(fileURLWithPath: "/does/not/run/in-this-test"),
            applicationSupportDirectory: root,
            pollInterval: .seconds(3_600)
        )
        var state = ClaudePersistentState(profiles: [first, second])
        state.setState(ClaudeProfileState(planName: "Pro"), for: second.id)
        try await SecureStateStore<ClaudePersistentState>(fileURL: configuration.stateURL).save(state)
        for profile in [first, second] {
            let folder = try profile.prepareConfigDirectory(root: configuration.profilesRoot)
            try Data("synthetic".utf8).write(to: folder.appendingPathComponent(".claude.json"))
        }
    }

    func folder(_ profile: ClaudeProfileConfiguration) -> URL {
        profile.configDirectoryURL(root: configuration.profilesRoot)
    }

    func saved() async throws -> ClaudePersistentState? {
        try await SecureStateStore<ClaudePersistentState>(fileURL: configuration.stateURL).load()
    }

    func monitor(_ runner: ScriptedClaudeRunner) -> ClaudeMonitorController {
        ClaudeMonitorController(
            configuration: configuration,
            cli: ClaudeCLI(runner: runner),
            now: { synthetic },
            updateHandler: { _ in },
            notificationHandler: { _ in }
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func removingOneClaudeAccountSignsOutOnlyThatFolder() async throws {
    let fixture = try await ClaudeFixture()
    defer { fixture.remove() }
    let runner = ScriptedClaudeRunner()
    let monitor = fixture.monitor(runner)
    defer { Task { await monitor.stop() } }
    try await monitor.start()

    let outcome = try await monitor.removeProfile(profileID: fixture.first.id)

    #expect(outcome == .complete)
    let logouts = runner.recorded.filter { $0.arguments == ["auth", "logout"] }
    #expect(logouts.map(\.directory) == [fixture.folder(fixture.first).standardizedFileURL])
    #expect(!FileManager.default.fileExists(atPath: fixture.folder(fixture.first).path))
    #expect(FileManager.default.fileExists(atPath: fixture.folder(fixture.second).appendingPathComponent(".claude.json").path))
    let saved = try #require(try await fixture.saved())
    #expect(saved.profiles == [fixture.second])
    #expect(saved.states.keys.sorted() == [ClaudePersistentState.key(for: fixture.second.id)])
    #expect(await monitor.snapshot().profiles.map(\.id) == [fixture.second.id])
}

@Test func claudeRemovalWorksWithoutClaudeCodeAndSaysWhatRemains() async throws {
    let fixture = try await ClaudeFixture()
    defer { fixture.remove() }
    let monitor = fixture.monitor(ScriptedClaudeRunner(failure: .executableNotFound))
    defer { Task { await monitor.stop() } }
    try await monitor.start()

    let outcome = try await monitor.removeProfile(profileID: fixture.first.id)

    #expect(outcome.claudeSignInMayRemain)
    #expect(outcome.notice?.contains("Claude Code-credentials-") == true)
    #expect(!FileManager.default.fileExists(atPath: fixture.folder(fixture.first).path))
    #expect(try await fixture.saved()?.profiles == [fixture.second])
}

@Test func aLinkedClaudeFolderIsNeverSignedOutOrFollowed() async throws {
    let fixture = try await ClaudeFixture()
    defer { fixture.remove() }
    let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let sentinel = outside.appendingPathComponent(".claude.json")
    try Data("keep".utf8).write(to: sentinel)
    try FileManager.default.removeItem(at: fixture.folder(fixture.first))
    try FileManager.default.createSymbolicLink(at: fixture.folder(fixture.first), withDestinationURL: outside)
    let runner = ScriptedClaudeRunner()
    let monitor = fixture.monitor(runner)
    defer { Task { await monitor.stop() } }
    try await monitor.start()

    let outcome = try await monitor.removeProfile(profileID: fixture.first.id)

    #expect(outcome.claudeSignInMayRemain)
    #expect(runner.recorded.filter { $0.arguments == ["auth", "logout"] }.isEmpty)
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep")
    var status = stat()
    #expect(lstat(fixture.folder(fixture.first).path, &status) != 0)
    #expect(try await fixture.saved()?.profiles == [fixture.second])
}

@Test func aFailedClaudeLogoutIsReportedNotHidden() async throws {
    let fixture = try await ClaudeFixture()
    defer { fixture.remove() }
    let monitor = fixture.monitor(ScriptedClaudeRunner(logoutStatus: 1))
    defer { Task { await monitor.stop() } }
    try await monitor.start()
    #expect(try await monitor.removeProfile(profileID: fixture.first.id).claudeSignInMayRemain)
}

@Test func claudeRemovalWaitsForARunningCheckAndKeepsAConcurrentRename() async throws {
    let fixture = try await ClaudeFixture()
    defer { fixture.remove() }
    let runner = ScriptedClaudeRunner()
    let monitor = fixture.monitor(runner)
    defer { Task { await monitor.stop() } }
    try await monitor.start()

    runner.hold(fixture.folder(fixture.first))
    let check = Task { await monitor.checkNow() }
    #expect(await eventually { runner.isHolding })

    let removal = Task { try await monitor.removeProfile(profileID: fixture.first.id) }
    try await monitor.renameProfile(profileID: fixture.second.id, displayName: " Side  project ")
    #expect(await eventually {
        do {
            try await monitor.renameProfile(profileID: fixture.first.id, displayName: fixture.first.displayName)
            return false
        } catch {
            return (error as? AccountLifecycleError) == .busy
        }
    })
    #expect(try await fixture.saved()?.profiles.count == 2)
    #expect(runner.recorded.filter { $0.arguments == ["auth", "logout"] }.isEmpty)

    runner.release()
    _ = await check.value
    #expect(try await removal.value == .complete)
    let saved = try #require(try await fixture.saved())
    #expect(saved.profiles.map(\.displayName) == ["Side project"])
    #expect(saved.states[ClaudePersistentState.key(for: fixture.first.id)] == nil)
    #expect(saved.state(for: fixture.second.id).planName == "Pro")
}

@Test func claudeRemovalGivesUpWhenACheckHangs() async throws {
    let fixture = try await ClaudeFixture()
    defer { fixture.remove() }
    let runner = ScriptedClaudeRunner()
    let monitor = fixture.monitor(runner)
    defer { Task { await monitor.stop() } }
    try await monitor.start()
    await monitor.overrideRemovalDrainTimeoutForTesting(.milliseconds(100))

    runner.hold(fixture.folder(fixture.first))
    let check = Task { await monitor.checkNow() }
    #expect(await eventually { runner.isHolding })
    await #expect(throws: AccountLifecycleError.busy) {
        try await monitor.removeProfile(profileID: fixture.first.id)
    }
    #expect(FileManager.default.fileExists(atPath: fixture.folder(fixture.first).path))
    #expect(try await fixture.saved()?.profiles.count == 2)
    runner.release()
    _ = await check.value
}

@Test func claudeStartRestoresEnrolledAccountsAndFinishesCommittedRemovals() async throws {
    let fixture = try await ClaudeFixture()
    defer { fixture.remove() }
    let root = fixture.configuration.profilesRoot
    try OwnedProfileDirectory.isolate(profileID: fixture.first.id, root: root)
    let gone = root.appendingPathComponent(".discard-" + UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
    try Data("synthetic".utf8).write(to: gone.appendingPathComponent("marker"))
    let monitor = fixture.monitor(ScriptedClaudeRunner())
    defer { Task { await monitor.stop() } }
    try await monitor.start()
    let entries = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    #expect(entries == [fixture.first, fixture.second].map { $0.id.uuidString.lowercased() }.sorted())
    #expect(FileManager.default.fileExists(atPath: fixture.folder(fixture.first).appendingPathComponent(".claude.json").path))
}

@Test func readOnlyClaudeMonitorRefusesAccountChanges() async throws {
    let fixture = try await ClaudeFixture(readOnly: true)
    defer { fixture.remove() }
    let monitor = fixture.monitor(ScriptedClaudeRunner())
    defer { Task { await monitor.stop() } }
    try await monitor.start()
    await #expect(throws: AccountLifecycleError.readOnly) {
        try await monitor.renameProfile(profileID: fixture.first.id, displayName: "X")
    }
    await #expect(throws: AccountLifecycleError.readOnly) {
        try await monitor.removeProfile(profileID: fixture.first.id)
    }
    #expect(FileManager.default.fileExists(atPath: fixture.folder(fixture.first).path))
}

@Test func handlersRouteByProviderAndReportNotices() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let claudeFixture = try await ClaudeFixture()
    defer { claudeFixture.remove() }
    let codex = makeController(fixture, sessions: [
        "first@example.com": LifecycleSession(email: "first@example.com"),
        "second@example.com": LifecycleSession(email: "second@example.com"),
    ])
    let claude = claudeFixture.monitor(ScriptedClaudeRunner(failure: .executableNotFound))
    defer {
        Task {
            await codex.stop()
            await claude.stop()
        }
    }
    _ = try await codex.start()
    try await claude.start()
    let notices = NoticeBox()
    let handlers = AccountLifecycleHandlers(codex: codex, claude: claude) { account, text in
        notices.append(account, text)
    }

    try await handlers.rename(AccountRef(provider: .codex, id: fixture.first.id), "Renamed")
    try await handlers.rename(AccountRef(provider: .claude, id: claudeFixture.second.id), "Renamed too")
    try await handlers.remove(AccountRef(provider: .claude, id: claudeFixture.first.id))

    #expect(await codex.snapshot().profiles.first?.displayName == "Renamed")
    #expect(await claude.snapshot().profiles.map(\.displayName) == ["Renamed too"])
    #expect(notices.values.map(\.0) == [AccountRef(provider: .claude, id: claudeFixture.first.id)])
    await #expect(throws: AccountLifecycleError.unavailable) {
        try await AccountLifecycleHandlers(codex: codex, claude: nil)
            .rename(AccountRef(provider: .claude, id: UUID()), "X")
    }
}

private final class NoticeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(AccountRef, String)] = []
    var values: [(AccountRef, String)] { lock.withLock { stored } }
    func append(_ account: AccountRef, _ text: String) { lock.withLock { stored.append((account, text)) } }
}
