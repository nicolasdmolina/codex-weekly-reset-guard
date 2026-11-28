import Foundation
import Testing
@testable import SecondWind
@testable import SecondWindCore

private let now = Date(timeIntervalSince1970: 2_000_000_000)
private let mini = SyncDeviceID(UUID(uuidString: "11111111-0000-4000-8000-000000000001")!)
private let workID = UUID(uuidString: "C0DE0000-0000-4000-8000-000000000002")!
private let remoteWorkID = UUID(uuidString: "C0DE0000-0000-4000-8000-0000000000A2")!

private func localWork(autoReset: Bool = false) -> GuardProfilePresentation {
    GuardProfilePresentation(
        id: workID.uuidString.lowercased(),
        displayName: "Work",
        accountHint: "w•••@example.com",
        weeklyRemainingPercent: 50,
        naturalResetAt: nil,
        availableResetCount: 1,
        nearestResetExpiry: nil,
        status: .healthy,
        detail: "",
        autoResetEnabled: autoReset,
        email: "work@example.com"
    )
}

private func miniSnapshot(autoRedeem: Bool, publishedAt: Date = now, acceptsCommands: Bool = true) -> DeviceSnapshot {
    DeviceSnapshot(
        deviceID: mini,
        deviceName: "Mac mini",
        publishedAt: publishedAt,
        accounts: [SharedAccount(
            profileID: remoteWorkID, provider: .codex, displayName: "Work", email: "Work@example.com",
            autoRedeemEnabled: autoRedeem, windows: []
        )],
        appliedCommandIDs: [],
        acceptsCommands: acceptsCommands
    )
}

@Test @MainActor func noCommandIsSentToAMacThatCannotReadCommands() {
    let model = GuardAppModel(referenceDate: now)
    let device = miniSnapshot(autoRedeem: false, acceptsCommands: false)
    model.remoteDevices = [device]
    var sent: [Bool] = []
    model.onSetRemoteAutoReset = { _, _, enabled in sent.append(enabled) }
    model.setRemoteAutoReset(device: device, account: device.accounts[0], enabled: true)
    model.setRemoteAutoReset(device: device, account: device.accounts[0], enabled: false)
    #expect(sent.isEmpty)
    #expect(model.pendingRemoteCommands.isEmpty)

    let accepting = miniSnapshot(autoRedeem: false, acceptsCommands: true)
    model.remoteDevices = [accepting]
    model.setRemoteAutoReset(device: accepting, account: accepting.accounts[0], enabled: true)
    #expect(sent == [true])
}

@Test @MainActor func localSwitchRefusesAutoRedeemThatAnotherMacAlreadyRuns() {
    let model = GuardAppModel(profiles: [localWork()], referenceDate: now)
    model.remoteDevices = [miniSnapshot(autoRedeem: true)]
    var toggles: [(String, Bool)] = []
    var failures: [String] = []
    model.onToggleAutoReset = { toggles.append(($0, $1)) }
    model.onAccountActionFailure = { _, message in failures.append(message) }

    model.setAutoReset(profileID: workID.uuidString.lowercased(), enabled: true)
    #expect(toggles.isEmpty)
    #expect(failures == ["Auto-redeem is already on for this account on Mac mini. Turn it off there first."])

    // Turning off is never blocked, and a stale snapshot no longer holds the lock.
    model.setAutoReset(profileID: workID.uuidString.lowercased(), enabled: false)
    model.remoteDevices = [miniSnapshot(autoRedeem: true, publishedAt: now.addingTimeInterval(-11 * 60))]
    model.setAutoReset(profileID: workID.uuidString.lowercased(), enabled: true)
    #expect(toggles.map(\.1) == [false, true])
}

@Test @MainActor func remoteEnableIsRefusedWhileThisMacRedeemsTheSameAccount() {
    let model = GuardAppModel(profiles: [localWork(autoReset: true)], referenceDate: now)
    let device = miniSnapshot(autoRedeem: true, publishedAt: now.addingTimeInterval(-30))
    model.remoteDevices = [device]
    var sent: [Bool] = []
    var failures: [String] = []
    model.onSetRemoteAutoReset = { _, _, enabled in sent.append(enabled) }
    model.onAccountActionFailure = { _, message in failures.append(message) }

    model.setRemoteAutoReset(device: device, account: device.accounts[0], enabled: true)
    #expect(sent.isEmpty)
    #expect(failures == ["Auto-redeem is already on for this account on this Mac. Turn it off here first."])
    model.setRemoteAutoReset(device: device, account: device.accounts[0], enabled: false)
    #expect(sent == [false])

    // A change already waiting for the host is not sent again.
    model.pendingRemoteCommands[GuardAppModel.remoteKey(device: mini, account: device.accounts[0])] =
        PendingRemoteCommand(commandID: UUID(), enabled: false, issuedAt: now)
    model.setRemoteAutoReset(device: device, account: device.accounts[0], enabled: false)
    #expect(sent == [false])
}

