import Foundation
import Testing
@testable import SecondWind
@testable import SecondWindCore

// MARK: - Codex

@Test @MainActor func newlyEnrolledOnePercentWeekWarnsWithoutRequestingAReset() async throws {
    let fixture = try QuotaFixture(profiles: [])
    defer { fixture.remove() }
    let clock = QuotaClock(fixture.now)
    let session = QuotaSession(email: "new@example.com", clock: clock, sessionUsed: 0, weeklyUsed: 99)
    let controller = fixture.controller(sessions: ["new@example.com": session], clock: clock)
    _ = try await controller.start()
    let enrolled = try await controller.addProfile(expectedEmail: "new@example.com", displayName: "New")
    let profileID = try #require(enrolled.profiles.first?.id)
    _ = try await controller.beginConnection(profileID: profileID)
    await session.completeLogin()
    #expect(await eventually { await controller.snapshot().profiles.first?.connectionStatus == .verified })
    for _ in 0..<3 {
        clock.advance(by: 10)
        _ = await controller.checkNow()
    }

    let snapshot = await controller.snapshot()
    let model = GuardAppModel(referenceDate: clock.value)
    model.apply(snapshot)
    let profile = try #require(model.profiles.first)
    #expect(!profile.autoResetEnabled)
    #expect(profile.status == .nearLimit)
    #expect(profile.status.title == "Running low")
    #expect(profile.detail == "Weekly limit is running low. Turn on Auto-redeem to use a saved reset.")
    let warning = try #require(profile.quota?.reading(at: clock.value).warning)
    #expect(warning.window.kind == .weekly)
    #expect(warning.window.remainingPercent == 1)
    #expect(warning.isCurrent)
    #expect(model.minimumRemainingPercent == 1)
    #expect(await session.consumeCount() == 0)
    await controller.stop()
}

@Test @MainActor func exhaustedFiveHourWithHealthyWeekNamesTheFiveHourWindowAndNeverRedeems() async throws {
    let fixture = try QuotaFixture(profiles: [("first@example.com", true)])
    defer { fixture.remove() }
    let clock = QuotaClock(fixture.now)
    let session = QuotaSession(email: "first@example.com", clock: clock, sessionUsed: 100, weeklyUsed: 25)
    let controller = fixture.controller(sessions: ["first@example.com": session], clock: clock)
    _ = try await controller.start()
    #expect(await settled(controller, sessions: [session]))
    for _ in 0..<3 {
        clock.advance(by: 10)
        _ = await controller.checkNow()
    }

    let snapshot = await controller.snapshot()
    let model = GuardAppModel(referenceDate: clock.value)
    model.apply(snapshot)
    let profile = try #require(model.profiles.first)
    #expect(profile.autoResetEnabled)
    #expect(profile.weeklyRemainingPercent == 75)
    #expect(profile.status == .nearLimit)
    #expect(profile.detail == "5-hour limit is used up. It renews on its own.")
    #expect(model.minimumRemainingPercent == 0)
    let summary = model.quotaSummary(at: clock.value)
    #expect(summary.warnings.map(\.window.window.kind) == [.session])
    #expect(summary.warnings.first?.window.level == .exhausted)
    #expect(!summary.isAllClear)
    #expect(try await fixture.persistedPhase(snapshot.profiles[0].id) == .healthy)
    #expect(await session.consumeCount() == 0)
    await controller.stop()
}

@Test @MainActor func failedCodexAccountKeepsItsLastGoodReadingWhileTheOtherUpdates() async throws {
    let fixture = try QuotaFixture(profiles: [("first@example.com", false), ("second@example.com", false)])
    defer { fixture.remove() }
    let clock = QuotaClock(fixture.now)
    let first = QuotaSession(email: "first@example.com", clock: clock, sessionUsed: 20, weeklyUsed: 30)
    let second = QuotaSession(email: "second@example.com", clock: clock, sessionUsed: 95, weeklyUsed: 40)
    let controller = fixture.controller(
        sessions: ["first@example.com": first, "second@example.com": second],
        clock: clock
    )
    var reported: [(QuotaProvider, [QuotaAccountRecord])] = []
    let model = GuardAppModel(referenceDate: fixture.now)
    model.onQuotaRecordsChanged = { provider, records in reported.append((provider, records)) }
    _ = try await controller.start()
    #expect(await settled(controller, sessions: [first, second]))
    let readAt = clock.value
    model.apply(await controller.snapshot())
    #expect(model.quotaSummary(at: readAt).warnings.map(\.window.window.kind) == [.session])
    #expect(reported.last?.0 == .codex)
    #expect(reported.last?.1.count == 2)

    await second.setRateReadError(.transportClosed)
    clock.advance(by: 3_601)
    _ = await controller.checkNow()
    let failedAt = clock.value
    let snapshot = await controller.snapshot()
    let firstReading = snapshot.profiles[0].quota.reading(at: failedAt)
    let secondReading = snapshot.profiles[1].quota.reading(at: failedAt)

    #expect(firstReading.freshness == .fresh(lastSuccessAt: failedAt))
    #expect(firstReading.isConfirmed)
    #expect(secondReading.freshness == .failed(.unavailable, failedAt: failedAt, lastSuccessAt: readAt))
    #expect(secondReading.windows.map(\.window.remainingPercent) == [5, 60])
    #expect(secondReading.windows.allSatisfy { !$0.isCurrent })
    let passed = try #require(secondReading.windows.first { $0.window.kind == .session })
    #expect(passed.resetPassed)
    #expect(secondReading.warning == nil)

    model.apply(snapshot)
    let summary = model.quotaSummary(at: failedAt)
    #expect(summary.warnings.isEmpty)
    #expect(summary.unconfirmedAccountIDs == [secondReading.id])
    #expect(!summary.isAllClear)
    #expect(model.profiles[1].status == .attention)

    await second.setRateReadError(nil)
    await second.setSessionUsed(0)
    clock.advance(by: 30)
    _ = await controller.checkNow()
    let recoveredAt = clock.value
    let recovered = await controller.snapshot()
    #expect(recovered.profiles[1].quota.reading(at: recoveredAt).freshness == .fresh(lastSuccessAt: recoveredAt))
    model.apply(recovered)
    #expect(model.quotaSummary(at: recoveredAt).isAllClear)
    #expect(model.profiles[1].status == .healthy)
    #expect(await first.consumeCount() == 0)
    #expect(await second.consumeCount() == 0)
    await controller.stop()
}

