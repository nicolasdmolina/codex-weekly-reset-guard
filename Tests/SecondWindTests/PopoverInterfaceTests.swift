import Foundation
import Testing
@testable import SecondWind
@testable import SecondWindCore

// Popover surfaces: display conventions, the quota-to-row adapter, the header summary, inline
// account editing, notification settings and notification navigation. Synthetic data only.

private let reference = PreviewFixtures.reference
private let codexA = AccountRef(provider: .codex, id: UUID(uuidString: "C0DE0000-0000-4000-8000-0000000000A1")!)
private let codexB = AccountRef(provider: .codex, id: UUID(uuidString: "C0DE0000-0000-4000-8000-0000000000B2")!)
private let claudeA = AccountRef(provider: .claude, id: UUID(uuidString: "C1A0DE00-0000-4000-8000-0000000000A1")!)

private struct Failure: LocalizedError {
    let errorDescription: String?
}

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private let posix = Locale(identifier: "en_US_POSIX")

@MainActor
private func settle(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
}

@MainActor
private func liveInterface() -> GuardInterfaceModel {
    GuardInterfaceModel(isPreview: false, isReadOnly: false, preferenceDefaults: nil, permission: .allowed)
}

private func codexRecord(
    _ account: AccountRef,
    session: Double?,
    weekly: Double,
    weeklyResetsIn: TimeInterval = 86_400,
    observedAgo: TimeInterval = 30,
    inventory: ResetInventoryReport
) -> QuotaAccountRecord {
    var windows = [QuotaWindow(kind: .weekly, usedPercent: 100 - weekly, resetsAt: reference.addingTimeInterval(weeklyResetsIn))]
    if let session {
        windows.insert(QuotaWindow(kind: .session, usedPercent: 100 - session, resetsAt: reference.addingTimeInterval(3_600)), at: 0)
    }
    return QuotaAccountRecord(
        provider: .codex,
        accountID: account.id,
        lastSuccess: QuotaObservation(
            observedAt: reference.addingTimeInterval(-observedAgo),
            windows: windows,
            unreportedWindows: session == nil ? [.session] : [],
            inventory: inventory
        )
    )
}

private func inventory(_ count: Int, _ expiries: ResetCreditExpiries) -> ResetInventoryReport {
    .reported(ResetInventorySnapshot(availableCount: count, expiries: expiries, fetchedAt: reference.addingTimeInterval(-30)))
}

private func presentation(_ account: AccountRef, name: String, record: QuotaAccountRecord?, status: GuardProfileStatus = .healthy, autoReset: Bool = false) -> GuardProfilePresentation {
    GuardProfilePresentation(
        id: account.id.uuidString.lowercased(),
        displayName: name,
        accountHint: "x•••@example.com",
        weeklyRemainingPercent: nil,
        naturalResetAt: nil,
        availableResetCount: 0,
        nearestResetExpiry: nil,
        status: status,
        detail: "",
        autoResetEnabled: autoReset,
        quota: record
    )
}

// MARK: - Identity and conventions

@Test func accountTokenRoundTripsAndRejectsMalformedValues() {
    #expect(codexA.token == "codex:c0de0000-0000-4000-8000-0000000000a1")
    #expect(AccountRef(token: codexA.token) == codexA)
    #expect(AccountRef(token: claudeA.token.uppercased()) == nil)
    for bad in ["", "codex", "codex:", "openai:\(codexA.id)", "codex:not-a-uuid", ":\(codexA.id)"] {
        #expect(AccountRef(token: bad) == nil)
    }
    #expect(AccountRef(provider: .codex, rawID: "profile-one") == nil)
    #expect(AccountRef(provider: .claude, rawID: claudeA.id.uuidString.lowercased()) == claudeA)
}

