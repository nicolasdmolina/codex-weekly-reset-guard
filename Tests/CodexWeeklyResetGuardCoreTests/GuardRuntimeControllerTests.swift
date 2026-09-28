import Foundation
import Testing
@testable import CodexWeeklyResetGuard
@testable import CodexWeeklyResetGuardCore

@Test func monitorPersistenceStartsEmptyWithoutExternalAccountDiscovery() async throws {
    let fixture = try RuntimeFixture(seedProfiles: false)
    defer { fixture.remove() }
    let persistence = MonitorPersistence(
        stateFileURL: fixture.stateURL,
        profilesDirectory: fixture.profilesURL
    )
    let state = try await persistence.loadOrBootstrap(now: fixture.now)
    #expect(state.profiles.isEmpty)
    #expect(state.monitorStates.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.profilesURL.path))
    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.stateURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test(arguments: [1, 2, 3])
func monitorPersistenceEnrollsAnyProfileCountDisabled(count: Int) async throws {
    let fixture = try RuntimeFixture(seedProfiles: false)
    defer { fixture.remove() }
    let persistence = MonitorPersistence(
        stateFileURL: fixture.stateURL,
        profilesDirectory: fixture.profilesURL
    )
    _ = try await persistence.loadOrBootstrap(now: fixture.now)
    for index in 0..<count {
        _ = try await persistence.addProfile(
            expectedEmail: "  PROFILE\(index)@Example.com  ",
            displayName: "",
            now: fixture.now
        )
    }
    let state = try await persistence.snapshot()
    #expect(state.profiles.count == count)
    #expect(state.profiles.allSatisfy { !$0.isEnabled })
    #expect(state.monitorStates.values.allSatisfy { !$0.isEnabled && $0.phase == .disabled })
    for (index, profile) in state.profiles.enumerated() {
        #expect(profile.expectedEmail == "profile\(index)@example.com")
        #expect(profile.displayName == "Codex profile \(index + 1)")
        let home = profile.codexHomeURL(profilesDirectory: fixture.profilesURL)
        let config = try String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)
        #expect(config.contains(#"cli_auth_credentials_store = "file""#))
        #expect(config.contains(#"persistence = "none""#))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
    }
    #expect(try await persistence.loadOrBootstrap() == state)
}

@Test func profileConfigurationDefaultsToDisabled() {
    #expect(!ProfileConfiguration(displayName: "New profile").isEnabled)
}

@Test func enrollmentRejectsDuplicateNormalizedIdentity() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let persistence = MonitorPersistence(stateFileURL: fixture.stateURL, profilesDirectory: fixture.profilesURL)
    let before = try await persistence.snapshot()
    do {
        _ = try await persistence.addProfile(expectedEmail: " FIRST@EXAMPLE.COM ", displayName: "Duplicate")
        Issue.record("Expected duplicate identity rejection")
    } catch let error as MonitorPersistenceError {
        #expect(error == .duplicateExpectedIdentity)
    }
    #expect(try await persistence.snapshot() == before)
}

@Test(arguments: ["", "person", "@example.com", "person@", "person @example.com", "person@example", ".person@example.com", "person..name@example.com"])
func enrollmentRejectsInvalidIdentity(email: String) async throws {
    let fixture = try RuntimeFixture(seedProfiles: false)
    defer { fixture.remove() }
    let persistence = MonitorPersistence(stateFileURL: fixture.stateURL, profilesDirectory: fixture.profilesURL)
    _ = try await persistence.loadOrBootstrap()
    let before = try await persistence.snapshot()
    do {
        _ = try await persistence.addProfile(expectedEmail: email, displayName: "Invalid")
        Issue.record("Expected invalid identity rejection")
    } catch let error as MonitorPersistenceError {
        #expect(error == .invalidExpectedIdentity)
    }
    #expect(try await persistence.snapshot() == before)
}

@Test func enrollmentPreservesExistingEnabledSettingsAndPolicyState() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let persistence = MonitorPersistence(stateFileURL: fixture.stateURL, profilesDirectory: fixture.profilesURL)
    let original = try await persistence.loadOrBootstrap()
    _ = try await persistence.addProfile(expectedEmail: "third@example.com", displayName: "Third")
    let stored = try await persistence.snapshot()
    #expect(Array(stored.profiles.prefix(original.profiles.count)) == original.profiles)
    for profile in original.profiles {
        #expect(stored.monitorState(for: profile.id) == original.monitorState(for: profile.id))
    }
    #expect(stored.profiles.last?.isEnabled == false)
}

@Test func monitorPersistenceMergesConcurrentProfileUpdates() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let persistence = MonitorPersistence(
        stateFileURL: fixture.stateURL,
        profilesDirectory: fixture.profilesURL
    )
    let initial = try await persistence.loadOrBootstrap()
    let profileIDs = initial.profiles.map(\.id)

    await withTaskGroup(of: Void.self) { group in
        for profileID in profileIDs {
            group.addTask {
                _ = try? await persistence.setProfileEnabled(profileID, enabled: false)
            }
        }
    }

    let stored = try await persistence.snapshot()
    #expect(stored.profiles.allSatisfy { !$0.isEnabled })
    #expect(stored.monitorStates.values.allSatisfy { !$0.isEnabled && $0.phase == .disabled })
}

@Test func monitorPersistenceNeverLosesConcurrentPreparedAttempts() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let persistence = MonitorPersistence(
        stateFileURL: fixture.stateURL,
        profilesDirectory: fixture.profilesURL
    )
    let initial = try await persistence.loadOrBootstrap()
    let resetAt = fixture.now.addingTimeInterval(86_400)
    let preparedStates = initial.profiles.enumerated().map { index, profile in
        var state = initial.monitorState(for: profile.id)!
        state.phase = .redeeming
        state.confirmation = ThresholdConfirmation(
            weeklyResetAt: resetAt,
            count: 2,
            lastObservedAt: fixture.now,
            lastRemainingPercent: 2,
            firstObservedAt: fixture.now.addingTimeInterval(-5)
        )
        state.attempt = RedemptionAttempt(
            profileID: GuardPersistentState.key(for: profile.id),
            idempotencyKey: "durable-key-\(index)",
            creditID: "credit-\(index)",
            weeklyResetAtBefore: resetAt,
            weeklyUsedPercentBefore: 98,
            availableCreditCountBefore: 1,
            preparedAt: fixture.now
        )
        return state
    }

    await withTaskGroup(of: Void.self) { group in
        for state in preparedStates {
            group.addTask {
                _ = try? await persistence.saveMonitorState(state)
            }
        }
    }

    let stored = try await persistence.snapshot()
    #expect(
        Set(stored.monitorStates.values.compactMap { $0.attempt?.idempotencyKey })
            == Set(["durable-key-0", "durable-key-1"])
    )
    #expect(stored.revision == 2)
}

@Test func stalePolicySaveCannotReenableADisabledProfile() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let persistence = MonitorPersistence(
        stateFileURL: fixture.stateURL,
        profilesDirectory: fixture.profilesURL
    )
    let initial = try await persistence.loadOrBootstrap()
    let profile = initial.profiles[0]
    var stale = initial.monitorState(for: profile.id)!
    stale.confirmation = ThresholdConfirmation(
        weeklyResetAt: fixture.now.addingTimeInterval(86_400),
        count: 2,
        lastObservedAt: fixture.now,
        lastRemainingPercent: 0,
        firstObservedAt: fixture.now.addingTimeInterval(-5)
    )
    stale.attempt = RedemptionAttempt(
        profileID: stale.profileID,
        idempotencyKey: "stale-prepared",
        creditID: nil,
        weeklyResetAtBefore: fixture.now.addingTimeInterval(86_400),
        weeklyUsedPercentBefore: 100,
        availableCreditCountBefore: 1,
        preparedAt: fixture.now
    )
    stale.phase = .redeeming

    _ = try await persistence.setProfileEnabled(profile.id, enabled: false)
    _ = try await persistence.saveMonitorState(stale)
    let stored = try await persistence.snapshot()

    #expect(stored.profiles.first { $0.id == profile.id }?.isEnabled == false)
    #expect(stored.monitorState(for: profile.id)?.isEnabled == false)
    #expect(stored.monitorState(for: profile.id)?.phase == .disabled)
    #expect(stored.monitorState(for: profile.id)?.attempt == nil)
}

