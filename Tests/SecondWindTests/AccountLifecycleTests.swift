import Foundation
import Testing
@testable import SecondWind
@testable import SecondWindCore

// Synthetic accounts only: two Codex profiles with stand-in files, never real credentials.

private struct AccountFixture: @unchecked Sendable {
    let root: URL
    let stateURL: URL
    let profilesURL: URL
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let first: ProfileConfiguration
    let second: ProfileConfiguration

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-lifecycle-\(UUID().uuidString)", isDirectory: true)
        stateURL = root.appendingPathComponent("state.json")
        profilesURL = root.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        first = ProfileConfiguration(displayName: "Work", expectedEmail: "first@example.com", isEnabled: true)
        second = ProfileConfiguration(displayName: "Personal", expectedEmail: "second@example.com", isEnabled: true)
        let state = GuardPersistentState(
            profiles: [first, second],
            monitorStates: Dictionary(uniqueKeysWithValues: [first, second].map { profile in
                let key = GuardPersistentState.key(for: profile.id)
                return (key, MonitorState(profileID: key))
            }),
            createdAt: now
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

    /// Stands in for the file Codex keeps its sign-in in. The contents are not a credential.
    func seedSignInFile(_ profile: ProfileConfiguration) throws {
        try Data("synthetic".utf8).write(to: home(profile).appendingPathComponent("auth.json"))
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func attempt(
    for profile: ProfileConfiguration,
    phase: RedemptionAttemptPhase,
    key: String = "weekly-reset-synthetic-key",
    at now: Date
) -> RedemptionAttempt {
    RedemptionAttempt(
        profileID: GuardPersistentState.key(for: profile.id),
        idempotencyKey: key,
        creditID: "credit-1",
        weeklyResetAtBefore: now.addingTimeInterval(3 * 86_400),
        weeklyUsedPercentBefore: 99,
        availableCreditCountBefore: 1,
        preparedAt: now,
        phase: phase
    )
}

private func saveAttempt(
    _ phase: RedemptionAttemptPhase,
    for profile: ProfileConfiguration,
    in fixture: AccountFixture,
    persistence: MonitorPersistence
) async throws -> RedemptionAttempt {
    let pending = attempt(for: profile, phase: phase, at: fixture.now)
    let key = GuardPersistentState.key(for: profile.id)
    _ = try await persistence.saveMonitorState(
        MonitorState(
            profileID: key,
            phase: .redeeming,
            confirmation: ThresholdConfirmation(
                weeklyResetAt: pending.weeklyResetAtBefore,
                count: 2,
                lastObservedAt: fixture.now,
                lastRemainingPercent: 1,
                firstObservedAt: fixture.now
            ),
            attempt: pending
        ),
        now: fixture.now
    )
    return pending
}

// MARK: Rename

@Test func renameChangesOnlyThatAccountsName() async throws {
    let fixture = try AccountFixture()
    defer { fixture.remove() }
    let persistence = fixture.persistence()
    let before = try await persistence.loadOrBootstrap(now: fixture.now)

    let renamed = try await persistence.renameProfile(
        fixture.first.id,
        displayName: "  Day\n job\taccount  ",
        now: fixture.now
    )

    #expect(renamed.profiles[0].displayName == "Day job account")
    #expect(renamed.profiles[1] == before.profiles[1])
    #expect(renamed.monitorStates == before.monitorStates)
    #expect(renamed.profiles[0].expectedEmail == before.profiles[0].expectedEmail)
    #expect(renamed.profiles[0].isEnabled == before.profiles[0].isEnabled)
    #expect((renamed.revision ?? 0) == (before.revision ?? 0) + 1)
    #expect(try await fixture.persistence().snapshot() == renamed)
}

@Test func renameToTheSameNameWritesNothing() async throws {
    let fixture = try AccountFixture()
    defer { fixture.remove() }
    let persistence = fixture.persistence()
    let before = try await persistence.loadOrBootstrap(now: fixture.now)
    let after = try await persistence.renameProfile(fixture.first.id, displayName: " Work ")
    #expect(after == before)
}

@Test func renameCapsLengthAndRejectsBlankOrUnknown() async throws {
    let fixture = try AccountFixture()
    defer { fixture.remove() }
    let persistence = fixture.persistence()
    let before = try await persistence.loadOrBootstrap(now: fixture.now)

    let long = String(repeating: "a", count: 80)
    let capped = try await persistence.renameProfile(fixture.first.id, displayName: long)
    #expect(capped.profiles[0].displayName.count == AccountNameRules.codexMaximumLength)

    await #expect(throws: MonitorPersistenceError.invalidDisplayName) {
        try await persistence.renameProfile(fixture.first.id, displayName: " \n\t ")
    }
    let unknown = UUID()
    await #expect(throws: MonitorPersistenceError.profileNotFound(unknown)) {
        try await persistence.renameProfile(unknown, displayName: "Ghost")
    }
    let after = try await persistence.snapshot()
    #expect(after.profiles[1] == before.profiles[1])
}

@Test func accountNameRulesFoldWhitespaceAndDropControls() {
    #expect(AccountNameRules.normalized("  a \n\n b\u{0007}c  ", maximumLength: 60) == "a bc")
    #expect(AccountNameRules.normalized("\u{0000}\n", maximumLength: 60) == nil)
    #expect(AccountNameRules.normalized("abc def", maximumLength: 4) == "abc")
}

// MARK: Remove

@Test func removeDeletesOnlyTheNamedAccountAndItsFolder() async throws {
    let fixture = try AccountFixture()
    defer { fixture.remove() }
    let persistence = fixture.persistence()
    _ = try await persistence.loadOrBootstrap(now: fixture.now)
    try fixture.seedSignInFile(fixture.first)
    try fixture.seedSignInFile(fixture.second)
    let otherPending = try await saveAttempt(
        .retryable, for: fixture.second, in: fixture, persistence: persistence
    )
    let before = try await persistence.snapshot()
    let otherHomeContents = try FileManager.default.contentsOfDirectory(atPath: fixture.home(fixture.second).path).sorted()

    let removal = try await persistence.removeProfile(fixture.first.id, now: fixture.now)

    #expect(!removal.keptResetRecord)
    #expect(removal.state.profiles.map(\.id) == [fixture.second.id])
    #expect(removal.state.monitorState(for: fixture.first.id) == nil)
    #expect(removal.state.monitorState(for: fixture.second.id) == before.monitorState(for: fixture.second.id))
    #expect(removal.state.monitorState(for: fixture.second.id)?.attempt == otherPending)
    #expect(removal.state.profiles[0] == before.profiles[1])
    #expect(removal.state.pendingHomeDiscards == [GuardPersistentState.key(for: fixture.first.id)])
    #expect(removal.state.retainedRedemptions == nil)
    // The folder is untouched until the caller has stopped the account's Codex session.
    #expect(fixture.exists(fixture.home(fixture.first)))

    let remaining = try await persistence.discardPendingProfileHomes(now: fixture.now)
    #expect(remaining.isEmpty)
    #expect(!fixture.exists(fixture.home(fixture.first)))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.home(fixture.second).path).sorted() == otherHomeContents)
    let after = try await persistence.snapshot()
    #expect(after.pendingHomeDiscards == nil)
    #expect(after.monitorState(for: fixture.second.id) == before.monitorState(for: fixture.second.id))
    #expect(try await fixture.persistence().loadOrBootstrap(now: fixture.now) == after)

    await #expect(throws: MonitorPersistenceError.profileNotFound(fixture.first.id)) {
        try await persistence.removeProfile(fixture.first.id)
    }
}