@Test func usedAndRemainingAlwaysAddUpAndCarryTheirWord() {
    #expect(QuotaConvention.remaining.text(remaining: 61.9) == "61% left")
    #expect(QuotaConvention.used.text(remaining: 61.9) == "39% used")
    for value in stride(from: -5.0, through: 105, by: 0.7) {
        #expect(QuotaConvention.remaining.percent(remaining: value) + QuotaConvention.used.percent(remaining: value) == 100)
    }
    #expect(QuotaConvention.remaining.percent(remaining: 0.4) == 0)
}

@Test func resetTimesReadAsCountdownsOrClockTimes() {
    func at(_ seconds: TimeInterval) -> Date { reference.addingTimeInterval(seconds) }
    #expect(QuotaTimeFormat.countdown(to: at(40 * 60), from: reference) == "in 40m")
    #expect(QuotaTimeFormat.countdown(to: at(3 * 3_600 + 40 * 60), from: reference) == "in 3h 40m")
    #expect(QuotaTimeFormat.countdown(to: at(2 * 3_600), from: reference) == "in 2h")
    #expect(QuotaTimeFormat.countdown(to: at(5 * 86_400 + 9 * 3_600), from: reference) == "in 5d 9h")
    #expect(QuotaTimeFormat.countdown(to: at(12 * 86_400 + 3_600), from: reference) == "in 12d")
    #expect(QuotaTimeFormat.countdown(to: at(-60), from: reference) == nil)
    #expect(QuotaTimeFormat.resetText(at(-60), reference: reference, style: .exact) == nil)

    // 2026-07-29 04:40 UTC. Foundation puts a narrow no-break space before AM/PM.
    func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }
    #expect(plain(QuotaTimeFormat.clock(at(3_600), reference: reference, calendar: utc, locale: posix)) == "5:40 AM")
    #expect(plain(QuotaTimeFormat.clock(at(2 * 86_400), reference: reference, calendar: utc, locale: posix)) == "Fri 4:40 AM")
    #expect(plain(QuotaTimeFormat.clock(at(10 * 86_400), reference: reference, calendar: utc, locale: posix)) == "Aug 8")
    #expect(plain(QuotaTimeFormat.expiry(at(3_600), reference: reference, calendar: utc, locale: posix)) == "today 5:40 AM")
    #expect(plain(QuotaTimeFormat.expiry(at(20 * 3_600), reference: reference, calendar: utc, locale: posix)) == "tomorrow 12:40 AM")
    #expect(plain(QuotaTimeFormat.expiry(at(3 * 86_400), reference: reference, calendar: utc, locale: posix)) == "Sat 4:40 AM")
    #expect(plain(QuotaTimeFormat.expiry(at(20 * 86_400), reference: reference, calendar: utc, locale: posix)) == "Aug 18")
    #expect(QuotaTimeFormat.age(of: at(-20), reference: reference) == "just now")
    #expect(QuotaTimeFormat.age(of: at(-14 * 60), reference: reference) == "14 min ago")
    #expect(QuotaTimeFormat.age(of: at(-3 * 3_600), reference: reference) == "3 h ago")
    #expect(QuotaTimeFormat.age(of: at(-3 * 86_400), reference: reference) == "3 days ago")
}

@Test @MainActor func displayPreferencesPersistLiveButNeverFromPreviews() throws {
    let suite = "second-wind-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let preview = GuardInterfaceModel(isPreview: true, isReadOnly: false, preferenceDefaults: defaults)
    preview.preferences.quota = .used
    #expect(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix("display.") })

    let live = GuardInterfaceModel(isPreview: false, isReadOnly: false, preferenceDefaults: defaults)
    #expect(live.preferences == DisplayPreferences())
    live.preferences.quota = .used
    live.toggleResetTimeStyle()
    let reloaded = DisplayPreferences.load(from: defaults)
    #expect(reloaded == DisplayPreferences(quota: .used, resetTimes: .exact))

    defaults.set("sideways", forKey: "display.quotaConvention")
    #expect(DisplayPreferences.load(from: defaults).quota == .remaining)
}

// MARK: - Quota adapter