@Test func requestStartedCompareAndSwapRejectsConcurrentDisable() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let persistence = MonitorPersistence(
        stateFileURL: fixture.stateURL,
        profilesDirectory: fixture.profilesURL
    )
    let initial = try await persistence.loadOrBootstrap()
    let profile = initial.profiles[0]
    let stale = initial.monitorState(for: profile.id)!
    _ = try await persistence.setProfileEnabled(profile.id, enabled: false)

    do {
        _ = try await persistence.saveMonitorState(
            stale,
            expectedRevision: initial.revision ?? 0
        )
        Issue.record("Expected the stale compare-and-swap to fail")
    } catch let error as MonitorPersistenceError {
        guard case .concurrentModification = error else {
            Issue.record(error)
            return
        }
    }
}

@Test func persistenceRejectsAttemptBelongingToAnotherProfile() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let persistence = MonitorPersistence(
        stateFileURL: fixture.stateURL,
        profilesDirectory: fixture.profilesURL
    )
    let initial = try await persistence.loadOrBootstrap()
    let profile = initial.profiles[0]
    var state = initial.monitorState(for: profile.id)!
    state.attempt = RedemptionAttempt(
        profileID: GuardPersistentState.key(for: initial.profiles[1].id),
        idempotencyKey: "swapped",
        creditID: nil,
        weeklyResetAtBefore: fixture.now.addingTimeInterval(86_400),
        weeklyUsedPercentBefore: 100,
        availableCreditCountBefore: 1,
        preparedAt: fixture.now
    )

    do {
        _ = try await persistence.saveMonitorState(state)
        Issue.record("Expected a cross-profile attempt to be rejected")
    } catch let error as MonitorPersistenceError {
        #expect(error == .invalidMonitorState(profile.id))
    }
}

@Test func pollingScheduleIsAdaptiveAndWeeklyThresholdFocused() {
    #expect(
        GuardPollingSchedule.interval(
            remainingPercent: 75,
            phase: .healthy,
            connectionStatus: .verified
        ) == 60
    )
    #expect(
        GuardPollingSchedule.interval(
            remainingPercent: 8,
            phase: .nearLimit,
            connectionStatus: .verified
        ) == 15
    )
    #expect(
        GuardPollingSchedule.interval(
            remainingPercent: 3,
            phase: .confirming,
            connectionStatus: .verified
        ) == 5
    )
    #expect(
        GuardPollingSchedule.interval(
            remainingPercent: 0,
            phase: .confirming,
            connectionStatus: .authenticationRequired
        ) == 60
    )
}

@Test func runtimeEnrollmentRequiresConnectAndExplicitOptIn() async throws {
    let fixture = try RuntimeFixture(seedProfiles: false)
    defer { fixture.remove() }
    let persistence = MonitorPersistence(stateFileURL: fixture.stateURL, profilesDirectory: fixture.profilesURL)
    let factoryCalls = LockedCounter()
    let session = DiagnosticGuardSession(email: "new@example.com", now: fixture.now)
    let controller = GuardRuntimeController(
        configuration: runtimeConfiguration(fixture),
        persistence: persistence,
        eventLog: RedactedEventLog(fileURL: fixture.eventsURL),
        sessionFactory: { _ in factoryCalls.increment(); return session },
        now: { fixture.now }
    )
    #expect(try await controller.start().profiles.isEmpty)
    let enrolled = try await controller.addProfile(expectedEmail: "new@example.com", displayName: "New")
    let profile = try #require(enrolled.profiles.first)
    #expect(profile.connectionStatus == .authenticationRequired)
    #expect(!profile.autoResetEnabled)
    _ = await controller.checkNow()
    #expect(factoryCalls.value == 0)
    do {
        _ = try await controller.setEnabled(profileID: profile.id, enabled: true)
        Issue.record("Enabling before Connect must fail")
    } catch let error as GuardRuntimeError {
        #expect(error == .authenticationRequired)
    }
    _ = try await controller.beginConnection(profileID: profile.id)
    _ = await controller.checkNow()
    #expect(await eventually { await controller.snapshot().profiles.first?.connectionStatus == .verified })
    #expect(try await persistence.snapshot().profiles.first?.isEnabled == false)
    #expect(await session.consumeCount() == 0)
    _ = try await controller.setEnabled(profileID: profile.id, enabled: true)
    #expect(try await persistence.snapshot().profiles.first?.isEnabled == true)
    await controller.stop()
}

@Test(arguments: [MonitorPersistenceTestingFault.beforeAddProfileWrite, .afterAddProfileWrite])
func enrollmentFailureCannotStartSessionOrEnableRedemption(fault: MonitorPersistenceTestingFault) async throws {
    let fixture = try RuntimeFixture(seedProfiles: false)
    defer { fixture.remove() }
    let persistence = MonitorPersistence(stateFileURL: fixture.stateURL, profilesDirectory: fixture.profilesURL)
    let factoryCalls = LockedCounter()
    let session = DiagnosticGuardSession(email: "new@example.com", now: fixture.now)
    let controller = GuardRuntimeController(
        configuration: runtimeConfiguration(fixture),
        persistence: persistence,
        eventLog: RedactedEventLog(fileURL: fixture.eventsURL),
        sessionFactory: { _ in factoryCalls.increment(); return session },
        now: { fixture.now }
    )
    _ = try await controller.start()
    await persistence.injectTestingFault(fault)
    do {
        _ = try await controller.addProfile(expectedEmail: "new@example.com", displayName: "New")
        Issue.record("Expected injected enrollment failure")
    } catch {
        // Both before-rename and ambiguous after-rename errors must leave redemption off.
    }
    let stored = try await persistence.snapshot()
    let snapshot = await controller.snapshot()
    let expectedCount = fault == .afterAddProfileWrite ? 1 : 0
    #expect(stored.profiles.count == expectedCount)
    #expect(snapshot.profiles.count == expectedCount)
    #expect(stored.profiles.allSatisfy { !$0.isEnabled })
    #expect(snapshot.profiles.allSatisfy { !$0.autoResetEnabled })
    #expect(factoryCalls.value == 0)
    #expect(await session.consumeCount() == 0)
    await controller.stop()
}

@Test func concurrentEnrollmentRejectsDuplicateIdentity() async throws {
    let fixture = try RuntimeFixture(seedProfiles: false)
    defer { fixture.remove() }
    let persistence = MonitorPersistence(stateFileURL: fixture.stateURL, profilesDirectory: fixture.profilesURL)
    _ = try await persistence.loadOrBootstrap()
    await withTaskGroup(of: Void.self) { group in
        for email in ["new@example.com", " NEW@EXAMPLE.COM "] {
            group.addTask {
                _ = try? await persistence.addProfile(expectedEmail: email, displayName: "New")
            }
        }
    }
    #expect(try await persistence.snapshot().profiles.count == 1)
}

@Test(arguments: [FailedPauseAction.disable, .reconnect])
private func laterPauseSupersedesEnableWaitingForIdentity(action: FailedPauseAction) async throws {
    let fixture = try RuntimeFixture(emails: ["first@example.com"])
    defer { fixture.remove() }
    let persistence = MonitorPersistence(stateFileURL: fixture.stateURL, profilesDirectory: fixture.profilesURL)
    let profileID = try #require(try await persistence.snapshot().profiles.first?.id)
    _ = try await persistence.setProfileEnabled(profileID, enabled: false)
    let clock = LockedTestClock(fixture.now)
    let session = RuntimeGuardSession(
        email: fixture.emails[0], clock: clock, weeklyUsedPercent: 98,
        resetAt: fixture.now.addingTimeInterval(86_400), blockAccountReadNumber: 2
    )
    let controller = makeRuntimeController(
        fixture: fixture, persistence: persistence, sessions: [fixture.emails[0]: session], clock: clock
    )
    _ = try await controller.start()
    #expect(await eventually { await session.rateReadCount() == 1 })
    #expect(await eventually { !(await controller.snapshot()).isChecking })
    let enable = Task { try await controller.setEnabled(profileID: profileID, enabled: true) }
    #expect(await eventually { await session.isAccountReadBlocked() })
    switch action {
    case .disable: _ = try await controller.setEnabled(profileID: profileID, enabled: false)
    case .reconnect: _ = try await controller.beginConnection(profileID: profileID)
    }
    await session.releaseBlockedAccountRead()
    do {
        _ = try await enable.value
        Issue.record("The older enable must not overwrite the later pause")
    } catch let error as GuardRuntimeError {
        #expect(error == .settingSuperseded)
    }
    #expect(try await persistence.snapshot().profiles.first?.isEnabled == false)
    #expect(try await persistence.snapshot().monitorState(for: profileID)?.isEnabled == false)
    #expect(await controller.snapshot().profiles.first?.autoResetEnabled == false)
    clock.advance(by: 5)
    _ = await controller.checkNow()
    #expect(await session.consumeCount() == 0)
    await controller.stop()
}

