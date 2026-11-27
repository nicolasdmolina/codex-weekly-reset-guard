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

private func miniSnapshot(autoRedeem: Bool, publishedAt: Date = now) -> DeviceSnapshot {
    DeviceSnapshot(
        deviceID: mini,
        deviceName: "Mac mini",
        publishedAt: publishedAt,
        accounts: [SharedAccount(
            profileID: remoteWorkID, provider: .codex, displayName: "Work", email: "Work@example.com",
            autoRedeemEnabled: autoRedeem, windows: []
        )],
        appliedCommandIDs: []
    )
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
    model.onAddProfile = { _, _ in otherCalls += 1 }

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