@Test func unreportedWindowIsUnknownNeverZero() {
    let record = codexRecord(codexA, session: nil, weekly: 1, inventory: inventory(0, .listed([])))
    let display = QuotaDisplayBuilder.codex(presentation(codexA, name: "Work", record: record), now: reference)
    let session = display.windows.first
    #expect(session?.id == "session")
    #expect(session?.remaining == nil)
    #expect(session?.state == .unreported)
    #expect(display.windows.map(\.id) == ["session", "weekly"])
    #expect(display.headline?.id == "weekly")
    #expect(display.warningWindow?.id == "weekly")
}

@Test func exhaustedSessionLeadsOverHealthyWeek() {
    let record = codexRecord(codexA, session: 0, weekly: 75, inventory: inventory(2, .listed([.never, .never])))
    let display = QuotaDisplayBuilder.codex(presentation(codexA, name: "Personal", record: record), now: reference)
    #expect(display.headline?.id == "session")
    #expect(display.headline?.level == .exhausted)
    #expect(display.isConfirmed)
}

@Test func passedResetAwaitsRefillAndStaleReadingsStayVisible() {
    let record = codexRecord(codexA, session: 50, weekly: 4, weeklyResetsIn: -60, observedAgo: 14 * 60, inventory: inventory(0, .listed([])))
    let display = QuotaDisplayBuilder.codex(presentation(codexA, name: "Work", record: record), now: reference)
    let weekly = display.windows.first { $0.id == "weekly" }
    #expect(weekly?.state == .awaitingRefill)
    #expect(weekly?.remaining == 4)
    #expect(display.windows.first { $0.id == "session" }?.state == .stale)
    #expect(display.awaitingRefill)
    #expect(display.headline?.id == "session")
    #expect(!display.isConfirmed)
    #expect(display.age == .stale(reference.addingTimeInterval(-14 * 60)))
}