@Test func enableCommitCannotOverwriteANewerDurablePause() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let persistence = MonitorPersistence(stateFileURL: fixture.stateURL, profilesDirectory: fixture.profilesURL)
    let original = try await persistence.snapshot()
    let profileID = original.profiles[0].id
    _ = try await persistence.setProfileEnabled(profileID, enabled: false)
    do {
        _ = try await persistence.setProfileEnabled(
            profileID, enabled: true, expectedRevision: original.revision ?? 0
        )
        Issue.record("Expected the stale enable commit to fail")
    } catch let error as MonitorPersistenceError {
        guard case .concurrentModification = error else {
            Issue.record(error)
            return
        }
    }
    #expect(try await persistence.snapshot().profiles[0].isEnabled == false)
}

@Test @MainActor func previewActionsCannotInvokeLiveCallbacks() {
    let model = PreviewFixtures.model(for: .healthy)
    var liveCalls = 0
    model.onCheckNow = { liveCalls += 1 }
    model.onReconnect = { _ in liveCalls += 1 }
    model.onToggleAutoReset = { _, _ in liveCalls += 1 }
    model.onAddProfile = { _, _ in liveCalls += 1 }
    model.profileEmail = "new@example.com"
    model.checkNow()
    model.reconnect(profileID: model.profiles[0].id)
    model.setAutoReset(profileID: model.profiles[0].id, enabled: false)
    model.addProfile()
    #expect(liveCalls == 0)
    #expect(!model.isAddingProfile)
}

@Test @MainActor func readOnlyModelCannotEnableAutomaticRedemption() {
    let profiles = PreviewFixtures.model(for: .paused).profiles
    let model = GuardAppModel(profiles: profiles, isReadOnly: true)
    var toggleCalled = false
    model.onToggleAutoReset = { _, _ in toggleCalled = true }
    model.setAutoReset(profileID: profiles[0].id, enabled: true)
    #expect(!toggleCalled)
    #expect(!model.profiles[0].autoResetEnabled)
}

@Test func runtimeSafetyGateRequiresCanonicalWeeklyDurationAndTwoFreshReadings() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let resetAt = now.addingTimeInterval(4 * 24 * 60 * 60)
    let credit = ResetCredit(
        id: "credit-1",
        kind: .codexRateLimits,
        status: .available,
        grantedAt: now.addingTimeInterval(-100),
        expiresAt: now.addingTimeInterval(10_000)
    )
    let inventory = ResetCreditInventory(availableCount: 1, credits: [credit])
    let attempt = RedemptionAttempt(
        profileID: "profile",
        idempotencyKey: "durable-key",
        creditID: credit.id,
        weeklyResetAtBefore: resetAt,
        weeklyUsedPercentBefore: 97,
        availableCreditCountBefore: 1,
        preparedAt: now
    )
    var state = MonitorState(profileID: "profile")
    state.confirmation = ThresholdConfirmation(
        weeklyResetAt: resetAt,
        count: 2,
        lastObservedAt: now,
        lastRemainingPercent: 3,
        firstObservedAt: now.addingTimeInterval(-5)
    )
    state.attempt = attempt
    let weekly = CanonicalWeeklyLimit(
        lane: .secondary,
        usedPercent: 97,
        durationMinutes: 10_080,
        resetsAt: resetAt,
        observedAt: now
    )

    #expect(
        GuardRedemptionSafetyGate.allowsConsume(
            weeklyLimit: weekly,
            inventory: inventory,
            state: state,
            attempt: attempt,
            policy: ResetPolicyEngine(),
            now: now
        )
    )

    var stalePair = state
    stalePair.confirmation?.firstObservedAt = now.addingTimeInterval(-121)
    #expect(!GuardRedemptionSafetyGate.allowsConsume(
        weeklyLimit: weekly, inventory: inventory, state: stalePair, attempt: attempt,
        policy: ResetPolicyEngine(), now: now
    ))
    var retry = attempt
    retry.phase = .retryable
    #expect(GuardRedemptionSafetyGate.allowsConsume(
        weeklyLimit: weekly, inventory: inventory, state: stalePair, attempt: retry,
        policy: ResetPolicyEngine(), now: now
    ))
    #expect(retry.idempotencyKey == attempt.idempotencyKey)
    stalePair.confirmation?.firstObservedAt = nil
    #expect(!GuardRedemptionSafetyGate.allowsConsume(
        weeklyLimit: weekly, inventory: inventory, state: stalePair, attempt: attempt,
        policy: ResetPolicyEngine(), now: now
    ))

    var fiveHour = weekly
    fiveHour.durationMinutes = 300
    #expect(
        !GuardRedemptionSafetyGate.allowsConsume(
            weeklyLimit: fiveHour,
            inventory: inventory,
            state: state,
            attempt: attempt,
            policy: ResetPolicyEngine(),
            now: now
        )
    )

    state.confirmation?.count = 1
    #expect(
        !GuardRedemptionSafetyGate.allowsConsume(
            weeklyLimit: weekly,
            inventory: inventory,
            state: state,
            attempt: attempt,
            policy: ResetPolicyEngine(),
            now: now
        )
    )

    state.confirmation?.count = 2
    var nearNaturalReset = weekly
    nearNaturalReset.resetsAt = now.addingTimeInterval(299)
    var nearAttempt = attempt
    nearAttempt.weeklyResetAtBefore = nearNaturalReset.resetsAt
    state.confirmation?.weeklyResetAt = nearNaturalReset.resetsAt
    state.attempt = nearAttempt
    #expect(
        !GuardRedemptionSafetyGate.allowsConsume(
            weeklyLimit: nearNaturalReset,
            inventory: inventory,
            state: state,
            attempt: nearAttempt,
            policy: ResetPolicyEngine(),
            now: now
        )
    )

    state.confirmation?.weeklyResetAt = resetAt
    state.attempt = attempt
    var swappedAttempt = attempt
    swappedAttempt.profileID = "another-profile"
    #expect(
        !GuardRedemptionSafetyGate.allowsConsume(
            weeklyLimit: weekly,
            inventory: inventory,
            state: state,
            attempt: swappedAttempt,
            policy: ResetPolicyEngine(),
            now: now
        )
    )
}

@Test func productionConfiguredDiagnosisCanNeverConsume() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let sessions = Dictionary(uniqueKeysWithValues: fixture.emails.map { email in
        (email, DiagnosticGuardSession(email: email, now: fixture.now))
    })
    let persistence = MonitorPersistence(
        stateFileURL: fixture.stateURL,
        profilesDirectory: fixture.profilesURL
    )
    _ = try await persistence.loadOrBootstrap(
        now: fixture.now
    )
    let eventLog = RedactedEventLog(fileURL: fixture.eventsURL)
    let configuration = GuardRuntimeConfiguration(
        operationMode: .production,
        codexExecutableURL: URL(fileURLWithPath: "/does/not/run/in-this-test"),
        applicationSupportDirectory: fixture.root,
        profilesDirectory: fixture.profilesURL
    )
    let controller = GuardRuntimeController(
        configuration: configuration,
        persistence: persistence,
        eventLog: eventLog,
        sessionFactory: { profile in
            guard let email = profile.expectedEmail, let session = sessions[email] else {
                throw GuardRuntimeError.missingExpectedIdentity
            }
            return session
        },
        now: { fixture.now }
    )

    let first = try await controller.diagnose()
    let second = try await controller.diagnose()

    #expect(first.profiles.count == 2)
    #expect(second.profiles.allSatisfy { $0.connectionStatus == .verified })
    #expect(second.profiles.allSatisfy { $0.weeklyRemainingPercent == 3 })
    for session in sessions.values {
        #expect(await session.consumeCount() == 0)
    }
}

