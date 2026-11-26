import Foundation
import Testing
import UserNotifications
@testable import SecondWind
@testable import SecondWindCore

private let start = Date(timeIntervalSince1970: 2_000_000_000)
private let hour: TimeInterval = 3_600

private final class AlertClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date { lock.withLock { value } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(seconds) }
    }
}

private actor FakeNotifier: AlertNotifier {
    private(set) var shown: [AlertDelivery] = []
    private(set) var pending: [String: AlertDelivery] = [:]
    private(set) var cancelled: [String] = []
    private(set) var scheduleCount = 0
    private(set) var permissionRequests = 0
    private(set) var calls = 0
    private var status: NotificationPermissionStatus
    private let grant: NotificationPermissionStatus
    var refusesSchedules = false

    init(status: NotificationPermissionStatus = .allowed, grant: NotificationPermissionStatus = .allowed) {
        self.status = status
        self.grant = grant
    }

    func setRefusesSchedules(_ refuses: Bool) {
        refusesSchedules = refuses
    }

    func deliver(_ delivery: AlertDelivery, now: Date) async throws {
        calls += 1
        if refusesSchedules, delivery.fireAt != nil {
            throw UNError(.notificationsNotAllowed)
        }
        if delivery.fireAt == nil {
            shown.append(delivery)
        } else {
            scheduleCount += 1
            pending[delivery.id] = delivery
        }
    }

    func cancel(_ ids: [String]) async {
        calls += 1
        cancelled += ids
        for id in ids { pending[id] = nil }
    }

    func permission() async -> NotificationPermissionStatus {
        calls += 1
        return status
    }

    func requestPermission() async -> NotificationPermissionStatus {
        calls += 1
        permissionRequests += 1
        if status == .notDetermined { status = grant }
        return status
    }

    func notices(_ match: (AlertNotice) -> Bool) -> [AlertDelivery] {
        shown.filter { match($0.notice) }
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("alert-routing-\(UUID().uuidString)", isDirectory: true)
}

private func router(
    _ directory: URL?,
    _ notifier: FakeNotifier,
    _ clock: AlertClock
) -> AlertRouter {
    AlertRouter(
        stateURL: directory?.appendingPathComponent("alerts.json", isDirectory: false),
        notifier: notifier,
        now: { clock.now }
    )
}

/// Ingests and waits, so a later clock move cannot age a reading still in the queue.
private func feed(
    _ alerts: AlertRouter,
    _ provider: QuotaProvider,
    _ records: [QuotaAccountRecord],
    names: [UUID: String] = [:]
) async {
    alerts.ingest(provider, records: records, names: names)
    await alerts.settled()
}

private func codex(
    _ id: UUID,
    at observedAt: Date,
    weeklyLeft: Double,
    resetsAt: Date,
    savedResets: Int? = nil,
    expiries: [Date]? = nil,
    access: IncludedUsageAccess = .allowed
) -> QuotaAccountRecord {
    let inventory: ResetInventoryReport
    if let savedResets {
        inventory = .reported(ResetInventorySnapshot(
            availableCount: savedResets,
            expiries: expiries.map { .listed($0.map { .on($0) }) } ?? .unlisted,
            fetchedAt: observedAt
        ))
    } else {
        inventory = .omitted
    }
    var observation = QuotaObservation(
        observedAt: observedAt,
        windows: [QuotaWindow(kind: .weekly, usedPercent: 100 - weeklyLeft, resetsAt: resetsAt)],
        inventory: inventory
    )
    observation.includedUsageAccess = access
    return QuotaAccountRecord(provider: .codex, accountID: id, lastSuccess: observation)
}

private func claude(
    _ id: UUID,
    at observedAt: Date,
    sessionLeft: Double,
    resetsAt: Date?,
    weeklyLeft: Double? = nil
) -> QuotaAccountRecord {
    var windows = [QuotaWindow(kind: .session, usedPercent: 100 - sessionLeft, resetsAt: resetsAt)]
    if let weeklyLeft {
        windows.append(QuotaWindow(kind: .weekly, usedPercent: 100 - weeklyLeft, resetsAt: resetsAt))
    }
    return QuotaAccountRecord(
        provider: .claude,
        accountID: id,
        lastSuccess: QuotaObservation(observedAt: observedAt, windows: windows, inventory: .notTracked)
    )
}

private func isRefill(_ notice: AlertNotice) -> Bool {
    if case .limitRefilled = notice { return true }
    return false
}

private func isAttention(_ notice: AlertNotice) -> Bool {
    if case .needsAttention = notice { return true }
    return false
}

private let refillOnly = AlertPreferences(savedResetExpiry: false, limitRefilled: true)
private let expiryOnly = AlertPreferences(savedResetExpiry: true, limitRefilled: false)

@Test func firstUsableReadingIsSilentAndRefillNeedsARecordedBlock() async throws {
    let directory = temporaryDirectory()
    let clock = AlertClock(start)
    let notifier = FakeNotifier()
    let alerts = router(directory, notifier, clock)
    let id = UUID()
    let ref = AccountRef(provider: .codex, id: id)
    try await alerts.setPreferences(refillOnly)

    await feed(alerts, .codex, [codex(id, at: clock.now, weeklyLeft: 100, resetsAt: start + 90 * hour)])
    clock.advance(60)
    await feed(alerts, .codex, [codex(id, at: clock.now, weeklyLeft: 0, resetsAt: start + 90 * hour)])
    #expect(await notifier.shown.isEmpty)

    clock.advance(60)
    let refilled = codex(id, at: clock.now, weeklyLeft: 100, resetsAt: start + 258 * hour)
    for _ in 0..<5 {
        alerts.ingest(.codex, records: [refilled], names: [id: "Work"])
    }
    await alerts.settled()
    let shown = await notifier.shown
    #expect(shown.count == 1)
    #expect(shown.first?.account == ref)
    #expect(shown.first?.name == "Work")
    #expect(shown.first?.notice == .limitRefilled(.weekly))
}

@Test func codexRefillWaitsForTheProviderToAllowOrdinaryUse() async throws {
    let directory = temporaryDirectory()
    let clock = AlertClock(start)
    let notifier = FakeNotifier()
    let alerts = router(directory, notifier, clock)
    let id = UUID()
    let blockedCycle = start + 20 * hour
    let nextCycle = blockedCycle + 168 * hour
    try await alerts.setPreferences(refillOnly)

    await feed(alerts, .codex, [codex(id, at: clock.now, weeklyLeft: 0, resetsAt: blockedCycle, access: .blocked)])
    for access: IncludedUsageAccess in [.blocked, .unknown, .unreported] {
        clock.advance(60)
        await feed(alerts, .codex, [codex(id, at: clock.now, weeklyLeft: 100, resetsAt: nextCycle, access: access)])
    }
    #expect(await notifier.shown.isEmpty)

    clock.advance(60)
    await feed(alerts, .codex, [codex(id, at: clock.now, weeklyLeft: 100, resetsAt: nextCycle, access: .allowed)])
    #expect(await notifier.notices(isRefill).map(\.notice) == [.limitRefilled(.weekly)])
}

@Test func eachWindowThatRefillsIsAnnouncedOnce() async throws {
    let directory = temporaryDirectory()
    let clock = AlertClock(start)
    let notifier = FakeNotifier()
    let alerts = router(directory, notifier, clock)
    let id = UUID()
    try await alerts.setPreferences(refillOnly)

    await feed(alerts, .claude, [claude(id, at: clock.now, sessionLeft: 0, resetsAt: start + hour, weeklyLeft: 0)])
    clock.advance(60)
    await feed(alerts, .claude, [claude(id, at: clock.now, sessionLeft: 100, resetsAt: start + 9 * hour, weeklyLeft: 100)])
    clock.advance(60)
    await feed(alerts, .claude, [claude(id, at: clock.now, sessionLeft: 100, resetsAt: start + 9 * hour, weeklyLeft: 100)])
    #expect(await notifier.shown.map(\.notice) == [.limitRefilled(.session), .limitRefilled(.weekly)])
}

@Test func anElapsedWindowCannotConfirmARefillAndAUsableFractionCounts() async throws {
    let clock = AlertClock(start)
    let notifier = FakeNotifier()
    let alerts = router(temporaryDirectory(), notifier, clock)
    let id = UUID()
    try await alerts.setPreferences(refillOnly)
    let renews = start + 30
    await feed(alerts, .codex, [codex(id, at: clock.now, weeklyLeft: 0, resetsAt: renews)])
    clock.advance(60)
    await feed(alerts, .codex, [codex(id, at: clock.now, weeklyLeft: 90, resetsAt: renews)])
    #expect(await notifier.shown.isEmpty)
    clock.advance(20)
    await feed(alerts, .codex, [codex(id, at: clock.now, weeklyLeft: 0.5, resetsAt: start + hour)])
    #expect(await notifier.shown.map(\.notice) == [.limitRefilled(.weekly)])
}

@Test func refillDedupSurvivesRelaunchAndFlappingInOneCycle() async throws {
    let directory = temporaryDirectory()
    let clock = AlertClock(start)
    let id = UUID()
    let cycle = start + 2 * hour

    let first = FakeNotifier()
    let beforeQuit = router(directory, first, clock)
    try await beforeQuit.setPreferences(refillOnly)
    await feed(beforeQuit, .claude, [claude(id, at: clock.now, sessionLeft: 0, resetsAt: cycle)])

    clock.advance(60)
    let second = FakeNotifier()
    let afterRelaunch = router(directory, second, clock)
    await feed(afterRelaunch, .claude, [claude(id, at: clock.now, sessionLeft: 100, resetsAt: cycle)])
    #expect(await second.notices(isRefill).count == 1)
    #expect(await afterRelaunch.preferences() == refillOnly)

    let third = FakeNotifier()
    let againRelaunched = router(directory, third, clock)
    for left in [0.0, 100, 0, 100] {
        clock.advance(60)
        await feed(againRelaunched, .claude, [claude(id, at: clock.now, sessionLeft: left, resetsAt: cycle)])
    }
    #expect(await third.calls == 0)
}

@Test func staleBackwardAndOldReadingsNeverAnnounceARefill() async throws {
    let directory = temporaryDirectory()
    let clock = AlertClock(start)
    let notifier = FakeNotifier()
    let alerts = router(directory, notifier, clock)
    let id = UUID()
    let blockedCycle = start + 50 * hour
    try await alerts.setPreferences(refillOnly)

    let refilledCycle = blockedCycle + 168 * hour
    await feed(alerts, .codex, [codex(id, at: clock.now, weeklyLeft: 0, resetsAt: blockedCycle)])
    await feed(alerts, .codex, [
        codex(id, at: clock.now.addingTimeInterval(-30), weeklyLeft: 100, resetsAt: refilledCycle),
    ])
    clock.advance(60)
    await feed(alerts, .codex, [codex(id, at: clock.now, weeklyLeft: 100, resetsAt: blockedCycle - 168 * hour)])
    clock.advance(10 * 60)
    await feed(alerts, .codex, [
        codex(id, at: clock.now.addingTimeInterval(-121), weeklyLeft: 100, resetsAt: refilledCycle),
    ])
    await feed(alerts, .codex, [
        codex(id, at: clock.now.addingTimeInterval(5), weeklyLeft: 100, resetsAt: refilledCycle),
    ])
    var failed = codex(id, at: clock.now, weeklyLeft: 100, resetsAt: refilledCycle)
    failed.recordFailure(.unavailable, at: clock.now)
    await feed(alerts, .codex, [failed])
    #expect(await notifier.shown.isEmpty)

    clock.advance(1)
    await feed(alerts, .codex, [codex(id, at: clock.now, weeklyLeft: 100, resetsAt: refilledCycle)])
    #expect(await notifier.notices(isRefill).count == 1)
}

@Test func twoAccountsAreTrackedAndEachRosterOnlyForgetsItsOwnProvider() async throws {
    let directory = temporaryDirectory()
    let clock = AlertClock(start)
    let notifier = FakeNotifier()
    let alerts = router(directory, notifier, clock)
    let (a, b, c) = (UUID(), UUID(), UUID())
    let (refA, refB) = (AccountRef(provider: .codex, id: a), AccountRef(provider: .codex, id: b))
    let reset = start + 40 * hour
    let expiry = start + 30 * hour
    try await alerts.setPreferences(AlertPreferences(savedResetExpiry: true, limitRefilled: true))

    await feed(alerts, .claude, [])
    await feed(alerts, .codex, [
        codex(a, at: clock.now, weeklyLeft: 0, resetsAt: reset, savedResets: 1, expiries: [expiry]),
        codex(b, at: clock.now, weeklyLeft: 0, resetsAt: reset, savedResets: 1, expiries: [expiry]),
    ])
    #expect(await notifier.pending.count == 4)

    clock.advance(60)
    await feed(alerts, .codex, [
        codex(a, at: clock.now, weeklyLeft: 100, resetsAt: reset + 168 * hour, savedResets: 1, expiries: [expiry]),
        codex(b, at: clock.now, weeklyLeft: 0, resetsAt: reset, savedResets: 1, expiries: [expiry]),
    ], names: [a: "Work", b: "Home"])
    #expect(await notifier.notices(isRefill).map(\.account) == [refA])
    #expect(await notifier.notices(isRefill).map(\.name) == ["Work"])

    clock.advance(60)
    await feed(alerts, .codex, [
        codex(b, at: clock.now, weeklyLeft: 100, resetsAt: reset + 168 * hour, savedResets: 1, expiries: [expiry]),
    ])
    #expect(await notifier.notices(isRefill).map(\.account) == [refA, refB])
    #expect(await notifier.cancelled.count == 2)
    #expect(await notifier.cancelled.allSatisfy { $0.hasPrefix(refA.token) })

    await feed(alerts, .claude, [claude(UUID(), at: clock.now, sessionLeft: 50, resetsAt: nil)])
    let pending = await notifier.pending
    #expect(pending.count == 2)
    #expect(pending.values.allSatisfy { $0.account == refB })

    alerts.forget(refB)
    await alerts.settled()
    #expect(await notifier.pending.isEmpty)

    await feed(alerts, .codex, [
        codex(c, at: clock.now, weeklyLeft: 50, resetsAt: reset, savedResets: 1, expiries: [expiry]),
    ])
    #expect(await notifier.pending.count == 2)
    await feed(alerts, .codex, [])
    #expect(await notifier.pending.isEmpty)
}

@Test func savedResetSpendingOrAnAppliedResetSilencesTheRefill() async throws {
    let directory = temporaryDirectory()
    let clock = AlertClock(start)
    let notifier = FakeNotifier()
    let alerts = router(directory, notifier, clock)
    let (spent, applied, appliedFirst) = (UUID(), UUID(), UUID())
    let reset = start + 40 * hour
    try await alerts.setPreferences(refillOnly)

    await feed(alerts, .codex, [
        codex(spent, at: clock.now, weeklyLeft: 0, resetsAt: reset, savedResets: 2),
        codex(applied, at: clock.now, weeklyLeft: 0, resetsAt: reset),
    ])
    alerts.post(.resetApplied(AccountRef(provider: .codex, id: applied), name: "Work"))
    alerts.post(.resetApplied(AccountRef(provider: .codex, id: appliedFirst), name: "Home"))
    clock.advance(30)
    await feed(alerts, .codex, [
        codex(spent, at: clock.now, weeklyLeft: 100, resetsAt: reset + 168 * hour, savedResets: 1),
        codex(applied, at: clock.now, weeklyLeft: 100, resetsAt: reset + 168 * hour),
        codex(appliedFirst, at: clock.now, weeklyLeft: 0, resetsAt: reset, savedResets: 2),
    ])
    clock.advance(30)
    await feed(alerts, .codex, [
        codex(spent, at: clock.now, weeklyLeft: 100, resetsAt: reset + 168 * hour, savedResets: 1),
        codex(applied, at: clock.now, weeklyLeft: 100, resetsAt: reset + 168 * hour),
        codex(appliedFirst, at: clock.now, weeklyLeft: 100, resetsAt: reset + 168 * hour, savedResets: 1),
    ])

    #expect(await notifier.notices(isRefill).isEmpty)
    #expect(await notifier.notices { $0 == .resetApplied }.count == 2)
}

@Test func expiryRemindersScheduleOnceAndReconcileConsumedCredits() async throws {
    let directory = temporaryDirectory()
    let clock = AlertClock(start)
    let notifier = FakeNotifier()
    let alerts = router(directory, notifier, clock)
    let id = UUID()
    let reset = start + 100 * hour
    let expiry = start + 30 * hour
    try await alerts.setPreferences(expiryOnly)

    for _ in 0..<3 {
        await feed(alerts, .codex, [
            codex(id, at: clock.now, weeklyLeft: 50, resetsAt: reset, savedResets: 2, expiries: [expiry, expiry + 20]),
        ])
        clock.advance(60)
    }
    var pending = await notifier.pending
    #expect(pending.count == 2)
    #expect(await notifier.scheduleCount == 2)
    #expect(Set(pending.values.compactMap(\.fireAt)) == [expiry - 24 * hour, expiry - hour])
    #expect(await notifier.shown.isEmpty)

    await feed(alerts, .codex, [codex(id, at: clock.now, weeklyLeft: 50, resetsAt: reset)])
    clock.advance(60)
    await feed(alerts, .codex, [codex(id, at: clock.now, weeklyLeft: 50, resetsAt: reset, savedResets: 2)])
    #expect(await notifier.pending.count == 2)

    clock.advance(60)
    await feed(alerts, .codex, [
        codex(id, at: clock.now, weeklyLeft: 50, resetsAt: reset, savedResets: 0, expiries: []),
    ])
    pending = await notifier.pending
    #expect(pending.isEmpty)
    #expect(await notifier.cancelled.count == 2)
}

@Test func remindersTheSystemRefusedAreScheduledAgainOnTheNextReading() async throws {
    let directory = temporaryDirectory()
    let clock = AlertClock(start)
    let notifier = FakeNotifier()
    let alerts = router(directory, notifier, clock)
    let id = UUID()
    let reading = { (date: Date) in
        codex(id, at: date, weeklyLeft: 50, resetsAt: start + 100 * hour, savedResets: 1, expiries: [start + 30 * hour])
    }
    try await alerts.setPreferences(expiryOnly)

    await notifier.setRefusesSchedules(true)
    await feed(alerts, .codex, [reading(clock.now)])
    #expect(await notifier.pending.isEmpty)

    await notifier.setRefusesSchedules(false)
    clock.advance(60)
    let relaunched = FakeNotifier()
    let again = router(directory, relaunched, clock)
    await feed(again, .codex, [reading(clock.now)])
    #expect(await relaunched.pending.count == 2)
    clock.advance(60)
    await feed(again, .codex, [reading(clock.now)])
    #expect(await relaunched.scheduleCount == 2)
}

@Test func cappedCreditListNeverCancelsRemindersForUnlistedResets() async throws {
    let directory = temporaryDirectory()
    let clock = AlertClock(start)
    let notifier = FakeNotifier()
    let alerts = router(directory, notifier, clock)
    let id = UUID()
    let reset = start + 100 * hour
    let (first, second) = (start + 30 * hour, start + 40 * hour)
    let reminders = { (expiry: Date) in
        Set([expiry - 24 * hour, expiry - hour])
    }
    try await alerts.setPreferences(expiryOnly)

    await feed(alerts, .codex, [
        codex(id, at: clock.now, weeklyLeft: 50, resetsAt: reset, savedResets: 2, expiries: [first, second]),
    ])
    #expect(Set(await notifier.pending.values.compactMap(\.fireAt)) == reminders(first).union(reminders(second)))

    clock.advance(60)
    await feed(alerts, .codex, [
        codex(id, at: clock.now, weeklyLeft: 50, resetsAt: reset, savedResets: 2, expiries: [first]),
    ])
    clock.advance(60)
    await feed(alerts, .codex, [
        codex(id, at: clock.now, weeklyLeft: 50, resetsAt: reset, savedResets: 2, expiries: []),
    ])
    #expect(await notifier.pending.count == 4)
    #expect(await notifier.cancelled.isEmpty)

    clock.advance(60)
    await feed(alerts, .codex, [
        codex(id, at: clock.now, weeklyLeft: 50, resetsAt: reset, savedResets: 1, expiries: [first]),
    ])
    #expect(Set(await notifier.pending.values.compactMap(\.fireAt)) == reminders(first))

    clock.advance(60)
    await feed(alerts, .codex, [codex(id, at: clock.now, weeklyLeft: 50, resetsAt: reset, savedResets: 0)])
    #expect(await notifier.pending.isEmpty)
    #expect(await notifier.cancelled.count == 4)
}

@Test func dueExpiryReminderFiresOnceForTheMostUrgentStage() async throws {
    let directory = temporaryDirectory()
    let clock = AlertClock(start)
    let notifier = FakeNotifier()
    let alerts = router(directory, notifier, clock)
    let (soon, later) = (UUID(), UUID())
    let reset = start + 100 * hour
    try await alerts.setPreferences(expiryOnly)

    await feed(alerts, .codex, [
        codex(soon, at: clock.now, weeklyLeft: 50, resetsAt: reset, savedResets: 1, expiries: [start + 1_800]),
        codex(later, at: clock.now, weeklyLeft: 50, resetsAt: reset, savedResets: 1, expiries: [start + 10 * hour]),
    ])
    let shown = await notifier.shown
    #expect(shown.count == 2)
    #expect(shown.contains {
        $0.account?.id == soon && $0.notice == .savedResetExpiring(.hourBefore, expiresAt: start + 1_800)
    })
    #expect(shown.contains {
        $0.account?.id == later && $0.notice == .savedResetExpiring(.dayBefore, expiresAt: start + 10 * hour)
    })
    #expect(await notifier.pending.values.map(\.notice) == [.savedResetExpiring(.hourBefore, expiresAt: start + 10 * hour)])

    clock.advance(60)
    let relaunched = FakeNotifier()
    let again = router(directory, relaunched, clock)
    await feed(again, .codex, [
        codex(soon, at: clock.now, weeklyLeft: 50, resetsAt: reset, savedResets: 1, expiries: [start + 1_800]),
        codex(later, at: clock.now, weeklyLeft: 50, resetsAt: reset, savedResets: 1, expiries: [start + 10 * hour]),
    ])
    #expect(await relaunched.calls == 0)
}