@Test func inventoryDistinguishesUnknownZeroListedAndUnlisted() {
    func inventoryDisplay(_ report: ResetInventoryReport) -> InventoryDisplay? {
        let record = codexRecord(codexA, session: 80, weekly: 60, inventory: report)
        return QuotaDisplayBuilder.codex(presentation(codexA, name: "A", record: record), now: reference).inventory
    }
    #expect(inventoryDisplay(.omitted) == .unknown(lastCount: nil, checkedAt: nil))
    guard case let .known(zero, _, _, _, _)? = inventoryDisplay(inventory(0, .listed([]))) else {
        Issue.record("A confirmed zero must stay known")
        return
    }
    #expect(zero == 0)

    let capped = inventoryDisplay(inventory(3, .listed([.on(reference.addingTimeInterval(3_600)), .never])))
    #expect(capped?.unlistedCount == 1)
    #expect(capped?.hasDetail == true)
    if case let .known(_, listed, datesReported, _, _)? = capped {
        #expect(listed == [.on(reference.addingTimeInterval(3_600)), .doesNotExpire])
        #expect(datesReported)
    }

    let countOnly = inventoryDisplay(inventory(2, .unlisted))
    #expect(countOnly?.unlistedCount == 0)
    #expect(countOnly?.hasDetail == false)
    if case let .known(_, _, datesReported, _, _)? = countOnly { #expect(!datesReported) }

    let single = inventoryDisplay(inventory(1, .listed([.on(reference.addingTimeInterval(3_600))])))
    #expect(single?.hasDetail == false)

    var unknownAfterKnown = codexRecord(codexA, session: 80, weekly: 60, observedAgo: 3 * 3_600, inventory: inventory(1, .listed([.never])))
    unknownAfterKnown.recordSuccess(QuotaObservation(
        observedAt: reference.addingTimeInterval(-20),
        windows: [QuotaWindow(kind: .weekly, usedPercent: 40, resetsAt: reference.addingTimeInterval(86_400))],
        inventory: .omitted
    ))
    let display = QuotaDisplayBuilder.codex(presentation(codexA, name: "A", record: unknownAfterKnown), now: reference)
    #expect(display.inventory == .unknown(lastCount: 1, checkedAt: reference.addingTimeInterval(-30)))
    #expect(display.inventoryUnconfirmed)
    #expect(!display.isConfirmed)
}

// MARK: - Header summary

@Test @MainActor func allClearRequiresEveryProviderLoadedAndEveryAccountConfirmed() {
    let healthy = presentation(codexA, name: "Personal", record: codexRecord(codexA, session: 80, weekly: 61, inventory: inventory(1, .listed([.never]))))
    let model = GuardAppModel(profiles: [healthy], isPreview: true, referenceDate: reference)
    let interface = GuardInterfaceModel(isPreview: true, isReadOnly: false, preferenceDefaults: nil)
    var summary = PopoverSummary.make(model: model, interface: interface, now: reference)
    #expect(summary.text == "All clear · lowest 61% left")
    #expect(summary.isConfident)
    #expect(summary.menuBarPercent == 61)
    #expect(summary.menuBarTitle == "61% left")
    #expect(summary.accessibilityValue == "lowest 61% left. All clear · lowest 61% left")
    #expect(summary.tooltip == "Second Wind: lowest 61% left")

    interface.preferences.quota = .used
    summary = PopoverSummary.make(model: model, interface: interface, now: reference)
    #expect(summary.text == "All clear · highest 39% used")
    #expect(summary.menuBarPercent == 39)
    #expect(summary.menuBarTitle == "39% used")
    #expect(summary.tooltip == "Second Wind: highest 39% used")

    interface.preferences.quota = .remaining
    interface.providerDidFail(.claude, reason: "Its saved account list could not be read.")
    summary = PopoverSummary.make(model: model, interface: interface, now: reference)
    #expect(summary.text == "Claude did not load")
    #expect(summary.tone == .critical)
    #expect(!summary.isConfident)
    #expect(summary.showsAttentionIcon)
    #expect(interface.notices.contains { $0.text.contains("Its saved account list could not be read.") })
}

@Test @MainActor func unknownInventoryOrStaleReadingBlocksAllClear() {
    let unknown = presentation(codexA, name: "Work", record: codexRecord(codexA, session: 80, weekly: 47, inventory: .omitted), autoReset: true)
    let stale = presentation(codexB, name: "Home", record: codexRecord(codexB, session: 80, weekly: 70, observedAgo: 600, inventory: inventory(0, .listed([]))))
    let interface = GuardInterfaceModel(isPreview: true, isReadOnly: false, preferenceDefaults: nil)
    let one = PopoverSummary.make(model: GuardAppModel(profiles: [unknown], isPreview: true, referenceDate: reference), interface: interface, now: reference)
    #expect(one.text == "1 account not confirmed")
    #expect(!one.isConfident)
    #expect(one.menuBarPercent == 47)
    #expect(one.menuBarTitle == "47% left")
    #expect(one.tooltip == "Second Wind: lowest 47% left. 1 account not confirmed")
    let two = PopoverSummary.make(model: GuardAppModel(profiles: [unknown, stale], isPreview: true, referenceDate: reference), interface: interface, now: reference)
    #expect(two.text == "2 accounts not confirmed")
    #expect(two.menuBarPercent == 47, "Stale windows never set the menu bar figure")
}

@Test @MainActor func lowWindowIsNamedEvenWithAutoRedeemOff() {
    let low = presentation(codexA, name: "Personal", record: codexRecord(codexA, session: 0, weekly: 75, inventory: inventory(0, .listed([]))), status: .nearLimit)
    let interface = GuardInterfaceModel(isPreview: true, isReadOnly: false, preferenceDefaults: nil)
    let summary = PopoverSummary.make(model: GuardAppModel(profiles: [low], isPreview: true, referenceDate: reference), interface: interface, now: reference)
    #expect(summary.text == "Personal 5-hour limit used up")
    #expect(summary.tone == .caution)
    #expect(summary.menuBarPercent == 0)
}

@Test @MainActor func blockedUsageWarnsAndUnknownAccessIsNeverAllClear() {
    let blocked = codexRecordWithAccess(codexA, access: .blocked)
    let unknown = codexRecordWithAccess(codexB, access: .unknown)
    let interface = GuardInterfaceModel(isPreview: true, isReadOnly: false, preferenceDefaults: nil)
    let both = PopoverSummary.make(
        model: GuardAppModel(profiles: [
            presentation(codexA, name: "Personal", record: blocked),
            presentation(codexB, name: "Work", record: unknown),
        ], isPreview: true, referenceDate: reference),
        interface: interface,
        now: reference
    )
    #expect(both.text == "Personal usage blocked")
    #expect(both.tone == .caution)
    #expect(both.menuBarTitle == "64% left", "Percentages stay visible when usage is blocked")
    #expect(!both.isConfident)

    let onlyUnknown = PopoverSummary.make(
        model: GuardAppModel(profiles: [presentation(codexB, name: "Work", record: unknown)], isPreview: true, referenceDate: reference),
        interface: interface,
        now: reference
    )
    #expect(onlyUnknown.text == "1 account not confirmed")
    let display = QuotaDisplayBuilder.codex(presentation(codexA, name: "Personal", record: blocked), now: reference)
    #expect(display.isBlocked)
    #expect(display.headline?.remaining == 64)
}

private func codexRecordWithAccess(_ account: AccountRef, access: IncludedUsageAccess) -> QuotaAccountRecord {
    QuotaAccountRecord(
        provider: .codex,
        accountID: account.id,
        lastSuccess: QuotaObservation(
            observedAt: reference.addingTimeInterval(-30),
            windows: [
                QuotaWindow(kind: .session, usedPercent: 12, resetsAt: reference.addingTimeInterval(3_600)),
                QuotaWindow(kind: .weekly, usedPercent: 36, resetsAt: reference.addingTimeInterval(86_400)),
            ],
            inventory: inventory(1, .listed([.never])),
            includedUsageAccess: access
        )
    )
}

// MARK: - Rename and remove

@Test @MainActor func renameValidatesSavesAndKeepsFailuresOnTheRow() async {
    let interface = liveInterface()
    var calls: [(AccountRef, String)] = []
    var failNext = true
    interface.renameAccount = { account, name in
        calls.append((account, name))
        if failNext {
            failNext = false
            throw Failure(errorDescription: "Second Wind is checking or signing in to this account. Try again in a moment.")
        }
    }

    interface.beginRename(codexA, currentName: "Work")
    interface.draftName = "  \n "
    interface.commitRename(currentName: "Work")
    #expect(interface.accountFeedback[codexA] == .failure("Enter a name with at least one letter or number."))
    #expect(calls.isEmpty)

    interface.draftName = "  Work  "
    interface.commitRename(currentName: "Work")
    #expect(interface.editor == nil, "An unchanged name closes the editor without a write")
    #expect(calls.isEmpty)

    interface.beginRename(codexA, currentName: "Work")
    interface.draftName = "Client   work"
    interface.commitRename(currentName: "Work")
    interface.commitRename(currentName: "Work")
    await settle { !interface.busyAccounts.contains(codexA) }
    #expect(calls.count == 1, "A second submit while saving is ignored")
    #expect(calls.first?.1 == "Client work")
    #expect(interface.editor == .renaming(codexA), "A failed save keeps the draft open")
    #expect(interface.accountFeedback[codexA] == .failure(
        "Could not rename this account. Second Wind is checking or signing in to this account. Try again in a moment."
    ))

    interface.commitRename(currentName: "Work")
    await settle { !interface.busyAccounts.contains(codexA) }
    #expect(calls.count == 2)
    #expect(interface.editor == nil)
    #expect(interface.accountFeedback[codexA] == nil)
}