@Test func readOnlyMonitoringCannotConsumeAnArmedReset() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let clock = LockedTestClock(fixture.now)
    let resetAt = fixture.now.addingTimeInterval(86_400)
    let (persistence, _) = try await armedPersistence(fixture: fixture, resetAt: resetAt)
    let sessions = Dictionary(uniqueKeysWithValues: fixture.emails.map { email in
        (email, RuntimeGuardSession(email: email, clock: clock, weeklyUsedPercent: 98, resetAt: resetAt))
    })
    var configuration = runtimeConfiguration(fixture)
    configuration.operationMode = .readOnly
    let controller = GuardRuntimeController(
        configuration: configuration,
        persistence: persistence,
        sessionFactory: { profile in sessions[profile.expectedEmail!]! },
        now: { clock.value }
    )
    _ = try await controller.start()
    #expect(await eventually { !(await controller.snapshot()).isChecking })
    for _ in 0..<3 {
        clock.advance(by: 10)
        _ = await controller.checkNow()
    }
    #expect(await controller.snapshot().profiles.allSatisfy { $0.connectionStatus == .verified })
    for session in sessions.values {
        #expect(await session.consumeCount() == 0)
    }
    await controller.stop()
}

@Test func diagnosisWithInjectedSessionsLeavesPolicyAndEventFilesUnchanged() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let persistence = MonitorPersistence(
        stateFileURL: fixture.stateURL,
        profilesDirectory: fixture.profilesURL
    )
    _ = try await persistence.loadOrBootstrap(
        now: fixture.now
    )
    let before = try policyAndEventSnapshot(fixture)
    let successfulSessions = Dictionary(uniqueKeysWithValues: fixture.emails.map { email in
        (email, DiagnosticGuardSession(email: email, now: fixture.now))
    })
    let successful = GuardRuntimeController(
        configuration: runtimeConfiguration(fixture),
        persistence: persistence,
        eventLog: RedactedEventLog(fileURL: fixture.eventsURL),
        sessionFactory: { profile in successfulSessions[profile.expectedEmail!]! },
        now: { fixture.now }
    )
    _ = try await successful.diagnose()
    #expect(try policyAndEventSnapshot(fixture) == before)

    let clock = LockedTestClock(fixture.now)
    let failingSessions = Dictionary(uniqueKeysWithValues: fixture.emails.map { expectedEmail in
        (
            expectedEmail,
            RuntimeGuardSession(
                email: "wrong@example.com",
                clock: clock,
                weeklyUsedPercent: 98,
                resetAt: fixture.now.addingTimeInterval(86_400)
            )
        )
    })
    let failing = GuardRuntimeController(
        configuration: runtimeConfiguration(fixture),
        persistence: persistence,
        eventLog: RedactedEventLog(fileURL: fixture.eventsURL),
        sessionFactory: { profile in failingSessions[profile.expectedEmail!]! },
        now: { fixture.now }
    )
    _ = try await failing.diagnose()
    #expect(try policyAndEventSnapshot(fixture) == before)
    for session in successfulSessions.values {
        #expect(await session.consumeCount() == 0)
    }
    for session in failingSessions.values {
        #expect(await session.consumeCount() == 0)
    }
}

@Test func disablingDuringFinalIdentityCheckPreventsConsumeAndKeepsBothFlagsOff() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let clock = LockedTestClock(fixture.now)
    let resetAt = fixture.now.addingTimeInterval(86_400)
    let (persistence, profileID) = try await armedPersistence(
        fixture: fixture,
        resetAt: resetAt
    )
    let target = RuntimeGuardSession(
        email: fixture.emails[0],
        clock: clock,
        weeklyUsedPercent: 98,
        resetAt: resetAt,
        blockAccountReadNumber: 2
    )
    let healthy = RuntimeGuardSession(
        email: fixture.emails[1],
        clock: clock,
        weeklyUsedPercent: 20,
        resetAt: resetAt
    )
    let controller = makeRuntimeController(
        fixture: fixture,
        persistence: persistence,
        sessions: [fixture.emails[0]: target, fixture.emails[1]: healthy],
        clock: clock
    )

    _ = try await controller.start()
    #expect(await eventually { await target.isAccountReadBlocked() })
    _ = try await controller.setEnabled(profileID: profileID, enabled: false)
    await target.releaseBlockedAccountRead()
    #expect(await eventually { await target.rateReadCount() >= 1 })
    #expect(await target.consumeCount() == 0)

    let stored = try await persistence.snapshot()
    #expect(stored.profiles.first { $0.id == profileID }?.isEnabled == false)
    #expect(stored.monitorState(for: profileID)?.isEnabled == false)
    await controller.stop()
}

@Test func oauthReconnectPausesBeforeAwaitAndRequiresExplicitVerifiedReenable() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let clock = LockedTestClock(fixture.now)
    let resetAt = fixture.now.addingTimeInterval(86_400)
    let (persistence, profileID) = try await armedPersistence(
        fixture: fixture,
        resetAt: resetAt
    )
    let target = RuntimeGuardSession(
        email: fixture.emails[0],
        clock: clock,
        weeklyUsedPercent: 98,
        resetAt: resetAt,
        blockAccountReadNumber: 2,
        consumeScript: [.outcome(.nothingToReset)]
    )
    let healthy = RuntimeGuardSession(
        email: fixture.emails[1],
        clock: clock,
        weeklyUsedPercent: 20,
        resetAt: resetAt,
        blockAccountReadNumber: 2
    )
    let controller = makeRuntimeController(
        fixture: fixture,
        persistence: persistence,
        sessions: [fixture.emails[0]: target, fixture.emails[1]: healthy],
        clock: clock
    )

    _ = try await controller.start()
    #expect(await eventually { await target.isAccountReadBlocked() })
    _ = try await controller.beginConnection(profileID: profileID)
    await target.setEmail("wrong-account@example.com")
    await target.releaseBlockedAccountRead()
    #expect(await eventually { !(await controller.snapshot()).isChecking })
    #expect(await target.consumeCount() == 0)
    #expect(try await persistence.snapshot().monitorState(for: profileID)?.isEnabled == false)

    await target.setEmail(fixture.emails[0])
    _ = try await controller.setEnabled(profileID: profileID, enabled: true)
    #expect(await target.consumeCount() == 0)
    clock.advance(by: 5)
    // Hold the unrelated profile's next write so this assertion measures explicit re-enable,
    // independently of whether that write would safely invalidate the redemption CAS.
    let check = Task { await controller.checkNow() }
    #expect(await eventually { await healthy.isAccountReadBlocked() })
    #expect(await eventually { await target.consumeCount() == 1 })
    await healthy.releaseBlockedAccountRead()
    _ = await check.value
    await controller.stop()
}

@Test func failedDisableBeforeStateReplacementKeepsRedemptionBlocked() async throws {
    try await assertFailedPauseKeepsRedemptionBlocked(
        fault: .beforeSetProfileEnabledWrite,
        action: .disable
    )
}

@Test func failedDisableAfterStateReplacementKeepsRedemptionBlocked() async throws {
    try await assertFailedPauseKeepsRedemptionBlocked(
        fault: .afterSetProfileEnabledWrite,
        action: .disable
    )
}

@Test func failedReconnectBeforeStateReplacementKeepsRedemptionBlocked() async throws {
    try await assertFailedPauseKeepsRedemptionBlocked(
        fault: .beforeSetProfileEnabledWrite,
        action: .reconnect
    )
}

@Test func failedReconnectAfterStateReplacementKeepsRedemptionBlocked() async throws {
    try await assertFailedPauseKeepsRedemptionBlocked(
        fault: .afterSetProfileEnabledWrite,
        action: .reconnect
    )
}