@Test func codexReadingGoesStaleWithoutAFreshPoll() async throws {
    let fixture = try QuotaFixture(profiles: [("first@example.com", false)])
    defer { fixture.remove() }
    let clock = QuotaClock(fixture.now)
    let session = QuotaSession(email: "first@example.com", clock: clock, sessionUsed: 20, weeklyUsed: 30)
    let controller = fixture.controller(sessions: ["first@example.com": session], clock: clock)
    let snapshot = try await controller.diagnose()
    let record = try #require(snapshot.profiles.first?.quota)
    #expect(record.reading(at: fixture.now).freshness == .fresh(lastSuccessAt: fixture.now))
    let stale = record.reading(at: fixture.now.addingTimeInterval(QuotaReadPolicy.codex.staleAfter))
    #expect(stale.freshness == .stale(lastSuccessAt: fixture.now))
    #expect(stale.windows.map(\.window.remainingPercent) == [80, 70])
    #expect(!QuotaSummary(readings: [stale]).isAllClear)
    #expect(await session.consumeCount() == 0)
}

@Test(arguments: [InventoryShape.absentLegacy, .countOnly(2), .listed(0)])
func codexInventoryKeepsUnknownApartFromZero(shape: InventoryShape) async throws {
    let fixture = try QuotaFixture(profiles: [("first@example.com", false)])
    defer { fixture.remove() }
    let clock = QuotaClock(fixture.now)
    let session = QuotaSession(
        email: "first@example.com", clock: clock, sessionUsed: 20, weeklyUsed: 30, inventory: shape
    )
    let controller = fixture.controller(sessions: ["first@example.com": session], clock: clock)
    let snapshot = try await controller.diagnose()
    let profile = try #require(snapshot.profiles.first)
    let reading = profile.quota.reading(at: fixture.now)
    #expect(reading.freshness == .fresh(lastSuccessAt: fixture.now))
    #expect(reading.windows.map(\.window.kind) == [.session, .weekly])

    switch shape {
    case .absentLegacy:
        #expect(reading.inventory == .unknown(lastKnown: nil))
        #expect(profile.availableResetCount == 0)
        #expect(profile.connectionStatus == .failed)
    case .countOnly:
        #expect(reading.inventory == .known(
            ResetInventorySnapshot(availableCount: 2, expiries: .unlisted, fetchedAt: fixture.now),
            isCurrent: true
        ))
        #expect(profile.availableResetCount == 2)
    case .listed:
        #expect(reading.inventory == .known(
            ResetInventorySnapshot(availableCount: 0, expiries: .listed([]), fetchedAt: fixture.now),
            isCurrent: true
        ))
        #expect(profile.availableResetCount == 0)
    case .capped:
        Issue.record("Covered by cappedSavedResetListGivesNoLegacyNextExpiry")
    }
    #expect(await session.consumeCount() == 0)
}

@Test func codexSavedResetExpiryIsReportedBesideTheRenewal() async throws {
    let fixture = try QuotaFixture(profiles: [("first@example.com", false)])
    defer { fixture.remove() }
    let clock = QuotaClock(fixture.now)
    let session = QuotaSession(
        email: "first@example.com", clock: clock, sessionUsed: 20, weeklyUsed: 30, inventory: .listed(1)
    )
    let controller = fixture.controller(sessions: ["first@example.com": session], clock: clock)
    let profile = try #require(try await controller.diagnose().profiles.first)
    guard case let .known(saved, true) = profile.quota.reading(at: fixture.now).inventory else {
        Issue.record("Expected a current inventory")
        return
    }
    let expiry = fixture.now.addingTimeInterval(QuotaSession.creditLifetime)
    #expect(saved.nextExpiry(after: fixture.now) == expiry)
    #expect(profile.nearestResetExpiry == expiry)
    #expect(profile.naturalResetAt == fixture.now.addingTimeInterval(QuotaSession.weeklyLifetime))
    #expect(expiry != profile.naturalResetAt)
}