@Test @MainActor func renameFieldStopsAtTheProviderLimit() {
    let interface = liveInterface()
    interface.beginRename(claudeA, currentName: "Studio")
    interface.draftName = String(repeating: "a", count: 80)
    interface.limitDraft(for: .claude)
    #expect(interface.draftName.count == 48)
    interface.draftName = String(repeating: "b", count: 80)
    interface.limitDraft(for: .codex)
    #expect(interface.draftName.count == 60)
}

@Test @MainActor func removeNeedsConfirmationAndReportsFailureUntilRetried() async {
    let interface = liveInterface()
    var removed: [AccountRef] = []
    var failNext = true
    interface.removeAccount = { account in
        if failNext {
            failNext = false
            throw Failure(errorDescription: "It is no longer in the list.")
        }
        removed.append(account)
    }

    interface.remove(codexA, displayName: "Personal")
    #expect(removed.isEmpty, "Removal without confirmation does nothing")

    interface.confirmRemoval(codexA)
    interface.remove(codexA, displayName: "Personal")
    await settle { !interface.busyAccounts.contains(codexA) }
    #expect(removed.isEmpty)
    #expect(interface.editor == .confirmingRemoval(codexA))
    #expect(interface.accountFeedback[codexA] == .failure("Could not remove Personal. It is no longer in the list."))

    interface.remove(codexA, displayName: "Personal")
    await settle { !interface.busyAccounts.contains(codexA) }
    #expect(removed == [codexA])
    #expect(interface.editor == nil)
    #expect(interface.accountFeedback[codexA] == nil)
    #expect(interface.transientNotice == "Removed Personal.")
}