@Test(arguments: [
    RedemptionAttemptPhase.requestInFlight,
    .retryable,
    .awaitingVerification,
    .verificationFailed,
])
func removalKeepsAnUncertainRedemption(phase: RedemptionAttemptPhase) async throws {
    let fixture = try AccountFixture()
    defer { fixture.remove() }
    let persistence = fixture.persistence()
    _ = try await persistence.loadOrBootstrap(now: fixture.now)
    let pending = try await saveAttempt(phase, for: fixture.first, in: fixture, persistence: persistence)
    #expect(try await persistence.snapshot().removalKeepsResetRecord(for: fixture.first.id))

    let removal = try await persistence.removeProfile(fixture.first.id, now: fixture.now)

    #expect(removal.keptResetRecord)
    let record = try #require(removal.state.retainedRedemptions?.first)
    #expect(removal.state.retainedRedemptions?.count == 1)
    #expect(record.expectedEmail == "first@example.com")
    #expect(record.formerProfileID == GuardPersistentState.key(for: fixture.first.id))
    #expect(record.attempt == pending)
    #expect(record.confirmation?.count == 2)
    // The kept record survives a restart.
    #expect(try await fixture.persistence().loadOrBootstrap(now: fixture.now).retainedRedemptions == [record])
}

@Test(arguments: [
    RedemptionAttemptPhase.prepared,
    .succeeded,
    .nothingToReset,
    .noCredit,
    .requestRejected,
])
func removalDropsARedemptionThatNeedsNoRecovery(phase: RedemptionAttemptPhase) async throws {
    let fixture = try AccountFixture()
    defer { fixture.remove() }
    let persistence = fixture.persistence()
    _ = try await persistence.loadOrBootstrap(now: fixture.now)
    _ = try await saveAttempt(phase, for: fixture.first, in: fixture, persistence: persistence)
    #expect(try await persistence.snapshot().removalKeepsResetRecord(for: fixture.first.id) == false)

    let removal = try await persistence.removeProfile(fixture.first.id, now: fixture.now)

    #expect(!removal.keptResetRecord)
    #expect(removal.state.retainedRedemptions == nil)
}