@Test func turningExpiryRemindersOffWithdrawsPendingOnes() async throws {
    let directory = temporaryDirectory()
    let clock = AlertClock(start)
    let notifier = FakeNotifier()
    let alerts = router(directory, notifier, clock)
    let id = UUID()
    try await alerts.setPreferences(expiryOnly)
    await feed(alerts, .codex, [
        codex(id, at: clock.now, weeklyLeft: 50, resetsAt: start + 100 * hour, savedResets: 1, expiries: [start + 48 * hour]),
    ])
    #expect(await notifier.pending.count == 2)

    try await alerts.setPreferences(.off)
    #expect(await notifier.pending.isEmpty)
    #expect(await alerts.preferences() == .off)
}

@Test func readOnlyRouterNeverTouchesNotificationsOrDisk() async throws {
    let directory = temporaryDirectory()
    let clock = AlertClock(start)
    let notifier = FakeNotifier(status: .notDetermined)
    let alerts = router(nil, notifier, clock)
    let id = UUID()
    let ref = AccountRef(provider: .codex, id: id)

    alerts.ingest(.codex, records: [codex(id, at: clock.now, weeklyLeft: 0, resetsAt: start + hour, savedResets: 1, expiries: [start + 600])])
    clock.advance(60)
    alerts.ingest(.codex, records: [codex(id, at: clock.now, weeklyLeft: 100, resetsAt: start + 9 * hour)])
    alerts.post(.resetApplied(ref, name: "Work"))
    alerts.post(.resetNeedsAttention(ref, name: "Work"))
    alerts.forget(ref)
    await alerts.settled()

    await #expect(throws: AlertPreferencesError.notSaved) { try await alerts.setPreferences(refillOnly) }
    await #expect(throws: AlertTestError.unavailable) { try await alerts.sendTest() }
    #expect(await alerts.permission() == .unknown)
    #expect(await alerts.requestPermission() == .unknown)
    #expect(await alerts.preferences() == .off)
    #expect(await notifier.calls == 0)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@Test func attentionNeedsAPriorVerifiedReadingAndRepeatsOnlyAfterRecovery() async throws {
    let directory = temporaryDirectory()
    let clock = AlertClock(start)
    let notifier = FakeNotifier()
    let alerts = router(directory, notifier, clock)
    let (fresh, known) = (UUID(), UUID())

    var neverConnected = QuotaAccountRecord(provider: .claude, accountID: fresh)
    neverConnected.recordFailure(.signInRequired, at: clock.now)
    await feed(alerts, .claude, [neverConnected])
    #expect(await notifier.shown.isEmpty)

    var record = claude(known, at: clock.now, sessionLeft: 60, resetsAt: nil)
    await feed(alerts, .claude, [record])
    clock.advance(60)
    record.recordFailure(.unavailable, at: clock.now)
    await feed(alerts, .claude, [record])
    record.recordFailure(.signInRequired, at: clock.now)
    for _ in 0..<3 { await feed(alerts, .claude, [record]) }
    #expect(await notifier.notices(isAttention).map(\.notice) == [.needsAttention(.signInRequired)])

    let relaunched = FakeNotifier()
    let again = router(directory, relaunched, clock)
    await feed(again, .claude, [record])
    again.post(.resetNeedsAttention(AccountRef(provider: .claude, id: known), name: "Home"))
    again.post(.resetNeedsAttention(AccountRef(provider: .claude, id: known), name: "Home"))
    await again.settled()
    #expect(await relaunched.notices(isAttention).map(\.notice) == [.needsAttention(.resetNeedsAttention)])

    clock.advance(60)
    record.recordSuccess(QuotaObservation(observedAt: clock.now, windows: [], inventory: .notTracked))
    await feed(again, .claude, [record])
    clock.advance(60)
    record.recordFailure(.signInRequired, at: clock.now)
    await feed(again, .claude, [record])
    #expect(await relaunched.notices(isAttention).count == 2)
}