@Test @MainActor func reportedFailuresSurviveSnapshotsUntilDismissed() {
    let model = PreviewFixtures.model(for: .healthy)
    let interface = PreviewFixtures.interface(for: model)
    let account = AccountRef(provider: .codex, rawID: model.profiles[0].id)!
    interface.reportFailure("Could not start the isolated Codex sign-in.", for: account)
    model.banner = nil
    model.profiles = model.profiles
    #expect(interface.accountFeedback[account] == .failure("Could not start the isolated Codex sign-in."))
    interface.dismissFeedback(for: account)
    #expect(interface.accountFeedback[account] == nil)
}

// MARK: - Mode gating

@Test @MainActor func previewAndReadOnlyNeverCallLiveAccountOrAlertCallbacks() async {
    for isPreview in [true, false] {
        let interface = GuardInterfaceModel(isPreview: isPreview, isReadOnly: !isPreview, preferenceDefaults: nil, permission: .notDetermined)
        var calls = 0
        interface.renameAccount = { _, _ in calls += 1 }
        interface.removeAccount = { _ in calls += 1 }
        interface.requestNotificationPermission = { calls += 1; return .allowed }
        interface.sendTestNotification = { calls += 1 }
        interface.setAlertPreferences = { _ in calls += 1 }
        interface.openNotificationSettings = { calls += 1 }
        interface.preflightCommand = { _ in calls += 1; return "SecondWind --preflight" }

        interface.beginRename(codexA, currentName: "A")
        interface.draftName = "B"
        interface.commitRename(currentName: "A")
        interface.confirmRemoval(codexA)
        interface.remove(codexA, displayName: "A")
        if isPreview {
            interface.allowNotifications()
            interface.sendTest()
            interface.openSystemNotificationSettings()
            interface.copyPreflightCommand(for: codexA)
        }
        interface.setAlert(\.savedResetExpiry, enabled: true)
        interface.setLaunchAtLogin(true)
        await settle { false }
        #expect(calls == 0, "isPreview: \(isPreview)")
        if !isPreview {
            #expect(interface.editor == nil, "Read-only cannot open account editors")
            #expect(interface.alertPreferences == .off)
            #expect(interface.preflightCommand(for: codexA) == nil)
        }
    }
}

// MARK: - Notifications and alerts