@Test func reAddingTheSameEmailReattachesTheKeyAndStaysPaused() async throws {
    let fixture = try AccountFixture()
    defer { fixture.remove() }
    let persistence = fixture.persistence()
    _ = try await persistence.loadOrBootstrap(now: fixture.now)
    let pending = try await saveAttempt(.retryable, for: fixture.first, in: fixture, persistence: persistence)
    try await persistence.removeProfile(fixture.first.id, now: fixture.now)
    try await persistence.discardPendingProfileHomes(now: fixture.now)

    let newID = UUID()
    let state = try await persistence.addProfile(
        expectedEmail: "  FIRST@example.COM ",
        displayName: "Back again",
        id: newID,
        now: fixture.now
    )

    let profile = try #require(state.profiles.first(where: { $0.id == newID }))
    let monitor = try #require(state.monitorState(for: newID))
    #expect(!profile.isEnabled)
    #expect(!monitor.isEnabled)
    #expect(monitor.phase == .disabled)
    #expect(monitor.attempt?.idempotencyKey == pending.idempotencyKey)
    #expect(monitor.attempt?.creditID == pending.creditID)
    #expect(monitor.attempt?.phase == .retryable)
    #expect(monitor.attempt?.profileID == GuardPersistentState.key(for: newID))
    #expect(state.retainedRedemptions == nil)
    #expect(state.removalKeepsResetRecord(for: newID))

    // While paused the policy neither mints a new key nor sends anything.
    let evaluation = ResetPolicyEngine().evaluate(
        weeklyLimit: CanonicalWeeklyLimit(
            lane: .secondary,
            usedPercent: 99,
            durationMinutes: RateLimitClassifier.weeklyDurationMinutes,
            resetsAt: pending.weeklyResetAtBefore,
            observedAt: fixture.now
        ),
        inventory: ResetCreditInventory(availableCount: 1, credits: nil),
        state: monitor,
        now: fixture.now,
        newIdempotencyKey: "weekly-reset-would-be-new"
    )
    #expect(evaluation.action == .none)
    #expect(evaluation.state.attempt?.idempotencyKey == pending.idempotencyKey)

    // Reconnecting pauses again and still keeps the record.
    let paused = try await persistence.setProfileEnabled(newID, enabled: false, now: fixture.now)
    #expect(paused.monitorState(for: newID)?.attempt?.idempotencyKey == pending.idempotencyKey)
}