@Test func naturalWeeklyRolloverDuringFinalIdentityCheckPreventsConsume() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let clock = LockedTestClock(fixture.now)
    let resetAt = fixture.now.addingTimeInterval(10 * 60)
    let (persistence, _) = try await armedPersistence(fixture: fixture, resetAt: resetAt)
    let target = RuntimeGuardSession(
        email: fixture.emails[0],
        clock: clock,
        weeklyUsedPercent: 98,
        resetAt: resetAt,
        advanceClockOnAccountReadNumber: (2, 11 * 60)
    )
    let healthy = RuntimeGuardSession(
        email: fixture.emails[1],
        clock: clock,
        weeklyUsedPercent: 20,
        resetAt: resetAt
    )
    let controller = makeRuntimeController(
        fixture: fixture,
        persistence: persistence,
        sessions: [fixture.emails[0]: target, fixture.emails[1]: healthy],
        clock: clock
    )

    _ = try await controller.start()
    #expect(await eventually { await target.rateReadCount() >= 2 })
    #expect(await target.consumeCount() == 0)
    await controller.stop()
}

@Test func definiteRPCRejectionIsNeverRetried() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let clock = LockedTestClock(fixture.now)
    let resetAt = fixture.now.addingTimeInterval(86_400)
    let (persistence, profileID) = try await armedPersistence(fixture: fixture, resetAt: resetAt)
    let target = RuntimeGuardSession(
        email: fixture.emails[0],
        clock: clock,
        weeklyUsedPercent: 98,
        resetAt: resetAt,
        consumeScript: [.failure(.rpc(code: -32602, message: "invalid params"))]
    )
    let healthy = RuntimeGuardSession(
        email: fixture.emails[1],
        clock: clock,
        weeklyUsedPercent: 20,
        resetAt: resetAt
    )
    let controller = makeRuntimeController(
        fixture: fixture,
        persistence: persistence,
        sessions: [fixture.emails[0]: target, fixture.emails[1]: healthy],
        clock: clock
    )

    _ = try await controller.start()
    _ = await controller.checkNow()
    #expect(await eventually { !(await controller.snapshot()).isChecking })
    if await target.consumeCount() == 0 {
        // The other profile's first durable poll can invalidate the consume CAS. Settle that
        // check and drive the next fresh reading instead of waiting for a real polling timer.
        clock.advance(by: 5)
        _ = await controller.checkNow()
    }
    #expect(await eventually { await target.consumeCount() == 1 })
    #expect(await eventually { !(await controller.snapshot()).isChecking })
    _ = await controller.checkNow()
    #expect(await target.consumeCount() == 1)
    #expect(try await persistence.snapshot().monitorState(for: profileID)?.attempt?.phase == .requestRejected)
    await controller.stop()
}

@Test func droppedConsumeResponseRetriesOnlyWithTheSameDurableKey() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let clock = LockedTestClock(fixture.now)
    let resetAt = fixture.now.addingTimeInterval(86_400)
    let (persistence, _) = try await armedPersistence(fixture: fixture, resetAt: resetAt)
    let target = RuntimeGuardSession(
        email: fixture.emails[0],
        clock: clock,
        weeklyUsedPercent: 98,
        resetAt: resetAt,
        consumeScript: [
            .failure(.transportClosed),
            .outcome(.nothingToReset),
        ]
    )
    let healthy = RuntimeGuardSession(
        email: fixture.emails[1],
        clock: clock,
        weeklyUsedPercent: 20,
        resetAt: resetAt
    )
    let controller = makeRuntimeController(
        fixture: fixture,
        persistence: persistence,
        sessions: [fixture.emails[0]: target, fixture.emails[1]: healthy],
        clock: clock
    )

    _ = try await controller.start()
    // `start()` schedules the initial poll without waiting for it. An explicit check makes this
    // test independent of Swift Testing's parallel task scheduling: either it owns the first
    // check, or it observes the already-running poll and the bounded wait observes that result.
    _ = await controller.checkNow()
    #expect(await eventually(timeout: .seconds(10)) { await target.consumeCount() >= 1 })
    #expect(await eventually(timeout: .seconds(10)) { !(await controller.snapshot()).isChecking })
    #expect(await target.consumeCount() == 1)
    _ = await controller.checkNow()
    #expect(await eventually(timeout: .seconds(10)) { await target.consumeCount() == 2 })
    let keys = await target.consumedKeys()
    #expect(keys.count == 2)
    #expect(Set(keys).count == 1)
    await controller.stop()
}

@Test func stopDuringFinalIdentityCheckJoinsWorkAndPreventsConsume() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let clock = LockedTestClock(fixture.now)
    let resetAt = fixture.now.addingTimeInterval(86_400)
    let (persistence, _) = try await armedPersistence(fixture: fixture, resetAt: resetAt)
    let target = RuntimeGuardSession(
        email: fixture.emails[0],
        clock: clock,
        weeklyUsedPercent: 98,
        resetAt: resetAt,
        blockAccountReadNumber: 2
    )
    let healthy = RuntimeGuardSession(
        email: fixture.emails[1],
        clock: clock,
        weeklyUsedPercent: 20,
        resetAt: resetAt
    )
    let controller = makeRuntimeController(
        fixture: fixture,
        persistence: persistence,
        sessions: [fixture.emails[0]: target, fixture.emails[1]: healthy],
        clock: clock
    )

    _ = try await controller.start()
    #expect(await eventually { await target.isAccountReadBlocked() })
    await controller.stop()
    #expect(await target.consumeCount() == 0)
    #expect(await target.shutdownCount() == 1)
}

@Test func stopWhileInitializationIsBlockedNeverCreatesSessionsOrPolling() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let persistence = MonitorPersistence(
        stateFileURL: fixture.stateURL,
        profilesDirectory: fixture.profilesURL
    )
    let gate = AsyncTestGate()
    let factoryCalls = LockedCounter()
    let unusedSession = RuntimeGuardSession(
        email: fixture.emails[0],
        clock: LockedTestClock(fixture.now),
        weeklyUsedPercent: 20,
        resetAt: fixture.now.addingTimeInterval(86_400)
    )
    let controller = GuardRuntimeController(
        configuration: runtimeConfiguration(fixture),
        persistence: persistence,
        eventLog: RedactedEventLog(fileURL: fixture.eventsURL),
        sessionFactory: { _ in
            factoryCalls.increment()
            return unusedSession
        },
        now: { fixture.now },
        startupGate: { await gate.suspend() }
    )

    let startup = Task { try await controller.start() }
    #expect(await eventually { await gate.hasEntered() })
    await controller.stop()
    await gate.release()
    do {
        _ = try await startup.value
        Issue.record("Expected stopped startup to fail")
    } catch {
        #expect(error as? GuardRuntimeError == .runtimeStopped)
    }
    #expect(factoryCalls.value == 0)
    #expect(await unusedSession.consumeCount() == 0)
}

@Test func concurrentStopCallersBothWaitForTheSameShutdown() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let clock = LockedTestClock(fixture.now)
    let resetAt = fixture.now.addingTimeInterval(86_400)
    let persistence = MonitorPersistence(
        stateFileURL: fixture.stateURL,
        profilesDirectory: fixture.profilesURL
    )
    let target = RuntimeGuardSession(
        email: fixture.emails[0],
        clock: clock,
        weeklyUsedPercent: 20,
        resetAt: resetAt,
        blockShutdown: true
    )
    let other = RuntimeGuardSession(
        email: fixture.emails[1],
        clock: clock,
        weeklyUsedPercent: 20,
        resetAt: resetAt
    )
    let controller = makeRuntimeController(
        fixture: fixture,
        persistence: persistence,
        sessions: [fixture.emails[0]: target, fixture.emails[1]: other],
        clock: clock
    )
    _ = try await controller.start()
    let completions = LockedCounter()
    let first = Task {
        await controller.stop()
        completions.increment()
    }
    #expect(await eventually { await target.isShutdownBlocked() })
    let second = Task {
        await controller.stop()
        completions.increment()
    }
    try? await Task.sleep(for: .milliseconds(30))
    #expect(completions.value == 0)

    await target.releaseBlockedShutdown()
    await first.value
    await second.value
    #expect(completions.value == 2)
    #expect(await target.shutdownCount() == 1)
}