@Test @MainActor func alertSwitchMovesOnlyAfterTheSettingIsSaved() async {
    let interface = liveInterface()
    interface.setAlertPreferences = { _ in throw Failure(errorDescription: "Try again.") }
    interface.setAlert(\.limitRefilled, enabled: true)
    await settle { !interface.pendingAlertChange }
    #expect(interface.alertPreferences == .off)
    #expect(interface.settingsFeedback == .failure("Could not save the alert setting. Try again."))

    var saved: [AlertPreferences] = []
    interface.setAlertPreferences = { saved.append($0) }
    interface.setAlert(\.limitRefilled, enabled: true)
    await settle { !interface.pendingAlertChange }
    #expect(saved == [AlertPreferences(savedResetExpiry: false, limitRefilled: true)])
    #expect(interface.alertPreferences.limitRefilled)
}

@Test @MainActor func turningAnAlertOnAsksForPermissionOnceAndExplainsADenial() async {
    let interface = GuardInterfaceModel(isPreview: false, isReadOnly: false, preferenceDefaults: nil, permission: .notDetermined)
    var requests = 0
    interface.requestNotificationPermission = { requests += 1; return .denied }
    interface.setAlertPreferences = { _ in }
    interface.setAlert(\.savedResetExpiry, enabled: true)
    await settle { !interface.pendingAlertChange }
    #expect(requests == 1)
    #expect(interface.permission == .denied)
    #expect(interface.alertPreferences.savedResetExpiry)
    #expect(interface.settingsFeedback == .failure(
        "Alert saved, but notifications are off for Second Wind. Turn them on in System Settings."
    ))
}

@Test @MainActor func testNotificationReportsEveryOutcomeInline() async {
    let denied = GuardInterfaceModel(isPreview: false, isReadOnly: false, preferenceDefaults: nil, permission: .denied)
    var sent = 0
    denied.sendTestNotification = { sent += 1 }
    denied.sendTest()
    await settle { !denied.isSendingTest }
    #expect(sent == 0)
    #expect(denied.settingsFeedback?.isFailure == true)

    let allowed = liveInterface()
    allowed.sendTestNotification = { sent += 1 }
    allowed.sendTest()
    await settle { !allowed.isSendingTest }
    #expect(sent == 1)
    #expect(allowed.settingsFeedback == .success("Test sent. It should appear in the top-right corner of your screen."))

    let failing = liveInterface()
    failing.sendTestNotification = { throw Failure(errorDescription: "Notifications are not available.") }
    failing.sendTest()
    await settle { !failing.isSendingTest }
    #expect(failing.settingsFeedback == .failure("The test did not send. Notifications are not available."))
}

@Test @MainActor func settingsPageReadsCurrentPermissionAndPreferences() async {
    let interface = liveInterface()
    interface.readNotificationPermission = { .notDetermined }
    interface.readAlertPreferences = { AlertPreferences(savedResetExpiry: true, limitRefilled: false) }
    interface.showSettings()
    await settle { interface.permission == .notDetermined }
    #expect(interface.page == .settings)
    #expect(interface.permission == .notDetermined)
    #expect(interface.alertPreferences.savedResetExpiry)
    interface.showAccounts()
    #expect(interface.page == .accounts)
    #expect(interface.settingsFeedback == nil)
}

@Test @MainActor func launchAtLoginFailureStaysOnTheSettingsPage() {
    var enabled = false
    let interface = GuardInterfaceModel(
        isPreview: false,
        isReadOnly: false,
        preferenceDefaults: nil,
        launchAtLogin: (read: { enabled }, write: { _ in throw Failure(errorDescription: nil) })
    )
    interface.setLaunchAtLogin(true)
    #expect(!interface.launchAtLogin)
    #expect(interface.launchAtLoginError != nil)
    enabled = true
    interface.showSettings()
    #expect(interface.launchAtLogin)
    #expect(interface.launchAtLoginError == nil)
}

// MARK: - Notification navigation