@Test @MainActor func remoteCommandUsesOnlyTheSwitchPathAndItsChecks() async {
    let model = GuardAppModel(profiles: [localWork()], referenceDate: now)
    var applied: [(String, Bool)] = []
    var otherCalls = 0
    model.applyAutoReset = { id, enabled in applied.append((id, enabled)); return true }
    model.onCheckNow = { otherCalls += 1 }
    model.onReconnect = { _ in otherCalls += 1 }
    model.onAddProfile = { otherCalls += 1 }

    #expect(await model.applyRemoteAutoReset(profileID: workID, enabled: true) == true)
    #expect(applied.map(\.0) == [workID.uuidString.lowercased()])
    #expect(!(await model.applyRemoteAutoReset(profileID: UUID(), enabled: true)))

    model.remoteDevices = [miniSnapshot(autoRedeem: true)]
    #expect(!(await model.applyRemoteAutoReset(profileID: workID, enabled: true)))
    #expect(applied.count == 1)
    #expect(otherCalls == 0)

    let readOnly = GuardAppModel(profiles: [localWork()], isReadOnly: true, referenceDate: now)
    readOnly.applyAutoReset = { _, _ in Issue.record("Diagnostics must not change Auto-redeem"); return true }
    #expect(!(await readOnly.applyRemoteAutoReset(profileID: workID, enabled: false)))
}

@Test @MainActor func sharedAccountsCarryReadingsButNoMaskedHintOrSecrets() {
    var work = localWork(autoReset: true)
    work.quota = QuotaAccountRecord(
        provider: .codex,
        accountID: workID,
        lastSuccess: QuotaObservation(
            observedAt: now,
            windows: [QuotaWindow(kind: .weekly, usedPercent: 92, resetsAt: now.addingTimeInterval(86_400))],
            inventory: .reported(ResetInventorySnapshot(availableCount: 3, expiries: .unlisted, fetchedAt: now))
        )
    )
    let model = GuardAppModel(profiles: [work], referenceDate: now)
    let shared = model.sharedAccounts()
    #expect(shared.count == 1)
    #expect(shared[0].email == "work@example.com")
    #expect(shared[0].autoRedeemEnabled == true)
    #expect(shared[0].savedResetCount == 3)
    #expect(shared[0].windows.map(\.remainingPercent) == [8])
    #expect(shared[0].attentionMessage == nil)
}

@Test func remoteLowQuotaAlertsOncePerAccountWindowAndCycle() {
    var ledger = AlertLedger()
    let account = RemoteAlertAccount(device: mini, deviceName: "Mac mini", provider: .codex, profileID: remoteWorkID, name: "Work")
    let reset = now.addingTimeInterval(86_400)
    let low = QuotaWindow(kind: .weekly, usedPercent: 93, resetsAt: reset)

    let first = AlertPolicy.post(.remoteLowQuota(account, window: low), ledger: &ledger, now: now)
    #expect(first.deliveries.count == 1)
    #expect(first.deliveries[0].account == nil)
    #expect(first.deliveries[0].notice == .remoteLowQuota(low, provider: .codex, deviceName: "Mac mini"))
    #expect(first.deliveries[0].notice.needsDurableLedger)
    #expect(AlertPolicy.post(.remoteLowQuota(account, window: low), ledger: &ledger, now: now.addingTimeInterval(60)).deliveries.isEmpty)

    // A local roster with no accounts never prunes the remote entry.
    _ = AlertPolicy.keepOnly([], of: .codex, ledger: &ledger, now: now)
    #expect(AlertPolicy.post(.remoteLowQuota(account, window: low), ledger: &ledger, now: now.addingTimeInterval(120)).deliveries.isEmpty)

    // The other window, and the next cycle, alert once each.
    let session = QuotaWindow(kind: .session, usedPercent: 95, resetsAt: now.addingTimeInterval(3_600))
    #expect(AlertPolicy.post(.remoteLowQuota(account, window: session), ledger: &ledger, now: now).deliveries.count == 1)
    let next = QuotaWindow(kind: .weekly, usedPercent: 93, resetsAt: reset.addingTimeInterval(7 * 86_400))
    #expect(AlertPolicy.post(.remoteLowQuota(account, window: next), ledger: &ledger, now: reset.addingTimeInterval(60)).deliveries.count == 1)

    let text = AlertText.make(for: first.deliveries[0], now: now)
    #expect(text.title == "Codex weekly limit is low")
    #expect(text.body.hasPrefix("Work on Mac mini has 7% left."))
}