@Test @MainActor func liveToggleWaitsForCommittedRuntimeSnapshot() {
    let profile = GuardProfilePresentation(
        id: UUID().uuidString.lowercased(),
        displayName: "Primary",
        accountHint: "p•••@example.com",
        weeklyRemainingPercent: 50,
        naturalResetAt: nil,
        availableResetCount: 1,
        nearestResetExpiry: nil,
        status: .healthy,
        detail: "Monitoring",
        autoResetEnabled: true
    )
    let model = GuardAppModel(profiles: [profile], isPreview: false)
    var requested: Bool?
    model.onToggleAutoReset = { _, enabled in requested = enabled }

    model.setAutoReset(profileID: profile.id, enabled: false)

    #expect(requested == false)
    #expect(model.profiles[0].autoResetEnabled == true)
}

@Test func repeatedFailedReconciliationNotifiesOnceThenLateRecoveryNotifiesOnce() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let clock = LockedTestClock(fixture.now)
    let resetAt = fixture.now.addingTimeInterval(86_400)
    let persistence = MonitorPersistence(
        stateFileURL: fixture.stateURL,
        profilesDirectory: fixture.profilesURL
    )
    let initial = try await persistence.loadOrBootstrap(
        now: fixture.now
    )
    let profileID = initial.profiles[0].id
    var state = initial.monitorState(for: profileID)!
    state.phase = .verifying
    state.confirmation = ThresholdConfirmation(
        weeklyResetAt: resetAt,
        count: 2,
        lastObservedAt: fixture.now,
        lastRemainingPercent: 2,
        firstObservedAt: fixture.now.addingTimeInterval(-5)
    )
    state.attempt = RedemptionAttempt(
        profileID: state.profileID,
        idempotencyKey: "late-reconciliation",
        creditID: "runtime-credit",
        weeklyResetAtBefore: resetAt,
        weeklyUsedPercentBefore: 98,
        availableCreditCountBefore: 1,
        preparedAt: fixture.now.addingTimeInterval(-10),
        updatedAt: fixture.now,
        phase: .awaitingVerification,
        consumeOutcome: .reset
    )
    _ = try await persistence.saveMonitorState(state, now: fixture.now)
    _ = try await persistence.setProfileEnabled(initial.profiles[1].id, enabled: false)

    let target = RuntimeGuardSession(
        email: fixture.emails[0],
        clock: clock,
        weeklyUsedPercent: 98,
        resetAt: resetAt,
        creditAvailable: false
    )
    let healthy = RuntimeGuardSession(
        email: fixture.emails[1],
        clock: clock,
        weeklyUsedPercent: 20,
        resetAt: resetAt
    )
    let notifications = LockedCounter()
    let controller = makeRuntimeController(
        fixture: fixture,
        persistence: persistence,
        sessions: [fixture.emails[0]: target, fixture.emails[1]: healthy],
        clock: clock,
        notificationHandler: { _, _ in notifications.increment() }
    )

    _ = try await controller.start()
    #expect(await eventually { notifications.value == 1 })
    #expect(await eventually { !(await controller.snapshot()).isChecking })
    for _ in 0..<20 {
        _ = await controller.checkNow()
    }
    #expect(notifications.value == 1)

    await target.setWeeklyUsedPercent(0)
    _ = await controller.checkNow()
    #expect(notifications.value == 2)
    let records = try await RedactedEventLog(fileURL: fixture.eventsURL).entries()
    #expect(records.filter { $0.kind == .verificationFailed }.count == 1)
    #expect(records.filter { $0.kind == .redemptionSucceeded }.count == 1)
    await controller.stop()
}