@Test func unsavedLedgerDropsOnlyLedgerDedupedNotices() async throws {
    let blocker = temporaryDirectory()
    try Data().write(to: blocker)
    defer { try? FileManager.default.removeItem(at: blocker) }
    let clock = AlertClock(start)
    let notifier = FakeNotifier()
    let alerts = AlertRouter(
        stateURL: blocker.appendingPathComponent("alerts.json", isDirectory: false),
        notifier: notifier,
        now: { clock.now }
    )
    let ref = AccountRef(provider: .claude, id: UUID())

    await #expect(throws: AlertPreferencesError.notSaved) { try await alerts.setPreferences(refillOnly) }
    alerts.post(.resetNeedsAttention(ref, name: "Home"))
    alerts.post(.lowQuota(ref, name: "Home", window: QuotaWindow(kind: .session, usedPercent: 95, resetsAt: nil)))
    await alerts.settled()
    #expect(await notifier.shown.map(\.notice) == [
        .lowQuota(QuotaWindow(kind: .session, usedPercent: 95, resetsAt: nil)),
    ])
}

@Test func payloadAndTextCarryOnlyTheAccountTokenAndName() {
    let ref = AccountRef(provider: .codex, id: UUID())
    let notices: [AlertNotice] = [
        .lowQuota(QuotaWindow(kind: .modelWeekly("Sonnet only"), usedPercent: 92, resetsAt: start + hour)),
        .limitRefilled(.session),
        .savedResetExpiring(.dayBefore, expiresAt: start + 20 * hour),
        .savedResetExpiring(.hourBefore, expiresAt: start + 1_800),
        .resetApplied,
        .needsAttention(.resetNeedsAttention),
        .needsAttention(.signInRequired),
        .needsAttention(.wrongAccount),
        .needsAttention(.monitoringStopped),
    ]
    for notice in notices {
        let delivery = AlertDelivery(id: "x", account: ref, name: "Work", notice: notice)
        let userInfo = AlertRoute.userInfo(for: delivery)
        #expect(userInfo == ["account": ref.token])
        #expect(AlertRoute.account(from: userInfo) == ref)
        let text = AlertText.make(for: delivery, now: start)
        #expect(!text.title.isEmpty && text.body.contains("Work"))
        #expect(!(text.title + text.body).contains("@"))
    }
    let test = AlertDelivery(id: "test", account: nil, name: "", notice: .test)
    #expect(AlertRoute.userInfo(for: test).isEmpty)
    #expect(AlertRoute.account(from: [:]) == nil)
    #expect(AlertRoute.account(from: ["account": "codex:not-a-uuid"]) == nil)
    #expect(AlertText.make(for: test, now: start).title == "Second Wind notifications are on")
    #expect(AlertText.windowName(.modelWeekly("Sonnet only")) == "Sonnet weekly")
}