@Test func cappedSavedResetListGivesNoLegacyNextExpiry() async throws {
    let fixture = try QuotaFixture(profiles: [("first@example.com", false)])
    defer { fixture.remove() }
    let clock = QuotaClock(fixture.now)
    let session = QuotaSession(
        email: "first@example.com", clock: clock, sessionUsed: 20, weeklyUsed: 30, inventory: .capped(3, listed: 1)
    )
    let controller = fixture.controller(sessions: ["first@example.com": session], clock: clock)
    let profile = try #require(try await controller.diagnose().profiles.first)
    #expect(profile.availableResetCount == 3)
    #expect(profile.nearestResetExpiry == nil)
    guard case let .known(saved, _) = profile.quota.reading(at: fixture.now).inventory else {
        Issue.record("Expected a known count")
        return
    }
    #expect(!saved.isComplete)
    #expect(saved.expiryOutlook(after: fixture.now) == .unknown)
}

@Test @MainActor func missingInventoryStillBlocksAnEnabledAccountWhileWindowsStayCurrent() async throws {
    let fixture = try QuotaFixture(profiles: [("first@example.com", true)])
    defer { fixture.remove() }
    let clock = QuotaClock(fixture.now)
    let session = QuotaSession(
        email: "first@example.com", clock: clock, sessionUsed: 20, weeklyUsed: 98, inventory: .absentLegacy
    )
    let controller = fixture.controller(sessions: ["first@example.com": session], clock: clock)
    _ = try await controller.start()
    #expect(await settled(controller, sessions: [session]))
    clock.advance(by: 10)
    _ = await controller.checkNow()
    let snapshot = await controller.snapshot()
    let profile = try #require(snapshot.profiles.first)
    #expect(profile.connectionStatus == .failed)
    #expect(profile.detail == "Saved-reset inventory was missing, so redemption is blocked.")
    #expect(try await fixture.persistedPhase(profile.id) == .attentionRequired)
    let reading = profile.quota.reading(at: clock.value)
    #expect(reading.freshness == .fresh(lastSuccessAt: clock.value))
    #expect(reading.inventory == .unknown(lastKnown: nil))
    #expect(reading.warning?.window.kind == .weekly)
    #expect(await session.consumeCount() == 0)
    await controller.stop()
}

@Test func identityFailureMarksTheReadingHistorical() async throws {
    let fixture = try QuotaFixture(profiles: [("first@example.com", false)])
    defer { fixture.remove() }
    let clock = QuotaClock(fixture.now)
    let session = QuotaSession(email: "first@example.com", clock: clock, sessionUsed: 20, weeklyUsed: 30)
    let controller = fixture.controller(sessions: ["first@example.com": session], clock: clock)
    _ = try await controller.diagnose()
    await session.setEmail("someone-else@example.com")
    clock.advance(by: 5)
    let snapshot = try await controller.diagnose()
    let profile = try #require(snapshot.profiles.first)
    #expect(profile.connectionStatus == .identityMismatch)
    #expect(profile.weeklyRemainingPercent == nil)
    let reading = profile.quota.reading(at: clock.value)
    #expect(reading.freshness == .failed(.wrongAccount, failedAt: clock.value, lastSuccessAt: fixture.now))
    #expect(reading.windows.allSatisfy { !$0.isCurrent })
}

// MARK: - Claude