private struct RuntimeFixture: @unchecked Sendable {
    let root: URL
    let stateURL: URL
    let eventsURL: URL
    let profilesURL: URL
    let emails: [String]
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    init(emails: [String] = ["first@example.com", "second@example.com"], seedProfiles: Bool = true) throws {
        self.emails = emails
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("guard-runtime-tests-\(UUID().uuidString)", isDirectory: true)
        stateURL = root.appendingPathComponent("state.json")
        eventsURL = root.appendingPathComponent("events.json")
        profilesURL = root.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if seedProfiles {
            // Safety regressions exercise already enrolled, explicitly enabled profiles. Fresh
            // onboarding is tested separately and never opts the user in automatically.
            let profiles = emails.enumerated().map { index, email in
                ProfileConfiguration(
                    displayName: "Test profile \(index + 1)",
                    expectedEmail: email,
                    isEnabled: true
                )
            }
            let state = GuardPersistentState(
                profiles: profiles,
                monitorStates: Dictionary(uniqueKeysWithValues: profiles.map { profile in
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
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct FileSnapshot: Equatable {
    let exists: Bool
    let modificationDate: Date?
    let data: Data?
}

private func policyAndEventSnapshot(_ fixture: RuntimeFixture) throws -> [FileSnapshot] {
    try [fixture.stateURL, fixture.eventsURL].map(fileSnapshot)
}

private func fileSnapshot(at url: URL) throws -> FileSnapshot {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.path) else {
        return FileSnapshot(exists: false, modificationDate: nil, data: nil)
    }
    let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
    return FileSnapshot(
        exists: true,
        modificationDate: values.contentModificationDate,
        data: try Data(contentsOf: url)
    )
}

private func runtimeConfiguration(_ fixture: RuntimeFixture) -> GuardRuntimeConfiguration {
    GuardRuntimeConfiguration(
        operationMode: .production,
        codexExecutableURL: URL(fileURLWithPath: "/does/not/run/in-this-test"),
        applicationSupportDirectory: fixture.root,
        profilesDirectory: fixture.profilesURL
    )
}

private enum FailedPauseAction: Sendable {
    case disable
    case reconnect
}

private func assertFailedPauseKeepsRedemptionBlocked(
    fault: MonitorPersistenceTestingFault,
    action: FailedPauseAction
) async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let clock = LockedTestClock(fixture.now)
    let resetAt = fixture.now.addingTimeInterval(86_400)
    let (persistence, profileID) = try await armedPersistence(
        fixture: fixture,
        resetAt: resetAt
    )
    let target = RuntimeGuardSession(
        email: fixture.emails[0],
        clock: clock,
        weeklyUsedPercent: 98,
        resetAt: resetAt,
        blockAccountReadNumber: 2,
        consumeScript: [.outcome(.nothingToReset)]
    )
    let healthy = RuntimeGuardSession(
        email: fixture.emails[1],
        clock: clock,
        weeklyUsedPercent: 20,
        resetAt: resetAt
    )
    let controller = makeRuntimeController(
        fixture: fixture,
        persistence: persistence,
        sessions: [fixture.emails[0]: target, fixture.emails[1]: healthy],
        clock: clock
    )

    _ = try await controller.start()
    #expect(await eventually { await target.isAccountReadBlocked() })
    await persistence.injectTestingFault(fault)
    do {
        switch action {
        case .disable:
            _ = try await controller.setEnabled(profileID: profileID, enabled: false)
        case .reconnect:
            _ = try await controller.beginConnection(profileID: profileID)
        }
        Issue.record("Expected the injected persistence failure")
    } catch {
        // The injected failure is the condition under test.
    }

    await target.releaseBlockedAccountRead()
    #expect(await eventually { !(await controller.snapshot()).isChecking })
    #expect(await target.consumeCount() == 0)

    // The stop remains active across future checks; merely observing an old enabled state after a
    // pre-replacement failure cannot reopen the network boundary.
    clock.advance(by: 5)
    _ = await controller.checkNow()
    #expect(await target.consumeCount() == 0)

    // Only an explicit enable that returns successfully may clear the in-memory interlock.
    _ = try await controller.setEnabled(profileID: profileID, enabled: true)
    #expect(await eventually(timeout: .seconds(10)) {
        // Drive a fresh, sufficiently separated reading even if the background poll briefly won
        // the check-in-flight race under the parallel test runner.
        clock.advance(by: 5)
        _ = await controller.checkNow()
        return await target.consumeCount() >= 1
    })
    #expect(await target.consumeCount() == 1)
    await controller.stop()
}

private func armedPersistence(
    fixture: RuntimeFixture,
    resetAt: Date
) async throws -> (MonitorPersistence, UUID) {
    let persistence = MonitorPersistence(
        stateFileURL: fixture.stateURL,
        profilesDirectory: fixture.profilesURL
    )
    let initial = try await persistence.loadOrBootstrap(
        now: fixture.now
    )
    let profileID = initial.profiles[0].id
    var state = initial.monitorState(for: profileID)!
    state.phase = .confirming
    state.confirmation = ThresholdConfirmation(
        weeklyResetAt: resetAt,
        count: 1,
        lastObservedAt: fixture.now.addingTimeInterval(-5),
        lastRemainingPercent: 2,
        firstObservedAt: fixture.now.addingTimeInterval(-5)
    )
    _ = try await persistence.saveMonitorState(state, now: fixture.now)
    _ = try await persistence.setProfileEnabled(
        initial.profiles[1].id,
        enabled: false,
        now: fixture.now
    )
    return (persistence, profileID)
}

private func makeRuntimeController(
    fixture: RuntimeFixture,
    persistence: MonitorPersistence,
    sessions: [String: RuntimeGuardSession],
    clock: LockedTestClock,
    notificationHandler: @escaping GuardRuntimeNotificationHandler = { _, _ in }
) -> GuardRuntimeController {
    GuardRuntimeController(
        configuration: runtimeConfiguration(fixture),
        persistence: persistence,
        eventLog: RedactedEventLog(fileURL: fixture.eventsURL),
        sessionFactory: { profile in
            guard let email = profile.expectedEmail, let session = sessions[email] else {
                throw GuardRuntimeError.missingExpectedIdentity
            }
            return session
        },
        now: { clock.value },
        notificationHandler: notificationHandler
    )
}

private func eventually(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

private final class LockedTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Date

    init(_ value: Date) {
        storedValue = value
    }

    var value: Date {
        lock.withLock { storedValue }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { storedValue = storedValue.addingTimeInterval(interval) }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int { lock.withLock { storedValue } }

    func increment() {
        lock.withLock { storedValue += 1 }
    }
}

private actor AsyncTestGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func hasEntered() -> Bool { entered }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private enum ScriptedConsume: Sendable {
    case outcome(RPCConsumeResetOutcome)
    case failure(AppServerClientError)
}

private actor RuntimeGuardSession: GuardAppServerSession {
    private var email: String
    private let clock: LockedTestClock
    private var weeklyUsedPercent: Int
    private let resetAt: Date
    private var creditAvailable: Bool
    private let blockAccountReadNumber: Int?
    private let blockShutdown: Bool
    private var advanceClockOnAccountReadNumber: (number: Int, seconds: TimeInterval)?
    private var consumeScript: [ScriptedConsume]
    private var accountReads = 0
    private var rateReads = 0
    private var consumeKeys: [String] = []
    private var shutdowns = 0
    private var blocked = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var shutdownBlocked = false
    private var shutdownContinuation: CheckedContinuation<Void, Never>?

    init(
        email: String,
        clock: LockedTestClock,
        weeklyUsedPercent: Int,
        resetAt: Date,
        creditAvailable: Bool = true,
        blockAccountReadNumber: Int? = nil,
        blockShutdown: Bool = false,
        advanceClockOnAccountReadNumber: (Int, TimeInterval)? = nil,
        consumeScript: [ScriptedConsume] = [.outcome(.nothingToReset)]
    ) {
        self.email = email
        self.clock = clock
        self.weeklyUsedPercent = weeklyUsedPercent
        self.resetAt = resetAt
        self.creditAvailable = creditAvailable
        self.blockAccountReadNumber = blockAccountReadNumber
        self.blockShutdown = blockShutdown
        self.advanceClockOnAccountReadNumber = advanceClockOnAccountReadNumber
        self.consumeScript = consumeScript
    }

    func start() async throws {}

    func shutdown() async {
        shutdowns += 1
        blockedContinuation?.resume()
        blockedContinuation = nil
        blocked = false
        if blockShutdown {
            shutdownBlocked = true
            await withCheckedContinuation { shutdownContinuation = $0 }
            shutdownBlocked = false
        }
    }

    func notifications() async -> AsyncStream<AppServerNotification> {
        AsyncStream { continuation in continuation.finish() }
    }

    func accountRead(refreshToken: Bool) async throws -> RPCAccountReadResponse {
        accountReads += 1
        if let advance = advanceClockOnAccountReadNumber,
           advance.number == accountReads {
            clock.advance(by: advance.seconds)
            advanceClockOnAccountReadNumber = nil
        }
        if blockAccountReadNumber == accountReads {
            blocked = true
            await withCheckedContinuation { blockedContinuation = $0 }
            blocked = false
        }
        return RPCAccountReadResponse(
            account: RPCAccountSummary(type: "chatgpt", email: email, planType: "pro"),
            requiresOpenaiAuth: true
        )
    }

    func startChatGPTLogin(
        useHostedLoginSuccessPage: Bool,
        appBrand: String
    ) async throws -> RPCChatGPTLoginStartResponse {
        RPCChatGPTLoginStartResponse(
            loginID: "runtime-fixture-login",
            authURL: URL(string: "https://example.com/login")!
        )
    }

    func readRateLimits() async throws -> RPCRateLimitsReadResponse {
        rateReads += 1
        let current = clock.value
        let snapshot = RPCRateLimitSnapshot(
            limitID: "codex",
            limitName: nil,
            primary: RPCRateLimitWindow(
                usedPercent: 100,
                windowDurationMinutes: 300,
                resetsAt: Int64(current.addingTimeInterval(3_600).timeIntervalSince1970)
            ),
            secondary: RPCRateLimitWindow(
                usedPercent: weeklyUsedPercent,
                windowDurationMinutes: 10_080,
                resetsAt: Int64(resetAt.timeIntervalSince1970)
            )
        )
        let credits = creditAvailable ? [
            RPCResetCredit(
                id: "runtime-credit",
                resetType: "codexRateLimits",
                status: "available",
                grantedAt: Int64(current.addingTimeInterval(-60).timeIntervalSince1970),
                expiresAt: Int64(current.addingTimeInterval(86_400).timeIntervalSince1970),
                title: nil,
                detail: nil
            ),
        ] : []
        return RPCRateLimitsReadResponse(
            rateLimits: snapshot,
            rateLimitsByLimitID: ["codex": snapshot],
            rateLimitResetCredits: RPCResetCreditsSummary(
                availableCount: creditAvailable ? 1 : 0,
                credits: credits
            )
        )
    }

    func consumeReset(idempotencyKey: String, creditID: String?) async throws
        -> RPCConsumeResetOutcome
    {
        consumeKeys.append(idempotencyKey)
        let next = consumeScript.isEmpty ? ScriptedConsume.outcome(.nothingToReset) : consumeScript.removeFirst()
        switch next {
        case let .outcome(outcome): return outcome
        case let .failure(error): throw error
        }
    }

    func setEmail(_ value: String) { email = value }
    func setWeeklyUsedPercent(_ value: Int) { weeklyUsedPercent = value }
    func setCreditAvailable(_ value: Bool) { creditAvailable = value }
    func isAccountReadBlocked() -> Bool { blocked }
    func releaseBlockedAccountRead() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
    func rateReadCount() -> Int { rateReads }
    func consumeCount() -> Int { consumeKeys.count }
    func consumedKeys() -> [String] { consumeKeys }
    func shutdownCount() -> Int { shutdowns }
    func isShutdownBlocked() -> Bool { shutdownBlocked }
    func releaseBlockedShutdown() {
        shutdownContinuation?.resume()
        shutdownContinuation = nil
    }
}

private actor DiagnosticGuardSession: GuardAppServerSession {
    let email: String
    let now: Date
    private var consumes = 0

    init(email: String, now: Date) {
        self.email = email
        self.now = now
    }

    func start() async throws {}
    func shutdown() async {}
    func notifications() async -> AsyncStream<AppServerNotification> {
        AsyncStream { continuation in continuation.finish() }
    }
    func accountRead(refreshToken: Bool) async throws -> RPCAccountReadResponse {
        RPCAccountReadResponse(
            account: RPCAccountSummary(type: "chatgpt", email: email, planType: "pro"),
            requiresOpenaiAuth: true
        )
    }
    func startChatGPTLogin(
        useHostedLoginSuccessPage: Bool,
        appBrand: String
    ) async throws -> RPCChatGPTLoginStartResponse {
        RPCChatGPTLoginStartResponse(
            loginID: "fixture-login",
            authURL: URL(string: "https://example.com/login")!
        )
    }
    func readRateLimits() async throws -> RPCRateLimitsReadResponse {
        let resetsAt = Int64(now.addingTimeInterval(4 * 24 * 60 * 60).timeIntervalSince1970)
        let snapshot = RPCRateLimitSnapshot(
            limitID: "codex",
            limitName: nil,
            primary: RPCRateLimitWindow(
                usedPercent: 100,
                windowDurationMinutes: 300,
                resetsAt: Int64(now.addingTimeInterval(60 * 60).timeIntervalSince1970)
            ),
            secondary: RPCRateLimitWindow(
                usedPercent: 97,
                windowDurationMinutes: 10_080,
                resetsAt: resetsAt
            )
        )
        return RPCRateLimitsReadResponse(
            rateLimits: snapshot,
            rateLimitsByLimitID: ["codex": snapshot],
            rateLimitResetCredits: RPCResetCreditsSummary(
                availableCount: 1,
                credits: nil
            )
        )
    }
    func consumeReset(idempotencyKey: String, creditID: String?) async throws
        -> RPCConsumeResetOutcome
    {
        consumes += 1
        return .reset
    }
    func consumeCount() -> Int { consumes }
}

@Test(arguments: [AppServerClientError.shutDown, .transportClosed])
func shutdownErrorsKeepTheDurableAttempt(error: AppServerClientError) async throws {
    let fixture = try RuntimeFixture(emails: ["only@example.com"])
    defer { fixture.remove() }
    let clock = LockedTestClock(fixture.now)
    let resetAt = fixture.now.addingTimeInterval(86_400)
    let persistence = MonitorPersistence(stateFileURL: fixture.stateURL, profilesDirectory: fixture.profilesURL)
    let initial = try await persistence.loadOrBootstrap(now: fixture.now)
    let profileID = try #require(initial.profiles.first?.id)
    var state = try #require(initial.monitorState(for: profileID))
    state.confirmation = ThresholdConfirmation(
        weeklyResetAt: resetAt, count: 1,
        lastObservedAt: fixture.now.addingTimeInterval(-5), lastRemainingPercent: 2,
        firstObservedAt: fixture.now.addingTimeInterval(-5)
    )
    _ = try await persistence.saveMonitorState(state, now: fixture.now)
    let session = RuntimeGuardSession(
        email: fixture.emails[0], clock: clock, weeklyUsedPercent: 98,
        resetAt: resetAt, consumeScript: [.failure(error)]
    )
    let controller = makeRuntimeController(
        fixture: fixture, persistence: persistence,
        sessions: [fixture.emails[0]: session], clock: clock
    )
    _ = try await controller.start()
    #expect(await eventually {
        let count = await session.consumeCount()
        let snapshot = await controller.snapshot()
        return count == 1 && !snapshot.isChecking
    })
    let beforePause = try await persistence.snapshot()
    let key = try #require(beforePause.monitorState(for: profileID)?.attempt?.idempotencyKey)
    #expect(beforePause.monitorState(for: profileID)?.attempt?.phase == .retryable)
    _ = try await controller.setEnabled(profileID: profileID, enabled: false)
    #expect(try await persistence.snapshot().monitorState(for: profileID)?.attempt?.idempotencyKey == key)
    _ = await controller.checkNow()
    #expect(await session.consumeCount() == 1)
    await controller.stop()
}

private enum WriteDelayScenario: Equatable, Sendable {
    case oldestConfirmation
    case naturalReset
}

@Test(arguments: [WriteDelayScenario.oldestConfirmation, .naturalReset])
private func requestStartedWriteDelayRechecksSafety(scenario: WriteDelayScenario) async throws {
    let fixture = try RuntimeFixture(emails: ["only@example.com"])
    defer { fixture.remove() }
    let clock = LockedTestClock(fixture.now)
    let delay: TimeInterval = scenario == .oldestConfirmation ? 116 : 2
    let resetAt = fixture.now.addingTimeInterval(scenario == .oldestConfirmation ? 86_400 : 301)
    let persistence = MonitorPersistence(
        stateFileURL: fixture.stateURL, profilesDirectory: fixture.profilesURL,
        afterMonitorStateWrite: { state in
            if state.attempt?.phase == .requestInFlight { clock.advance(by: delay) }
        }
    )
    let initial = try await persistence.loadOrBootstrap(now: fixture.now)
    let profileID = try #require(initial.profiles.first?.id)
    var state = try #require(initial.monitorState(for: profileID))
    state.confirmation = ThresholdConfirmation(
        weeklyResetAt: resetAt, count: 1,
        lastObservedAt: fixture.now.addingTimeInterval(-5), lastRemainingPercent: 2,
        firstObservedAt: fixture.now.addingTimeInterval(-5)
    )
    _ = try await persistence.saveMonitorState(state, now: fixture.now)
    let session = RuntimeGuardSession(
        email: fixture.emails[0], clock: clock, weeklyUsedPercent: 98, resetAt: resetAt
    )
    let controller = makeRuntimeController(
        fixture: fixture, persistence: persistence,
        sessions: [fixture.emails[0]: session], clock: clock
    )
    _ = try await controller.start()
    #expect(await eventually {
        let reads = await session.rateReadCount()
        let snapshot = await controller.snapshot()
        return reads >= 2 && !snapshot.isChecking
    })
    #expect(clock.value == fixture.now.addingTimeInterval(delay))
    #expect(await session.consumeCount() == 0)
    let stopped = try await persistence.snapshot()
    #expect(stopped.monitorState(for: profileID)?.attempt?.phase == .verificationFailed)
    let retainedKey = try #require(stopped.monitorState(for: profileID)?.attempt?.idempotencyKey)
    _ = await controller.checkNow()
    #expect(await session.consumeCount() == 0)
    #expect(try await persistence.snapshot().monitorState(for: profileID)?.attempt?.idempotencyKey == retainedKey)
    await controller.stop()
}

