import Foundation
import Testing
@testable import SecondWindCore

private let now = Date(timeIntervalSince1970: 1_790_000_000)
private let mini = SyncDeviceID(UUID(uuidString: "11111111-0000-4000-8000-000000000001")!)
private let laptop = SyncDeviceID(UUID(uuidString: "22222222-0000-4000-8000-000000000002")!)
private let studio = SyncDeviceID(UUID(uuidString: "33333333-0000-4000-8000-000000000003")!)
private let workID = UUID(uuidString: "C0DE0000-0000-4000-8000-000000000002")!
private let claudeID = UUID(uuidString: "C1A0DE00-0000-4000-8000-000000000001")!

private func codexAccount(
    _ id: UUID = workID,
    email: String = "work@example.com",
    autoRedeem: Bool = false,
    weekly: Double = 58,
    observedAt: Date = now
) -> SharedAccount {
    SharedAccount(
        profileID: id,
        provider: .codex,
        displayName: "Work",
        email: email,
        autoRedeemEnabled: autoRedeem,
        windows: [
            SharedWindow(kind: .session, remainingPercent: 90, resetsAt: now.addingTimeInterval(3_600), observedAt: observedAt),
            SharedWindow(kind: .weekly, remainingPercent: weekly, resetsAt: now.addingTimeInterval(4 * 86_400), observedAt: observedAt),
        ],
        savedResetCount: 2
    )
}

private func snapshot(
    _ device: SyncDeviceID,
    name: String = "Mac mini",
    publishedAt: Date = now,
    accounts: [SharedAccount],
    applied: [UUID] = []
) -> DeviceSnapshot {
    DeviceSnapshot(deviceID: device, deviceName: name, publishedAt: publishedAt, accounts: accounts, appliedCommandIDs: applied)
}

private func command(_ enabled: Bool, profile: UUID = workID, issuedAt: Date = now, from: SyncDeviceID = laptop) -> RemoteCommand {
    RemoteCommand(issuedBy: from, issuedAt: issuedAt, action: .setAutoRedeem(profileID: profile, enabled: enabled))
}

// MARK: Encoding

@Test func deviceSnapshotRoundTripsWithoutSecrets() throws {
    let claude = SharedAccount(
        profileID: claudeID,
        provider: .claude,
        displayName: "Studio",
        email: " Studio@Example.com ",
        autoRedeemEnabled: true,
        windows: [SharedWindow(kind: .modelWeekly("Sonnet only"), remainingPercent: 31, resetsAt: nil, observedAt: now)],
        attentionMessage: "Sign in to start monitoring."
    )
    let original = snapshot(mini, accounts: [codexAccount(autoRedeem: true), claude], applied: [UUID()])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(original)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(DeviceSnapshot.self, from: data)

    #expect(decoded == original)
    #expect(decoded.schemaVersion == DeviceSnapshot.currentSchemaVersion)
    // Claude never carries an Auto-redeem flag, and emails are normalized for comparison.
    #expect(decoded.accounts[1].autoRedeemEnabled == nil)
    #expect(decoded.accounts[1].email == "studio@example.com")
    #expect(decoded.accounts[1].windows[0].windowKind == .modelWeekly("Sonnet only"))
    let text = String(decoding: data, as: UTF8.self).lowercased()
    for forbidden in ["token", "idempotency", "codex_home", "path", "credit"] {
        #expect(!text.contains(forbidden), "snapshot JSON mentions \(forbidden)")
    }
}