@Test @MainActor func claudeReadingGoesStaleFailsKeepsHistoryAndRecovers() async throws {
    let fixture = try QuotaFixture(profiles: [])
    defer { fixture.remove() }
    let clock = QuotaClock(fixture.now)
    let runner = ScriptedClaudeRunner()
    let monitor = fixture.claudeMonitor(runner: runner, clock: clock)
    try await monitor.start()
    let profileID = try await monitor.addProfile(email: "claude@example.com", displayName: "Claude")
    try ClaudeProfileConfiguration(id: profileID, displayName: "Claude", expectedEmail: "claude@example.com")
        .prepareConfigDirectory(root: fixture.claudeConfiguration.profilesRoot)
    await monitor.checkNow()

    let readAt = clock.value
    var reading = try #require(await monitor.snapshot().profiles.first?.quota).reading(at: readAt)
    #expect(reading.freshness == .fresh(lastSuccessAt: readAt))
    #expect(reading.windows.map(\.window.kind) == [.session, .weekly])
    #expect(reading.isConfirmed)

    let staleRecord = try #require(await monitor.snapshot().profiles.first?.quota)
    #expect(staleRecord.reading(at: readAt.addingTimeInterval(600)).freshness == .stale(lastSuccessAt: readAt))

    runner.setFailing(true)
    clock.advance(by: ScriptedClaudeRunner.sessionResetOffset + 1)
    await monitor.checkNow()
    let failedAt = clock.value
    let failed = await monitor.snapshot()
    reading = try #require(failed.profiles.first?.quota).reading(at: failedAt)
    #expect(reading.freshness == .failed(.unavailable, failedAt: failedAt, lastSuccessAt: readAt))
    #expect(reading.windows.map(\.window.remainingPercent) == [8, 70])
    #expect(reading.windows.first?.resetPassed == true)
    #expect(reading.warning == nil)

    let model = GuardAppModel(referenceDate: failedAt)
    var reported: [QuotaProvider] = []
    model.onQuotaRecordsChanged = { provider, records in
        reported.append(provider)
        #expect(records.map(\.accountID) == [profileID])
    }
    model.apply(failed)
    #expect(reported == [.claude])
    let presentation = try #require(model.claudeProfiles.first)
    #expect(presentation.status == .attention)
    #expect(presentation.windows.map(\.isCurrent) == [false, false])
    #expect(model.minimumRemainingPercent == nil)
    #expect(!model.quotaSummary(at: failedAt).isAllClear)

    runner.setFailing(false)
    runner.setSessionReset("May 18, 2033 at 9:34am (UTC)")
    clock.advance(by: 60)
    await monitor.checkNow()
    let recoveredAt = clock.value
    reading = try #require(await monitor.snapshot().profiles.first?.quota).reading(at: recoveredAt)
    #expect(reading.freshness == .fresh(lastSuccessAt: recoveredAt))
    model.apply(await monitor.snapshot())
    #expect(model.claudeProfiles.first?.windows.allSatisfy { $0.isCurrent } == true)
    #expect(model.claudeProfiles.first?.status == .low)
    await monitor.stop()

    // A relaunch shows the saved report as restored and unverified before its first poll, even
    // though it is younger than the stale limit.
    clock.advance(by: 30)
    let early = SnapshotLog()
    let restarted = fixture.claudeMonitor(runner: runner, clock: clock, updates: early)
    try await restarted.start()
    let firstPublished = try #require(early.all.first?.profiles.first?.quota)
    let restored = firstPublished.reading(at: clock.value)
    #expect(restored.isRestoredUnverified)
    #expect(restored.freshness == .stale(lastSuccessAt: recoveredAt))
    #expect(restored.windows.allSatisfy { !$0.isCurrent })
    let restartReadAt = clock.value
    let afterPoll = try #require(await restarted.snapshot().profiles.first?.quota).reading(at: restartReadAt)
    #expect(afterPoll.freshness == .fresh(lastSuccessAt: restartReadAt))
    #expect(!afterPoll.isRestoredUnverified)
    await restarted.stop()

    runner.setFailing(true)
    clock.advance(by: 3_600)
    let relaunched = fixture.claudeMonitor(runner: runner, clock: clock)
    try await relaunched.start()
    reading = try #require(await relaunched.snapshot().profiles.first?.quota).reading(at: clock.value)
    #expect(reading.freshness == .failed(.unavailable, failedAt: clock.value, lastSuccessAt: restartReadAt))
    #expect(reading.windows.count == 2)
    await relaunched.stop()
}

@Test func aClaudeAccountAddedWithoutAnEmailTakesItsFirstSignInsIdentity() async throws {
    let fixture = try QuotaFixture(profiles: [])
    defer { fixture.remove() }
    let clock = QuotaClock(fixture.now)
    let runner = ScriptedClaudeRunner()
    let monitor = fixture.claudeMonitor(runner: runner, clock: clock)
    try await monitor.start()
    let first = try await monitor.addProfile(email: nil, displayName: AccountNaming.provisionalName)
    try ClaudeProfileConfiguration(id: first, displayName: AccountNaming.provisionalName)
        .prepareConfigDirectory(root: fixture.claudeConfiguration.profilesRoot)
    #expect(await monitor.snapshot().profiles.first?.expectedEmail == nil)
    await monitor.checkNow()

    // The scripted Claude Code reports claude@example.com: the profile takes it and a name.
    let pinned = try #require(await monitor.snapshot().profiles.first(where: { $0.id == first }))
    #expect(pinned.expectedEmail == "claude@example.com")
    #expect(pinned.displayName == "Personal", "Reserved example domains read as personal")
    #expect(pinned.status == .verified)

    // A second new profile signed in to the same account is caught and keeps no identity.
    let second = try await monitor.addProfile(email: nil, displayName: AccountNaming.provisionalName)
    try ClaudeProfileConfiguration(id: second, displayName: AccountNaming.provisionalName)
        .prepareConfigDirectory(root: fixture.claudeConfiguration.profilesRoot)
    await monitor.checkNow()
    let duplicate = try #require(await monitor.snapshot().profiles.first(where: { $0.id == second }))
    #expect(duplicate.expectedEmail == nil)
    #expect(duplicate.status == .duplicate(found: "claude@example.com"))
    await monitor.stop()
}