@Test func recoveredChecksClearOnlyTheirOwnBanner() async throws {
    let fixture = try RuntimeFixture()
    defer { fixture.remove() }
    let clock = LockedTestClock(fixture.now)
    let persistence = MonitorPersistence(stateFileURL: fixture.stateURL, profilesDirectory: fixture.profilesURL)
    let first = RuntimeGuardSession(
        email: fixture.emails[0], clock: clock, weeklyUsedPercent: 20,
        resetAt: fixture.now.addingTimeInterval(86_400)
    )
    let second = RuntimeGuardSession(
        email: fixture.emails[1], clock: clock, weeklyUsedPercent: 20,
        resetAt: fixture.now.addingTimeInterval(86_400)
    )
    let controller = makeRuntimeController(
        fixture: fixture, persistence: persistence,
        sessions: [fixture.emails[0]: first, fixture.emails[1]: second], clock: clock
    )
    _ = try await controller.start()
    #expect(await eventually {
        let firstReads = await first.rateReadCount()
        let secondReads = await second.rateReadCount()
        let snapshot = await controller.snapshot()
        return firstReads > 0 && secondReads > 0 && !snapshot.isChecking
    })
    await first.setEmail("wrong-first@example.com")
    await second.setEmail("wrong-second@example.com")
    _ = await controller.checkNow()
    #expect(await controller.snapshot().banner != nil)
    await first.setEmail(fixture.emails[0])
    _ = await controller.checkNow()
    #expect(await controller.snapshot().banner != nil)
    await second.setEmail(fixture.emails[1])
    _ = await controller.checkNow()
    #expect(await controller.snapshot().banner == nil)
    #expect(await first.consumeCount() == 0)
    #expect(await second.consumeCount() == 0)
    await controller.stop()
}