@Test func olderSnapshotsWithoutTheCommandFlagDoNotAcceptCommands() throws {
    let json = """
    {"schemaVersion":1,"deviceID":"11111111-0000-4000-8000-000000000001","deviceName":"Mac mini",
     "publishedAt":"2026-09-21T12:00:00Z","accounts":[],"appliedCommandIDs":[]}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(DeviceSnapshot.self, from: Data(json.utf8))
    #expect(!decoded.acceptsCommands)

    var accepting = decoded
    accepting.acceptsCommands = true
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    #expect(try decoder.decode(DeviceSnapshot.self, from: encoder.encode(accepting)).acceptsCommands)
}

@Test func remoteCommandRoundTripsAsAbsoluteState() throws {
    let original = command(true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(RemoteCommand.self, from: encoder.encode(original))
    #expect(decoded == original)
    #expect(decoded.action == .setAutoRedeem(profileID: workID, enabled: true))
}

@Test func windowKindKeysRoundTrip() {
    for kind in [QuotaWindowKind.session, .weekly, .monthly, .modelWeekly("Sonnet only")] {
        #expect(QuotaWindowKind(key: kind.key) == kind)
    }
    #expect(QuotaWindowKind(key: "yearly") == nil)
    #expect(QuotaWindowKind(key: "weekly:") == nil)
}

@Test func sharedAccountReadsThroughTheQuotaModel() {
    let record = codexAccount(weekly: 7, observedAt: now.addingTimeInterval(-60)).quotaRecord()
    let reading = record.reading(at: now, policy: .remote)
    #expect(reading.freshness == .fresh(lastSuccessAt: now.addingTimeInterval(-60)))
    #expect(reading.currentLowWindows.map(\.window.kind) == [.weekly])
    if case let .known(saved, isCurrent) = reading.inventory {
        #expect(saved.availableCount == 2)
        #expect(isCurrent)
    } else {
        Issue.record("Expected a known saved-reset count")
    }

    // A reading older than the remote stale line, or a window past its reset, never alerts.
    let old = codexAccount(weekly: 7, observedAt: now.addingTimeInterval(-11 * 60)).quotaRecord()
    #expect(old.reading(at: now, policy: .remote).currentLowWindows.isEmpty)
    let passed = codexAccount(weekly: 7).quotaRecord().reading(at: now.addingTimeInterval(5 * 86_400), policy: .remote)
    #expect(passed.currentLowWindows.isEmpty)

    let empty = SharedAccount(profileID: claudeID, provider: .claude, displayName: "Studio", email: "s@example.com", autoRedeemEnabled: nil, windows: [])
    #expect(empty.quotaRecord().lastSuccess == nil)
}

// MARK: Staleness

@Test func snapshotFreshnessMarksStaleAfterTenMinutes() {
    #expect(SnapshotFreshness(publishedAt: now.addingTimeInterval(-30), now: now) == .live(age: 30))
    #expect(SnapshotFreshness(publishedAt: now.addingTimeInterval(-599), now: now).isLive)
    #expect(SnapshotFreshness(publishedAt: now.addingTimeInterval(-600), now: now) == .stale(age: 600))
    // A clock slightly ahead on the other Mac reads as just now.
    #expect(SnapshotFreshness(publishedAt: now.addingTimeInterval(20), now: now) == .live(age: 0))
}

@Test func remoteAccountStateFollowsPendingCommandToAcknowledgement() {
    let pending = PendingRemoteCommand(commandID: UUID(), enabled: true, issuedAt: now)
    let before = snapshot(mini, publishedAt: now.addingTimeInterval(-20), accounts: [codexAccount()])
    #expect(RemoteAccountState.classify(account: before.accounts[0], in: before, pending: pending, now: now) == .pending(enabled: true))

    let applied = snapshot(mini, publishedAt: now.addingTimeInterval(30), accounts: [codexAccount(autoRedeem: true)], applied: [pending.commandID])
    #expect(RemoteAccountState.classify(account: applied.accounts[0], in: applied, pending: pending, now: now.addingTimeInterval(40)) == .live(age: 10))

    let refused = snapshot(mini, publishedAt: now.addingTimeInterval(30), accounts: [codexAccount()], applied: [pending.commandID])
    #expect(RemoteAccountState.classify(account: refused.accounts[0], in: refused, pending: pending, now: now.addingTimeInterval(40)) == .notApplied(enabled: true))

    // A host that never answers stops the wait once the command could no longer be applied.
    let silent = snapshot(mini, publishedAt: now.addingTimeInterval(-20), accounts: [codexAccount()])
    #expect(RemoteAccountState.classify(account: silent.accounts[0], in: silent, pending: pending, now: now.addingTimeInterval(31 * 60)) == .pending(enabled: true))
    #expect(RemoteAccountState.classify(account: silent.accounts[0], in: silent, pending: pending, now: now.addingTimeInterval(33 * 60)) == .notApplied(enabled: true))

    #expect(RemoteAccountState.classify(account: silent.accounts[0], in: silent, pending: nil, now: now.addingTimeInterval(20 * 60)) == .stale(age: 1_220))
}

// MARK: Double auto-redeem guard

@Test func autoRedeemGuardFindsOnlyLiveSnapshotsWithTheSameEmailOn() {
    let on = snapshot(mini, accounts: [codexAccount(email: "WORK@example.com", autoRedeem: true)])
    #expect(AutoRedeemGuard.conflictingDevice(email: "work@example.com ", among: [on], now: now)?.deviceID == mini)
    #expect(AutoRedeemGuard.conflictingDevice(email: "other@example.com", among: [on], now: now) == nil)
    #expect(AutoRedeemGuard.conflictingDevice(email: "work@example.com", among: [on], excluding: [mini], now: now) == nil)
    #expect(AutoRedeemGuard.conflictingDevice(email: "", among: [on], now: now) == nil)

    let off = snapshot(mini, accounts: [codexAccount(autoRedeem: false)])
    #expect(AutoRedeemGuard.conflictingDevice(email: "work@example.com", among: [off], now: now) == nil)
    let stale = snapshot(mini, publishedAt: now.addingTimeInterval(-11 * 60), accounts: [codexAccount(autoRedeem: true)])
    #expect(AutoRedeemGuard.conflictingDevice(email: "work@example.com", among: [stale], now: now) == nil)
}

// MARK: Command decisions

@Test func hostAppliesAFreshCommandForAKnownCodexProfile() {
    let decision = RemoteCommandPolicy.decide(
        command(true), host: mini, hostAccounts: [codexAccount()], handledCommandIDs: [], otherDevices: [], now: now.addingTimeInterval(30)
    )
    #expect(decision == .apply(profileID: workID, enabled: true))
}

@Test func hostAppliesACommandAtMostOnce() {
    let once = command(false)
    let decision = RemoteCommandPolicy.decide(
        once, host: mini, hostAccounts: [codexAccount(autoRedeem: true)], handledCommandIDs: [once.id], otherDevices: [], now: now
    )
    #expect(decision == .reject(.alreadyApplied))
}

@Test func hostRejectsStaleAndFutureCommands() {
    let accounts = [codexAccount()]
    #expect(RemoteCommandPolicy.decide(
        command(true, issuedAt: now.addingTimeInterval(-31 * 60)), host: mini, hostAccounts: accounts, handledCommandIDs: [], otherDevices: [], now: now
    ) == .reject(.expired))
    #expect(RemoteCommandPolicy.decide(
        command(true, issuedAt: now.addingTimeInterval(-29 * 60)), host: mini, hostAccounts: accounts, handledCommandIDs: [], otherDevices: [], now: now
    ) == .apply(profileID: workID, enabled: true))
    #expect(RemoteCommandPolicy.decide(
        command(true, issuedAt: now.addingTimeInterval(5 * 60)), host: mini, hostAccounts: accounts, handledCommandIDs: [], otherDevices: [], now: now
    ) == .reject(.issuedInFuture))
    #expect(RemoteCommandPolicy.decide(
        command(true, from: mini), host: mini, hostAccounts: accounts, handledCommandIDs: [], otherDevices: [], now: now
    ) == .reject(.issuedBySelf))
}

@Test func hostRejectsUnknownAndClaudeProfiles() {
    let claude = SharedAccount(profileID: claudeID, provider: .claude, displayName: "Studio", email: "s@example.com", autoRedeemEnabled: nil, windows: [])
    #expect(RemoteCommandPolicy.decide(
        command(true, profile: UUID()), host: mini, hostAccounts: [codexAccount(), claude], handledCommandIDs: [], otherDevices: [], now: now
    ) == .reject(.unknownProfile))
    #expect(RemoteCommandPolicy.decide(
        command(true, profile: claudeID), host: mini, hostAccounts: [codexAccount(), claude], handledCommandIDs: [], otherDevices: [], now: now
    ) == .reject(.unsupportedProfile))
}

@Test func hostRefusesARemoteEnableWhenAnotherMacAlreadyRedeemsThatAccount() {
    let elsewhere = snapshot(studio, name: "Studio iMac", accounts: [codexAccount(UUID(), autoRedeem: true)])
    #expect(RemoteCommandPolicy.decide(
        command(true), host: mini, hostAccounts: [codexAccount()], handledCommandIDs: [], otherDevices: [elsewhere], now: now
    ) == .reject(.autoRedeemOnElsewhere(deviceName: "Studio iMac")))
    // Turning off is never refused.
    #expect(RemoteCommandPolicy.decide(
        command(false), host: mini, hostAccounts: [codexAccount(autoRedeem: true)], handledCommandIDs: [], otherDevices: [elsewhere], now: now
    ) == .apply(profileID: workID, enabled: false))
}

// MARK: Remote removal

@Test func olderSnapshotsDoNotAcceptRemoval() throws {
    let json = """
    {"schemaVersion":1,"deviceID":"11111111-0000-4000-8000-000000000001","deviceName":"Mac mini",
     "publishedAt":"2026-09-21T12:00:00Z","accounts":[],"appliedCommandIDs":[],"acceptsCommands":true}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(DeviceSnapshot.self, from: Data(json.utf8))
    #expect(decoded.acceptsCommands)
    #expect(!decoded.acceptsRemoval)
    #expect(!decoded.canRemove(at: decoded.publishedAt))

    var accepting = decoded
    accepting.acceptsRemoval = true
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let roundTripped = try decoder.decode(DeviceSnapshot.self, from: encoder.encode(accepting))
    #expect(roundTripped.canRemove(at: decoded.publishedAt))
    // A quiet Mac would not read the request in time.
    #expect(!roundTripped.canRemove(at: decoded.publishedAt.addingTimeInterval(DeviceSyncPolicy.staleAfter + 1)))
}