@Test func aDifferentEmailDoesNotTakeAKeptRecord() async throws {
    let fixture = try AccountFixture()
    defer { fixture.remove() }
    let persistence = fixture.persistence()
    _ = try await persistence.loadOrBootstrap(now: fixture.now)
    _ = try await saveAttempt(.requestInFlight, for: fixture.first, in: fixture, persistence: persistence)
    try await persistence.removeProfile(fixture.first.id, now: fixture.now)

    let state = try await persistence.addProfile(expectedEmail: "third@example.com", displayName: "")
    #expect(state.profiles.last.flatMap { state.monitorState(for: $0.id)?.attempt } == nil)
    #expect(state.retainedRedemptions?.count == 1)
}

@Test func anAccountAddedWithoutAnEmailTakesItsFirstSignInsIdentityAndKeptRecord() async throws {
    let fixture = try AccountFixture()
    defer { fixture.remove() }
    let persistence = fixture.persistence()
    _ = try await persistence.loadOrBootstrap(now: fixture.now)
    let pending = try await saveAttempt(.retryable, for: fixture.first, in: fixture, persistence: persistence)
    try await persistence.removeProfile(fixture.first.id, now: fixture.now)

    let newID = UUID()
    let added = try await persistence.addProfile(expectedEmail: nil, displayName: "New account", id: newID, now: fixture.now)
    #expect(added.profiles.first(where: { $0.id == newID })?.expectedEmail == nil)
    #expect(added.monitorState(for: newID)?.attempt == nil, "Nothing attaches before the identity is known")
    #expect(added.retainedRedemptions?.count == 1)
    // An account with no identity can never be switched on.
    await #expect(throws: MonitorPersistenceError.invalidExpectedIdentity) {
        try await persistence.setProfileEnabled(newID, enabled: true, now: fixture.now)
    }

    let pinned = try await persistence.pinIdentity(newID, email: " First@Example.com ", displayName: "Personal", now: fixture.now)
    let profile = try #require(pinned.profiles.first(where: { $0.id == newID }))
    #expect(profile.expectedEmail == "first@example.com")
    #expect(profile.displayName == "Personal")
    #expect(!profile.isEnabled)
    #expect(pinned.monitorState(for: newID)?.attempt?.idempotencyKey == pending.idempotencyKey)
    #expect(pinned.monitorState(for: newID)?.attempt?.profileID == GuardPersistentState.key(for: newID))
    #expect(pinned.retainedRedemptions == nil)
    // The identity survives a restart and never changes afterwards.
    let reloaded = try await fixture.persistence().loadOrBootstrap(now: fixture.now)
    #expect(reloaded.profiles.first(where: { $0.id == newID })?.expectedEmail == "first@example.com")
    #expect(reloaded.monitorState(for: newID)?.attempt?.idempotencyKey == pending.idempotencyKey)
    _ = try await persistence.pinIdentity(newID, email: "first@example.com", now: fixture.now)
    await #expect(throws: MonitorPersistenceError.invalidExpectedIdentity) {
        try await persistence.pinIdentity(newID, email: "someone-else@example.com", now: fixture.now)
    }
}

@Test func aFirstSignInAsAnAccountAlreadyListedIsADuplicate() async throws {
    let fixture = try AccountFixture()
    defer { fixture.remove() }
    let persistence = fixture.persistence()
    _ = try await persistence.loadOrBootstrap(now: fixture.now)
    let newID = UUID()
    _ = try await persistence.addProfile(expectedEmail: nil, displayName: "New account", id: newID, now: fixture.now)
    await #expect(throws: MonitorPersistenceError.duplicateExpectedIdentity) {
        try await persistence.pinIdentity(newID, email: "SECOND@example.com", now: fixture.now)
    }
    #expect(try await persistence.snapshot().profiles.first(where: { $0.id == newID })?.expectedEmail == nil)
}