@Test func pendingReconnectSuppressesReadsUntilItsLoginCompletes() async throws {
    let fixture = try QuotaFixture(profiles: [("first@example.com", false)])
    defer { fixture.remove() }
    let clock = QuotaClock(fixture.now)
    let session = QuotaSession(email: "first@example.com", clock: clock, sessionUsed: 20, weeklyUsed: 30)
    let controller = fixture.controller(sessions: ["first@example.com": session], clock: clock)
    _ = try await controller.start()
    #expect(await settled(controller, sessions: [session]))
    let profileID = try #require(await controller.snapshot().profiles.first?.id)
    let readsBefore = await session.rateReadCount()

    _ = try await controller.beginConnection(profileID: profileID)
    clock.advance(by: 5)
    let pending = await controller.checkNow()
    let profile = try #require(pending.profiles.first)
    #expect(profile.connectionStatus == .connecting)
    #expect(await session.rateReadCount() == readsBefore)
    let reading = profile.quota.reading(at: clock.value)
    #expect(reading.freshness == .failed(.signInRequired, failedAt: fixture.now, lastSuccessAt: fixture.now))
    #expect(!QuotaSummary(readings: [reading]).isAllClear)
    do {
        _ = try await controller.setEnabled(profileID: profileID, enabled: true)
        Issue.record("Enabling must wait for the pending sign-in")
    } catch let error as GuardRuntimeError {
        #expect(error == .authenticationRequired)
    }

    await session.completeLogin()
    #expect(await eventually { await controller.snapshot().profiles.first?.connectionStatus == .verified })
    let verified = try #require(await controller.snapshot().profiles.first)
    #expect(verified.quota.reading(at: clock.value).freshness == .fresh(lastSuccessAt: clock.value))
    #expect(await session.consumeCount() == 0)
    await controller.stop()
}

@Test @MainActor func enableTimeIdentityMismatchIsPublished() async throws {
    let fixture = try QuotaFixture(profiles: [("first@example.com", false)])
    defer { fixture.remove() }
    let clock = QuotaClock(fixture.now)
    let session = QuotaSession(email: "first@example.com", clock: clock, sessionUsed: 20, weeklyUsed: 30)
    let controller = fixture.controller(sessions: ["first@example.com": session], clock: clock)
    _ = try await controller.start()
    #expect(await settled(controller, sessions: [session]))
    let profileID = try #require(await controller.snapshot().profiles.first?.id)
    #expect(await controller.snapshot().profiles.first?.connectionStatus == .verified)

    await session.setEmail("someone-else@example.com")
    clock.advance(by: 5)
    do {
        _ = try await controller.setEnabled(profileID: profileID, enabled: true)
        Issue.record("Expected the identity check to fail")
    } catch let error as GuardRuntimeError {
        #expect(error == .identityMismatch)
    }
    let snapshot = await controller.snapshot()
    let profile = try #require(snapshot.profiles.first)
    #expect(profile.connectionStatus == .identityMismatch)
    #expect(profile.weeklyRemainingPercent == nil)
    #expect(!profile.autoResetEnabled)
    let reading = profile.quota.reading(at: clock.value)
    #expect(reading.freshness == .failed(.wrongAccount, failedAt: clock.value, lastSuccessAt: fixture.now))
    let model = GuardAppModel(referenceDate: clock.value)
    model.apply(snapshot)
    #expect(model.profiles.first?.status == .attention)
    #expect(!model.quotaSummary(at: clock.value).isAllClear)
    #expect(await session.consumeCount() == 0)
    await controller.stop()
}

@Test func heldPollCannotOverturnAnEnableTimeWrongAccount() async throws {
    let fixture = try QuotaFixture(profiles: [("first@example.com", false)])
    defer { fixture.remove() }
    let clock = QuotaClock(fixture.now)
    let session = QuotaSession(email: "first@example.com", clock: clock, sessionUsed: 20, weeklyUsed: 30)
    let controller = fixture.controller(sessions: ["first@example.com": session], clock: clock)
    _ = try await controller.start()
    #expect(await settled(controller, sessions: [session]))
    let profileID = try #require(await controller.snapshot().profiles.first?.id)

    await session.holdNextRateRead()
    clock.advance(by: 5)
    let poll = Task { await controller.checkNow() }
    #expect(await eventually { await session.isRateReadHeld() })
    await session.setEmail("someone-else@example.com")
    do {
        _ = try await controller.setEnabled(profileID: profileID, enabled: true)
        Issue.record("Expected the identity check to fail")
    } catch let error as GuardRuntimeError {
        #expect(error == .identityMismatch)
    }
    let failedAt = clock.value
    await session.releaseRateRead()
    _ = await poll.value

    let profile = try #require(await controller.snapshot().profiles.first)
    #expect(profile.connectionStatus == .identityMismatch)
    let reading = profile.quota.reading(at: clock.value)
    #expect(reading.freshness == .failed(.wrongAccount, failedAt: failedAt, lastSuccessAt: fixture.now))
    #expect(!QuotaSummary(readings: [reading]).isAllClear)
    #expect(await session.consumeCount() == 0)
    await controller.stop()
}

@Test(arguments: [IncludedUsageAccess.blocked, .unknown])
@MainActor func withheldIncludedUsageStopsAllClearButKeepsFiguresAndNeverRedeems(
    access: IncludedUsageAccess
) async throws {
    let fixture = try QuotaFixture(profiles: [("first@example.com", true)])
    defer { fixture.remove() }
    let clock = QuotaClock(fixture.now)
    let session = QuotaSession(
        email: "first@example.com", clock: clock, sessionUsed: 20, weeklyUsed: 30, access: access
    )
    let controller = fixture.controller(sessions: ["first@example.com": session], clock: clock)
    _ = try await controller.start()
    #expect(await settled(controller, sessions: [session]))
    let snapshot = await controller.snapshot()
    let reading = try #require(snapshot.profiles.first).quota.reading(at: clock.value)
    #expect(reading.includedUsageAccess == access)
    #expect(reading.windows.map(\.window.remainingPercent) == [80, 70])
    #expect(reading.hasConfirmedWindows)
    #expect(!QuotaSummary(readings: [reading]).isAllClear)

    await session.setAccess(.allowed)
    clock.advance(by: 10)
    let allowed = await controller.checkNow()
    #expect(QuotaSummary(readings: [allowed.profiles[0].quota.reading(at: clock.value)]).isAllClear)
    #expect(await session.consumeCount() == 0)
    await controller.stop()
}