@Test func hostRemovesOnlyAKnownAccountForAMacItSees() {
    let removal = RemoteCommand(issuedBy: laptop, issuedAt: now, action: .removeAccount(profileID: workID))
    let sender = snapshot(laptop, name: "MacBook", accounts: [])
    let claude = SharedAccount(profileID: claudeID, provider: .claude, displayName: "Studio", email: "s@example.com", autoRedeemEnabled: nil, windows: [])
    #expect(RemoteCommandPolicy.decide(
        removal, host: mini, hostAccounts: [codexAccount()], handledCommandIDs: [], otherDevices: [sender], now: now
    ) == .remove(profileID: workID))
    // Claude accounts can be removed too.
    let claudeRemoval = RemoteCommand(issuedBy: laptop, issuedAt: now, action: .removeAccount(profileID: claudeID))
    #expect(RemoteCommandPolicy.decide(
        claudeRemoval, host: mini, hostAccounts: [claude], handledCommandIDs: [], otherDevices: [sender], now: now
    ) == .remove(profileID: claudeID))
    #expect(RemoteCommandPolicy.decide(
        removal, host: mini, hostAccounts: [claude], handledCommandIDs: [], otherDevices: [sender], now: now
    ) == .reject(.unknownProfile))
    #expect(RemoteCommandPolicy.decide(
        removal, host: mini, hostAccounts: [codexAccount()], handledCommandIDs: [], otherDevices: [], now: now
    ) == .reject(.unknownSender))
    #expect(RemoteCommandPolicy.decide(
        removal, host: mini, hostAccounts: [codexAccount()], handledCommandIDs: [removal.id], otherDevices: [sender], now: now
    ) == .reject(.alreadyApplied))
    #expect(RemoteCommandPolicy.decide(
        RemoteCommand(issuedBy: laptop, issuedAt: now.addingTimeInterval(-31 * 60), action: .removeAccount(profileID: workID)),
        host: mini, hostAccounts: [codexAccount()], handledCommandIDs: [], otherDevices: [sender], now: now
    ) == .reject(.expired))
}