@Test func anInterruptedFolderDeleteFinishesOnNextLaunch() async throws {
    let fixture = try AccountFixture()
    defer { fixture.remove() }
    let persistence = fixture.persistence()
    _ = try await persistence.loadOrBootstrap(now: fixture.now)
    try fixture.seedSignInFile(fixture.first)
    try await persistence.removeProfile(fixture.first.id, now: fixture.now)

    await persistence.injectTestingFault(.beforeProfileHomeDiscard)
    await #expect(throws: (any Error).self) {
        try await persistence.discardPendingProfileHomes(now: fixture.now)
    }
    #expect(fixture.exists(fixture.home(fixture.first)))

    let relaunched = try await fixture.persistence().loadOrBootstrap(now: fixture.now)
    #expect(!fixture.exists(fixture.home(fixture.first)))
    #expect(relaunched.pendingHomeDiscards == nil)
    #expect(fixture.exists(fixture.home(fixture.second)))
    #expect(relaunched.profiles.map(\.id) == [fixture.second.id])
}

@Test func aRemovalWhoseDurabilityCheckFailedIsStillComplete() async throws {
    let fixture = try AccountFixture()
    defer { fixture.remove() }
    let persistence = fixture.persistence()
    _ = try await persistence.loadOrBootstrap(now: fixture.now)
    await persistence.injectTestingFault(.afterRemoveProfileWrite)
    await #expect(throws: (any Error).self) {
        try await persistence.removeProfile(fixture.first.id, now: fixture.now)
    }
    let state = try await persistence.snapshot()
    #expect(state.profiles.map(\.id) == [fixture.second.id])
    #expect(state.pendingHomeDiscards == [GuardPersistentState.key(for: fixture.first.id)])
}

@Test func aFailedRemovalWriteChangesNothing() async throws {
    let fixture = try AccountFixture()
    defer { fixture.remove() }
    let persistence = fixture.persistence()
    let before = try await persistence.loadOrBootstrap(now: fixture.now)
    await persistence.injectTestingFault(.beforeRemoveProfileWrite)
    await #expect(throws: (any Error).self) {
        try await persistence.removeProfile(fixture.first.id, now: fixture.now)
    }
    #expect(try await persistence.snapshot() == before)
    #expect(fixture.exists(fixture.home(fixture.first)))
}

// MARK: Concurrency

@Test func removalMergesWithConcurrentWritesToOtherAccounts() async throws {
    let fixture = try AccountFixture()
    defer { fixture.remove() }
    let persistence = fixture.persistence()
    _ = try await persistence.loadOrBootstrap(now: fixture.now)
    let secondKey = GuardPersistentState.key(for: fixture.second.id)
    let thirdID = UUID()

    await withTaskGroup(of: Void.self) { group in
        group.addTask { _ = try? await persistence.removeProfile(fixture.first.id) }
        group.addTask { _ = try? await persistence.setProfileEnabled(fixture.second.id, enabled: false) }
        group.addTask {
            _ = try? await persistence.addProfile(expectedEmail: "third@example.com", displayName: "Third", id: thirdID)
        }
        group.addTask { _ = try? await persistence.renameProfile(fixture.second.id, displayName: "Renamed") }
    }

    let state = try await persistence.snapshot()
    #expect(state.profiles.map(\.id) == [fixture.second.id, thirdID])
    #expect(state.profiles[0].displayName == "Renamed")
    #expect(!state.profiles[0].isEnabled)
    #expect(state.monitorStates[secondKey]?.isEnabled == false)
    #expect(state.monitorState(for: fixture.first.id) == nil)
    #expect(state.pendingHomeDiscards == [GuardPersistentState.key(for: fixture.first.id)])
}