@Test func testNoticeAsksPermissionOnlyWhenNeverAsked() async throws {
    let clock = AlertClock(start)

    let undetermined = FakeNotifier(status: .notDetermined)
    try await router(temporaryDirectory(), undetermined, clock).sendTest()
    #expect(await undetermined.permissionRequests == 1)
    #expect(await undetermined.shown.map(\.notice) == [.test])

    let allowed = FakeNotifier(status: .allowed)
    try await router(temporaryDirectory(), allowed, clock).sendTest()
    #expect(await allowed.permissionRequests == 0)
    #expect(await allowed.shown.count == 1)

    let denied = FakeNotifier(status: .denied)
    await #expect(throws: AlertTestError.notAllowed) {
        try await router(temporaryDirectory(), denied, clock).sendTest()
    }
    #expect(await denied.shown.isEmpty)

    let declined = FakeNotifier(status: .notDetermined, grant: .denied)
    let alerts = router(temporaryDirectory(), declined, clock)
    try await alerts.setPreferences(refillOnly)
    #expect(await declined.permissionRequests == 1)
    try await alerts.setPreferences(.off)
    #expect(await declined.permissionRequests == 1)
}

@Test func permissionStatusAndSettingsLinkMapping() {
    #expect(UserNotificationCenterNotifier.status(.notDetermined) == .notDetermined)
    #expect(UserNotificationCenterNotifier.status(.denied) == .denied)
    #expect(UserNotificationCenterNotifier.status(.authorized) == .allowed)
    #expect(UserNotificationCenterNotifier.status(.provisional) == .allowed)
    #expect(
        NotificationSettingsLink.url(bundleIdentifier: "com.nickymolina.second-wind").absoluteString
            == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.nickymolina.second-wind"
    )
    #expect(NotificationSettingsLink.url(bundleIdentifier: nil) == NotificationSettingsLink.fallbackURL)
}