private struct SilentNotifier: AlertNotifier {
    func deliver(_ delivery: AlertDelivery, now: Date) async throws {}
    func cancel(_ ids: [String]) async {}
    func permission() async -> NotificationPermissionStatus { .allowed }
    func requestPermission() async -> NotificationPermissionStatus { .allowed }
}

@Test @MainActor func unreadableICloudFolderStillPublishesAndLogsBothSteps() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SecondWindSyncCoordinator-\(UUID().uuidString)", isDirectory: true)
    let shared = DeviceSyncFolder(root: root.appendingPathComponent("iCloud/Second Wind", isDirectory: true))
    let model = GuardAppModel(referenceDate: now)
    let interface = GuardInterfaceModel(isPreview: false, isReadOnly: false, preferenceDefaults: nil, syncStatus: .on)
    interface.providerDidLoad(.codex)
    interface.providerDidLoad(.claude)
    let log = RedactedEventLog(fileURL: root.appendingPathComponent("support/sync-events.json"))
    let stateURL = root.appendingPathComponent("support/sync-state.json")
    let coordinator = DeviceSyncCoordinator(
        model: model,
        interface: interface,
        alerts: AlertRouter(stateURL: nil, notifier: SilentNotifier()),
        stateURL: stateURL,
        log: log,
        locateFolder: { shared }
    )

    await coordinator.pass()
    #expect(interface.syncStatus == .on)
    let ok = try #require(try await log.entries().last)
    #expect(ok.kind == .syncPass)
    #expect(ok.fields == [
        "publish": "ok", "read": "ok", "acceptsCommands": "true", "devices": "0",
        "commandsListed": "0", "commandsDecoded": "0", "decisions": "",
    ])

    let devices = shared.root.appendingPathComponent("devices")
    // Listing fails while writing still works, as on the Mac mini.
    #expect(chmod(devices.path, 0o300) == 0)
    await coordinator.pass()
    #expect(chmod(devices.path, 0o700) == 0)
    #expect(interface.syncStatus == .readFailed)
    let failed = try #require(try await log.entries().last)
    #expect(failed.fields["publish"] == "ok")
    #expect(failed.fields["read"] == "failed")
    #expect(failed.fields["acceptsCommands"] == "false")
    #expect(failed.fields["readErrorDomain"] == NSCocoaErrorDomain)
    #expect(failed.fields["readErrorCode"] == String(NSFileReadNoPermissionError))
    #expect(failed.fields["readUnderlyingDomain"] == NSPOSIXErrorDomain)
    #expect(failed.fields["readUnderlyingCode"] == String(EACCES))

    let id = try #require(try await SecureStateStore<DeviceSyncState>(fileURL: stateURL).load()).deviceID
    let published = try #require(try shared.readSnapshots(excluding: SyncDeviceID()).first { $0.deviceID == id })
    #expect(!published.acceptsCommands)
}

// MARK: One card per account across Macs

private func sharedAccount(_ id: UUID, email: String, autoRedeem: Bool? = false, provider: QuotaProvider = .codex) -> SharedAccount {
    SharedAccount(profileID: id, provider: provider, displayName: "Account", email: email, autoRedeemEnabled: autoRedeem, windows: [])
}

private func device(_ id: SyncDeviceID, name: String, publishedAt: Date = now, accounts: [SharedAccount]) -> DeviceSnapshot {
    DeviceSnapshot(deviceID: id, deviceName: name, publishedAt: publishedAt, accounts: accounts, appliedCommandIDs: [], acceptsCommands: true)
}

private func reading(weeklyUsed: Double = 50, observedAt: Date = now.addingTimeInterval(-30)) -> QuotaAccountRecord {
    QuotaAccountRecord(
        provider: .codex,
        accountID: workID,
        lastSuccess: QuotaObservation(
            observedAt: observedAt,
            windows: [QuotaWindow(kind: .weekly, usedPercent: weeklyUsed, resetsAt: now.addingTimeInterval(86_400))],
            inventory: .omitted
        )
    )
}

private let laptop = SyncDeviceID(UUID(uuidString: "22222222-0000-4000-8000-000000000002")!)

@Test @MainActor func anAccountThisMacReadsShowsOnceAndOthersStay() {
    var local = localWork()
    local.quota = reading()
    let model = GuardAppModel(profiles: [local], referenceDate: now)
    let other = UUID()
    model.remoteDevices = [device(mini, name: "Mac mini", accounts: [
        sharedAccount(remoteWorkID, email: " WORK@example.com "),
        sharedAccount(other, email: "other@example.com"),
    ])]
    #expect(model.remoteCopies(now: now).map(\.account.profileID) == [other])
}