@Test func aRacingAttemptSaveIsEitherKeptOrRejectedNeverOrphaned() async throws {
    for _ in 0..<8 {
        let fixture = try AccountFixture()
        defer { fixture.remove() }
        let persistence = fixture.persistence()
        _ = try await persistence.loadOrBootstrap(now: fixture.now)
        let inFlight = attempt(for: fixture.first, phase: .requestInFlight, at: fixture.now)
        let key = GuardPersistentState.key(for: fixture.first.id)

        let save = Task { () -> Bool in
            do {
                _ = try await persistence.saveMonitorState(
                    MonitorState(profileID: key, phase: .redeeming, attempt: inFlight)
                )
                return true
            } catch {
                return false
            }
        }
        let remove = Task { () -> Bool in
            (try? await persistence.removeProfile(fixture.first.id)) != nil
        }
        let didSave = await save.value
        let didRemove = await remove.value

        #expect(didRemove)
        let state = try await persistence.snapshot()
        #expect(state.monitorState(for: fixture.first.id) == nil)
        if didSave {
            #expect(state.retainedRedemptions?.first?.attempt.idempotencyKey == inFlight.idempotencyKey)
        } else {
            #expect(state.retainedRedemptions == nil)
        }
    }
}

// MARK: Saved-state compatibility and validation

@Test func savedStateWithoutAccountFieldsStillLoadsAndOmitsThem() async throws {
    let fixture = try AccountFixture()
    defer { fixture.remove() }
    let original = try String(contentsOf: fixture.stateURL, encoding: .utf8)
    #expect(!original.contains("retainedRedemptions"))
    let persistence = fixture.persistence()
    _ = try await persistence.loadOrBootstrap(now: fixture.now)
    _ = try await persistence.renameProfile(fixture.first.id, displayName: "Changed")
    let written = try String(contentsOf: fixture.stateURL, encoding: .utf8)
    #expect(!written.contains("retainedRedemptions"))
    #expect(!written.contains("pendingHomeDiscards"))
}

@Test func validationRejectsTamperedAccountRecords() async throws {
    let fixture = try AccountFixture()
    defer { fixture.remove() }
    let persistence = fixture.persistence()
    let base = try await persistence.loadOrBootstrap(now: fixture.now)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    var activeDiscard = base
    activeDiscard.pendingHomeDiscards = [GuardPersistentState.key(for: fixture.first.id)]
    try encoder.encode(activeDiscard).write(to: fixture.stateURL)
    await #expect(throws: MonitorPersistenceError.invalidPendingHomeDiscard) {
        try await fixture.persistence().snapshot()
    }

    var pathDiscard = base
    pathDiscard.pendingHomeDiscards = ["../../outside"]
    try encoder.encode(pathDiscard).write(to: fixture.stateURL)
    await #expect(throws: MonitorPersistenceError.invalidPendingHomeDiscard) {
        try await fixture.persistence().snapshot()
    }

    var shadowing = base
    let former = UUID()
    var shadowAttempt = attempt(for: fixture.first, phase: .retryable, at: fixture.now)
    shadowAttempt.profileID = GuardPersistentState.key(for: former)
    shadowing.retainedRedemptions = [RetainedRedemption(
        expectedEmail: "first@example.com",
        formerProfileID: GuardPersistentState.key(for: former),
        attempt: shadowAttempt,
        retainedAt: fixture.now
    )]
    try encoder.encode(shadowing).write(to: fixture.stateURL)
    await #expect(throws: MonitorPersistenceError.invalidRetainedRedemption) {
        try await fixture.persistence().snapshot()
    }
}

// MARK: Claude state transforms and sign-out