@Test func claudePollFromBeforeAReconnectCannotClearTheNewSignInFailure() async throws {
    let fixture = try QuotaFixture(profiles: [])
    defer { fixture.remove() }
    let clock = QuotaClock(fixture.now)
    let runner = ScriptedClaudeRunner()
    let monitor = fixture.claudeMonitor(runner: runner, clock: clock)
    try await monitor.start()
    let profileID = try await monitor.addProfile(email: "claude@example.com", displayName: "Claude")
    try ClaudeProfileConfiguration(id: profileID, displayName: "Claude", expectedEmail: "claude@example.com")
        .prepareConfigDirectory(root: fixture.claudeConfiguration.profilesRoot)
    await monitor.checkNow()
    let firstReadAt = clock.value

    runner.setFailing(true)
    clock.advance(by: 60)
    await monitor.checkNow()

    runner.setFailing(false)
    runner.holdNextUsageCall()
    clock.advance(by: 60)
    let poll = Task { await monitor.checkNow() }
    #expect(await eventually { runner.isUsageHeld })
    clock.advance(by: 5)
    let signInAt = clock.value
    // The isolated test configuration has no real `claude`, so this sign-in fails.
    await monitor.connect(profileID: profileID)
    runner.releaseUsage()
    await poll.value

    let snapshot = await monitor.snapshot()
    let profile = try #require(snapshot.profiles.first)
    #expect(profile.status != .verified)
    #expect(profile.report?.observedAt == firstReadAt)
    let reading = profile.quota.reading(at: clock.value)
    #expect(reading.freshness == .failed(.signInRequired, failedAt: signInAt, lastSuccessAt: firstReadAt))
    #expect(!QuotaSummary(readings: [reading]).isAllClear)
    await monitor.stop()
}

@Test func unreadableClaudeStoreIsNeitherPublishedNorOverwritten() async throws {
    let fixture = try QuotaFixture(profiles: [])
    defer { fixture.remove() }
    let clock = QuotaClock(fixture.now)
    let stateURL = fixture.claudeConfiguration.stateURL
    let corrupt = Data("not json".utf8)
    try corrupt.write(to: stateURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)

    let updates = SnapshotLog()
    let monitor = fixture.claudeMonitor(runner: ScriptedClaudeRunner(), clock: clock, updates: updates)
    await #expect(throws: (any Error).self) { try await monitor.start() }
    await monitor.checkNow()
    #expect(updates.all.isEmpty)
    await #expect(throws: ClaudeMonitorError.stateUnavailable) {
        _ = try await monitor.addProfile(email: "claude@example.com", displayName: "Claude")
    }
    #expect(try Data(contentsOf: stateURL) == corrupt)
    #expect(updates.all.isEmpty)

    try FileManager.default.removeItem(at: stateURL)
    await monitor.checkNow()
    #expect(updates.all.last?.profiles.isEmpty == true)
    _ = try await monitor.addProfile(email: "claude@example.com", displayName: "Claude")
    #expect(updates.all.last?.profiles.count == 1)
    await monitor.stop()
}

// MARK: - Fixtures