@Test @MainActor func anotherMacsCopyStaysWhileThisMacHasNoCurrentReading() {
    var local = localWork()
    let model = GuardAppModel(profiles: [local], referenceDate: now)
    model.remoteDevices = [device(mini, name: "Mac mini", accounts: [sharedAccount(remoteWorkID, email: "work@example.com")])]
    #expect(model.remoteCopies(now: now).map(\.account.profileID) == [remoteWorkID])

    local.quota = reading(observedAt: now.addingTimeInterval(-3 * 3_600))
    model.profiles = [local]
    #expect(model.remoteCopies(now: now).count == 1)

    local.quota = reading()
    model.profiles = [local]
    #expect(model.remoteCopies(now: now).isEmpty)
}

@Test @MainActor func accountsWithoutAnEmailNeverMerge() {
    var local = localWork()
    local.email = nil
    local.quota = reading()
    let model = GuardAppModel(profiles: [local], referenceDate: now)
    model.remoteDevices = [
        device(mini, name: "Mac mini", accounts: [sharedAccount(remoteWorkID, email: "")]),
        device(laptop, name: "MacBook", accounts: [sharedAccount(UUID(), email: "")]),
    ]
    #expect(model.remoteCopies(now: now).count == 2)
}

@Test @MainActor func anAccountOnTwoOtherMacsKeepsOneSteadyCard() {
    let model = GuardAppModel(referenceDate: now)
    let miniCopy = sharedAccount(remoteWorkID, email: "work@example.com")
    let laptopCopy = sharedAccount(UUID(), email: "work@example.com")
    model.remoteDevices = [
        device(laptop, name: "MacBook", accounts: [laptopCopy]),
        device(mini, name: "Mac mini", accounts: [miniCopy]),
    ]
    let shown = { model.remoteCopies(now: now).map(\.device.deviceID) }
    #expect(shown() == [mini])

    // Publishing order never moves the card.
    model.remoteDevices[0].publishedAt = now.addingTimeInterval(5)
    #expect(shown() == [mini])
    model.remoteDevices.reverse()
    #expect(shown() == [mini])

    // A Mac that redeems the account wins, and a change in flight wins over that.
    model.remoteDevices[1].accounts[0].autoRedeemEnabled = true
    #expect(shown() == [laptop])
    model.pendingRemoteCommands[GuardAppModel.remoteKey(device: mini, account: miniCopy)] =
        PendingRemoteCommand(commandID: UUID(), enabled: false, issuedAt: now)
    #expect(shown() == [mini])

    // Alerts pick among the Macs read this pass, so a quiet Mac never hides a fresh one.
    #expect(model.remoteCopies(among: [model.remoteDevices[1]], now: now).map(\.device.deviceID) == [laptop])
}

@Test @MainActor func theCardSwitchTurnsOffAutoRedeemWhereverItRuns() {
    let model = GuardAppModel(profiles: [localWork()], referenceDate: now)
    model.remoteDevices = [miniSnapshot(autoRedeem: true)]
    var sent: [Bool] = []
    var toggles: [Bool] = []
    model.onSetRemoteAutoReset = { _, _, enabled in sent.append(enabled) }
    model.onToggleAutoReset = { _, enabled in toggles.append(enabled) }
    let id = workID.uuidString.lowercased()

    #expect(model.remoteRedeemer(of: model.profiles[0], now: now)?.device.deviceID == mini)
    model.setAccountAutoReset(profileID: id, enabled: false)
    #expect(sent == [false])
    #expect(toggles.isEmpty)

    // A Mac that went quiet with Auto-redeem on still shows as the one redeeming.
    model.remoteDevices = [miniSnapshot(autoRedeem: true, publishedAt: now.addingTimeInterval(-3 * 3_600))]
    #expect(model.remoteRedeemer(of: model.profiles[0], now: now)?.device.deviceID == mini)

    // Once no other Mac redeems it, the switch runs Auto-redeem here.
    model.remoteDevices = [miniSnapshot(autoRedeem: false)]
    #expect(model.remoteRedeemer(of: model.profiles[0], now: now) == nil)
    model.setAccountAutoReset(profileID: id, enabled: true)
    #expect(toggles == [true])

    // A leftover change to another Mac never turns an enable into a command to that Mac.
    model.pendingRemoteCommands[GuardAppModel.remoteKey(device: mini, account: model.remoteDevices[0].accounts[0])] =
        PendingRemoteCommand(commandID: UUID(), enabled: false, issuedAt: now)
    model.setAccountAutoReset(profileID: id, enabled: true)
    #expect(toggles == [true, true])
    #expect(sent == [false])
}