@Test func revealResolutionWaitsOnlyWhileTheProviderIsLoading() {
    let present: Set<AccountRef> = [codexA]
    #expect(RevealResolution.resolve(target: codexA, present: present, load: .loading, published: false) == .found)
    #expect(RevealResolution.resolve(target: codexB, present: present, load: .loading, published: false) == .waiting)
    #expect(RevealResolution.resolve(target: codexB, present: present, load: .loading, published: true) == .missing)
    #expect(RevealResolution.resolve(target: codexB, present: present, load: .loaded, published: false) == .missing)
    #expect(RevealResolution.resolve(target: codexB, present: [], load: .failed("x"), published: false) == .unavailable("x"))
    #expect(RevealResolution.resolve(target: codexA, present: present, load: .failed("x"), published: true) == .found)
}

@Test @MainActor func coldStartRevealWaitsForTheProviderThenHighlightsTheAccount() async {
    let model = GuardAppModel(profiles: [], isPreview: false)
    let interface = liveInterface()
    interface.attach(model)
    interface.reveal(claudeA)
    #expect(interface.pendingReveal == claudeA)

    model.isReady = true
    model.profiles = [presentation(codexA, name: "Personal", record: nil)]
    await settle { false }
    #expect(interface.pendingReveal == claudeA, "Codex loading says nothing about a Claude target")

    model.claudeProfiles = [
        ClaudeProfilePresentation(
            id: claudeA.id.uuidString.lowercased(), displayName: "Studio", accountHint: "s•••@example.com",
            planName: nil, windows: [], status: .healthy, detail: "", signInURL: nil
        ),
    ]
    await settle { interface.pendingReveal == nil }
    #expect(interface.scrollTarget == claudeA)
    #expect(interface.highlighted == claudeA)
    #expect(interface.notices.isEmpty)
}

@Test @MainActor func revealOfARemovedOrUnloadableAccountExplainsWhy() async {
    let model = GuardAppModel(profiles: [presentation(codexA, name: "Personal", record: nil)], isPreview: false)
    model.isReady = true
    let interface = liveInterface()
    interface.attach(model)
    interface.providerDidLoad(.codex)
    interface.reveal(codexB)
    #expect(interface.pendingReveal == nil)
    #expect(interface.highlighted == nil)
    #expect(interface.notices.map(\.text) == ["That Codex account is no longer in Second Wind."])

    interface.reveal(claudeA)
    #expect(interface.pendingReveal == claudeA)
    interface.providerDidFail(.claude, reason: "Its saved account list could not be read.")
    #expect(interface.pendingReveal == nil)
    #expect(interface.notices.map(\.text).contains("Could not open that Claude account because its accounts did not load."))
    #expect(interface.notices.map(\.text).contains("Claude accounts could not load. Its saved account list could not be read."))
}

@Test @MainActor func revealClosesSettingsAndAnyOpenEditor() {
    let model = GuardAppModel(profiles: [presentation(codexA, name: "Personal", record: nil)], isPreview: false)
    model.isReady = true
    let interface = liveInterface()
    interface.attach(model)
    interface.providerDidLoad(.codex)
    interface.beginRename(codexA, currentName: "Personal")
    interface.showSettings()
    interface.reveal(codexA)
    #expect(interface.page == .accounts)
    #expect(interface.editor == nil)
    #expect(interface.highlighted == codexA)
}

// MARK: - Fixtures

@Test @MainActor func everyPreviewIsSyntheticPinnedAndUsesTypedAccountIDs() throws {
    try PreviewFixtures.validate()
    for kind in PreviewKind.allCases {
        let model = PreviewFixtures.model(for: kind)
        let interface = PreviewFixtures.interface(for: model)
        #expect(interface.isPreview, "\(kind.rawValue)")
        #expect(model.referenceDate == reference, "\(kind.rawValue)")
        for profile in model.profiles {
            #expect(!profile.accountHint.contains("@") || profile.accountHint.contains("•••@example.com"))
        }
    }
    #expect(PreviewFixtures.interface(for: PreviewFixtures.model(for: .settings)).page == .settings)
    #expect(PreviewFixtures.interface(for: PreviewFixtures.model(for: .usedExact)).preferences == DisplayPreferences(quota: .used, resetTimes: .exact))
}

private extension GuardInterfaceModel.Feedback {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