@Test func claudeTransformsTouchOnlyTheNamedAccount() {
    let first = ClaudeProfileConfiguration(displayName: "A", expectedEmail: "a@example.com")
    let second = ClaudeProfileConfiguration(displayName: "B", expectedEmail: "b@example.com")
    var state = ClaudePersistentState(profiles: [first, second], sentAlertKeys: ["session@1"])
    state.rememberAlerts(["weekly@2"], for: first.id)
    #expect(state.alertKeys(for: first.id) == ["session@1", "weekly@2"])
    #expect(state.alertKeys(for: second.id) == ["session@1"])
    state.rememberAlerts(["weekly@2"], for: second.id)
    state.setState(ClaudeProfileState(planName: "Pro"), for: first.id)
    state.setState(ClaudeProfileState(planName: "Max"), for: second.id)

    #expect(ClaudeAccountLifecycle.rename(first.id, to: "Work", in: &state))
    #expect(state.profiles.map(\.displayName) == ["Work", "B"])
    #expect(ClaudeAccountLifecycle.remove(first.id, from: &state))
    #expect(state.profiles == [second])
    #expect(state.states.keys.sorted() == [ClaudePersistentState.key(for: second.id)])
    #expect(state.state(for: second.id).planName == "Max")
    #expect(state.alertKeys(for: first.id) == ["session@1"])
    #expect(state.alertKeys(for: second.id) == ["session@1", "weekly@2"])
    #expect(!ClaudeAccountLifecycle.remove(first.id, from: &state))
    #expect(!ClaudeAccountLifecycle.rename(first.id, to: "X", in: &state))
}

private final class RecordingClaudeRunner: ClaudeCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [([String], URL)] = []
    private let status: Int32
    private let error: ClaudeCLIError?

    init(status: Int32 = 0, error: ClaudeCLIError? = nil) {
        self.status = status
        self.error = error
    }

    var recorded: [([String], URL)] { lock.withLock { calls } }

    func run(arguments: [String], configDirectory: URL, timeout: Duration) async throws -> ClaudeCommandOutput {
        lock.withLock { calls.append((arguments, configDirectory)) }
        if let error { throw error }
        return ClaudeCommandOutput(status: status, standardOutput: Data())
    }
}

@Test func claudeSignOutUsesOnlyTheOfficialLogoutInThatFolder() async throws {
    let folder = URL(fileURLWithPath: "/tmp/sw-synthetic/claude/abc", isDirectory: true)
    let runner = RecordingClaudeRunner()
    #expect(try await ClaudeCLI(runner: runner).signOut(configDirectory: folder))
    #expect(runner.recorded.map(\.0) == [["auth", "logout"]])
    #expect(runner.recorded.map(\.1) == [folder])

    #expect(try await ClaudeCLI(runner: RecordingClaudeRunner(status: 1)).signOut(configDirectory: folder) == false)
    await #expect(throws: ClaudeCLIError.executableNotFound) {
        try await ClaudeCLI(runner: RecordingClaudeRunner(error: .executableNotFound)).signOut(configDirectory: folder)
    }
}

@Test func removalOutcomeDescribesWhatRemains() {
    #expect(AccountRemovalOutcome.complete.notice == nil)
    #expect(AccountRemovalOutcome(keptResetRecord: true).notice == nil)
    #expect(AccountRemovalOutcome(claudeSignInMayRemain: true).notice?.contains("Keychain") == true)
    #expect(AccountRemovalOutcome(folderCleanupPending: true).notice?.contains("next time") == true)
}

@Test func lifecycleErrorsMapToPlainRecoveryText() {
    #expect(AccountLifecycleError(codexFailure: MonitorPersistenceError.profileNotFound(UUID())) == .accountNotFound)
    #expect(AccountLifecycleError(codexFailure: MonitorPersistenceError.invalidDisplayName) == .invalidName)
    #expect(AccountLifecycleError(codexFailure: GuardRuntimeError.runtimeStopped) == .unavailable)
    #expect(AccountLifecycleError(codexFailure: SecureStateStoreError.ioFailure(operation: "rename", code: 5)) == .notSaved)
    for error in [AccountLifecycleError.accountNotFound, .invalidName, .busy, .readOnly, .unavailable, .notSaved] {
        #expect(error.errorDescription?.isEmpty == false)
    }
}