private struct QuotaFixture: @unchecked Sendable {
    let root: URL
    let stateURL: URL
    let eventsURL: URL
    let profilesURL: URL
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    init(profiles: [(String, Bool)]) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-runtime-tests-\(UUID().uuidString)", isDirectory: true)
        stateURL = root.appendingPathComponent("state.json")
        eventsURL = root.appendingPathComponent("events.json")
        profilesURL = root.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard !profiles.isEmpty else { return }
        let configurations = profiles.enumerated().map { index, profile in
            ProfileConfiguration(
                displayName: "Quota profile \(index + 1)",
                expectedEmail: profile.0,
                isEnabled: profile.1
            )
        }
        let state = GuardPersistentState(
            profiles: configurations,
            monitorStates: Dictionary(uniqueKeysWithValues: configurations.map { profile in
                let key = GuardPersistentState.key(for: profile.id)
                return (key, MonitorState(profileID: key, isEnabled: profile.isEnabled))
            }),
            createdAt: now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    var persistence: MonitorPersistence {
        MonitorPersistence(stateFileURL: stateURL, profilesDirectory: profilesURL)
    }

    func persistedPhase(_ profileID: UUID) async throws -> MonitorPhase? {
        try await persistence.snapshot().monitorState(for: profileID)?.phase
    }

    func controller(sessions: [String: QuotaSession], clock: QuotaClock) -> GuardRuntimeController {
        GuardRuntimeController(
            configuration: GuardRuntimeConfiguration(
                operationMode: .production,
                codexExecutableURL: URL(fileURLWithPath: "/does/not/run/in-this-test"),
                applicationSupportDirectory: root,
                profilesDirectory: profilesURL
            ),
            persistence: persistence,
            eventLog: RedactedEventLog(fileURL: eventsURL),
            sessionFactory: { profile in
                guard let email = profile.expectedEmail, let session = sessions[email] else {
                    throw GuardRuntimeError.missingExpectedIdentity
                }
                return session
            },
            now: { clock.value }
        )
    }

    var claudeConfiguration: ClaudeMonitorConfiguration {
        ClaudeMonitorConfiguration(
            isReadOnly: false,
            executableURL: URL(fileURLWithPath: "/does/not/run/in-this-test"),
            applicationSupportDirectory: root,
            pollInterval: .seconds(3_600)
        )
    }

    func claudeMonitor(
        runner: ScriptedClaudeRunner,
        clock: QuotaClock,
        updates: SnapshotLog = SnapshotLog()
    ) -> ClaudeMonitorController {
        ClaudeMonitorController(
            configuration: claudeConfiguration,
            cli: ClaudeCLI(runner: runner),
            now: { clock.value },
            updateHandler: { snapshot in updates.append(snapshot) },
            notificationHandler: { _ in }
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func eventually(
    timeout: Duration = .seconds(3),
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

private func settled(_ controller: GuardRuntimeController, sessions: [QuotaSession]) async -> Bool {
    await eventually {
        for session in sessions where await session.rateReadCount() == 0 { return false }
        let checking = await controller.snapshot().isChecking
        return !checking
    }
}

private final class SnapshotLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ClaudeMonitorSnapshot] = []

    func append(_ snapshot: ClaudeMonitorSnapshot) { lock.withLock { stored.append(snapshot) } }
    var all: [ClaudeMonitorSnapshot] { lock.withLock { stored } }
}

private final class QuotaClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date

    init(_ value: Date) { stored = value }

    var value: Date { lock.withLock { stored } }

    func advance(by interval: TimeInterval) {
        lock.withLock { stored = stored.addingTimeInterval(interval) }
    }
}

enum InventoryShape: Sendable, CustomTestStringConvertible {
    /// An older app-server response: no per-limit map and no inventory field.
    case absentLegacy
    case countOnly(Int)
    case listed(Int)
    /// The provider capped its detail rows below the count.
    case capped(Int, listed: Int)

    var testDescription: String {
        switch self {
        case .absentLegacy: "absent (legacy)"
        case let .countOnly(count): "count only \(count)"
        case let .listed(count): "listed \(count)"
        case let .capped(count, listed): "\(listed) of \(count) listed"
        }
    }
}

private actor QuotaSession: GuardAppServerSession {
    static let sessionLifetime: TimeInterval = 3_600
    static let weeklyLifetime: TimeInterval = 4 * 86_400
    static let creditLifetime: TimeInterval = 2 * 86_400

    private var email: String
    private let clock: QuotaClock
    private var sessionUsed: Int
    private let weeklyUsed: Int
    private let sessionResetAt: Date
    private let weeklyResetAt: Date
    private let inventory: InventoryShape
    private var access: IncludedUsageAccess
    private var rateReadError: AppServerClientError?
    private var rateReads = 0
    private var consumes = 0
    private var notificationStreams: [AsyncStream<AppServerNotification>.Continuation] = []
    private var holdNextRate = false
    private var heldRate: CheckedContinuation<Void, Never>?

    init(
        email: String,
        clock: QuotaClock,
        sessionUsed: Int,
        weeklyUsed: Int,
        inventory: InventoryShape = .listed(1),
        access: IncludedUsageAccess = .unreported
    ) {
        self.access = access
        self.email = email
        self.clock = clock
        self.sessionUsed = sessionUsed
        self.weeklyUsed = weeklyUsed
        self.inventory = inventory
        sessionResetAt = clock.value.addingTimeInterval(Self.sessionLifetime)
        weeklyResetAt = clock.value.addingTimeInterval(Self.weeklyLifetime)
    }

    func start() async throws {}
    func shutdown() async {
        for stream in notificationStreams { stream.finish() }
        notificationStreams.removeAll()
    }

    func notifications() async -> AsyncStream<AppServerNotification> {
        let (stream, continuation) = AsyncStream<AppServerNotification>.makeStream()
        notificationStreams.append(continuation)
        return stream
    }

    func completeLogin() {
        let completion = RPCLoginCompletedNotification(loginID: "quota-fixture-login", success: true, error: nil)
        for stream in notificationStreams { stream.yield(.loginCompleted(completion)) }
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
        #expect(!notificationStreams.isEmpty, "Subscribe before requesting a sign-in that can complete immediately.")
        return RPCChatGPTLoginStartResponse(
            loginID: "quota-fixture-login",
            authURL: URL(string: "https://example.com/login")!
        )
    }

    func readRateLimits() async throws -> RPCRateLimitsReadResponse {
        rateReads += 1
        if holdNextRate {
            holdNextRate = false
            await withCheckedContinuation { heldRate = $0 }
        }
        if let rateReadError { throw rateReadError }
        let current = clock.value
        // Like the provider, a window that has renewed reports its next reset time.
        func next(_ reset: Date, every period: TimeInterval) -> Date {
            var value = reset
            while value <= current { value = value.addingTimeInterval(period) }
            return value
        }
        let sessionResetAt = next(self.sessionResetAt, every: 5 * 3_600)
        let weeklyResetAt = next(self.weeklyResetAt, every: 7 * 86_400)
        let snapshot = RPCRateLimitSnapshot(
            limitID: "codex",
            limitName: nil,
            primary: RPCRateLimitWindow(
                usedPercent: sessionUsed,
                windowDurationMinutes: 300,
                resetsAt: Int64(sessionResetAt.timeIntervalSince1970)
            ),
            secondary: RPCRateLimitWindow(
                usedPercent: weeklyUsed,
                windowDurationMinutes: 10_080,
                resetsAt: Int64(weeklyResetAt.timeIntervalSince1970)
            )
        )
        func credits(_ count: Int) -> [RPCResetCredit] {
            (0..<count).map { index in
                RPCResetCredit(
                    id: "quota-credit-\(index)",
                    resetType: "codexRateLimits",
                    status: "available",
                    grantedAt: Int64(current.addingTimeInterval(-60).timeIntervalSince1970),
                    expiresAt: Int64(current.addingTimeInterval(Self.creditLifetime).timeIntervalSince1970),
                    title: nil,
                    detail: nil
                )
            }
        }
        switch inventory {
        case .absentLegacy:
            return RPCRateLimitsReadResponse(rateLimits: snapshot, includedUsageAccess: access)
        case let .countOnly(count):
            return RPCRateLimitsReadResponse(
                rateLimits: snapshot,
                rateLimitsByLimitID: ["codex": snapshot],
                rateLimitResetCredits: RPCResetCreditsSummary(availableCount: Int64(count), credits: nil),
                includedUsageAccess: access
            )
        case let .listed(count):
            return RPCRateLimitsReadResponse(
                rateLimits: snapshot,
                rateLimitsByLimitID: ["codex": snapshot],
                rateLimitResetCredits: RPCResetCreditsSummary(
                    availableCount: Int64(count),
                    credits: credits(count)
                ),
                includedUsageAccess: access
            )
        case let .capped(count, listed):
            return RPCRateLimitsReadResponse(
                rateLimits: snapshot,
                rateLimitsByLimitID: ["codex": snapshot],
                rateLimitResetCredits: RPCResetCreditsSummary(
                    availableCount: Int64(count),
                    credits: credits(listed)
                ),
                includedUsageAccess: access
            )
        }
    }

    func consumeReset(idempotencyKey: String, creditID: String?) async throws -> RPCConsumeResetOutcome {
        consumes += 1
        return .nothingToReset
    }

    func setEmail(_ value: String) { email = value }
    func holdNextRateRead() { holdNextRate = true }
    func isRateReadHeld() -> Bool { heldRate != nil }
    func releaseRateRead() {
        heldRate?.resume()
        heldRate = nil
    }
    func setAccess(_ value: IncludedUsageAccess) { access = value }
    func setSessionUsed(_ value: Int) { sessionUsed = value }
    func setRateReadError(_ value: AppServerClientError?) { rateReadError = value }
    func rateReadCount() -> Int { rateReads }
    func consumeCount() -> Int { consumes }
}

/// The fixture clock starts at 2033-05-18 03:33:20 UTC.
private final class ScriptedClaudeRunner: ClaudeCommandRunning, @unchecked Sendable {
    static let sessionResetOffset: TimeInterval = 3_640

    private let lock = NSLock()
    private var failing = false
    private var sessionReset = "May 18, 2033 at 4:34am (UTC)"
    private var holdNextUsage = false
    private var heldUsage: CheckedContinuation<Void, Never>?

    func setFailing(_ value: Bool) { lock.withLock { failing = value } }
    func setSessionReset(_ value: String) { lock.withLock { sessionReset = value } }
    func holdNextUsageCall() { lock.withLock { holdNextUsage = true } }
    var isUsageHeld: Bool { lock.withLock { heldUsage != nil } }
    func releaseUsage() {
        let held = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { heldUsage = nil }
            return heldUsage
        }
        held?.resume()
    }

    func run(arguments: [String], configDirectory: URL, timeout: Duration) async throws -> ClaudeCommandOutput {
        if !arguments.starts(with: ["auth", "status"]),
           lock.withLock({ () -> Bool in defer { holdNextUsage = false }; return holdNextUsage }) {
            await withCheckedContinuation { continuation in lock.withLock { heldUsage = continuation } }
        }
        if lock.withLock({ failing }) { throw ClaudeCLIError.launchFailed }
        if arguments.starts(with: ["auth", "status"]) {
            let json = #"{"loggedIn":true,"authMethod":"claude.ai","email":"claude@example.com","subscriptionType":"max"}"#
            return ClaudeCommandOutput(status: 0, standardOutput: Data(json.utf8))
        }
        let result = "Current session: 92% used · resets \(lock.withLock { sessionReset })\\n"
            + "Current week (all models): 30% used · resets May 24, 2033 at 4am (UTC)"
        let json = #"{"type":"result","subtype":"success","is_error":false,"result":"\#(result)","local_command":"usage","num_turns":0}"#
        return ClaudeCommandOutput(status: 0, standardOutput: Data(json.utf8))
    }
}
