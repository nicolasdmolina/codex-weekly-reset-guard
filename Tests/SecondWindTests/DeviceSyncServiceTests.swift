import Darwin
import Foundation
import Testing
@testable import SecondWindCore

private let start = Date(timeIntervalSince1970: 1_790_000_000)
private let workID = UUID(uuidString: "C0DE0000-0000-4000-8000-000000000002")!
private let personalID = UUID(uuidString: "C0DE0000-0000-4000-8000-000000000001")!

/// A stand-in host: two Codex accounts whose Auto-redeem flag only changes through `apply`.
private actor FakeHost {
    private(set) var autoRedeem: [UUID: Bool] = [workID: false, personalID: false]
    private(set) var applied: [(UUID, Bool)] = []

    func apply(_ id: UUID, _ enabled: Bool) -> Bool {
        applied.append((id, enabled))
        autoRedeem[id] = enabled
        return true
    }

    private(set) var removed: Set<UUID> = []

    func remove(_ id: UUID) -> Bool {
        removed.insert(id)
        return true
    }

    func accounts() -> [SharedAccount] {
        [personalID, workID].map { id in
            SharedAccount(
                profileID: id,
                provider: .codex,
                displayName: id == workID ? "Work" : "Personal",
                email: id == workID ? "work@example.com" : "me@example.com",
                autoRedeemEnabled: autoRedeem[id],
                windows: [SharedWindow(kind: .weekly, remainingPercent: 40, resetsAt: start.addingTimeInterval(86_400), observedAt: start)],
                savedResetCount: 1
            )
        }
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = start
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SecondWindSyncTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct Pair {
    let shared: DeviceSyncFolder
    let host: DeviceSyncService
    let viewer: DeviceSyncService
    let fake: FakeHost
    let clock: Clock
    let viewerApplied: @Sendable () -> Int
}

private func makePair() throws -> Pair {
    let root = try makeDirectory()
    let shared = DeviceSyncFolder(root: root.appendingPathComponent("iCloud/Second Wind", isDirectory: true))
    let clock = Clock()
    let fake = FakeHost()
    let host = DeviceSyncService(
        folder: shared,
        stateURL: root.appendingPathComponent("mini/sync-state.json"),
        deviceName: "Mac mini",
        now: { clock.now },
        localAccounts: { await fake.accounts() },
        applyAutoRedeem: { await fake.apply($0, $1) }
    )
    let viewerCalls = Counter()
    let viewer = DeviceSyncService(
        folder: shared,
        stateURL: root.appendingPathComponent("laptop/sync-state.json"),
        deviceName: "MacBook Pro",
        now: { clock.now },
        localAccounts: { [] },
        applyAutoRedeem: { _, _ in viewerCalls.increment(); return false }
    )
    return Pair(shared: shared, host: host, viewer: viewer, fake: fake, clock: clock, viewerApplied: { viewerCalls.value })
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@Test func hostPublishesViewerSendsAndTheHostAppliesOnceWithAnAcknowledgement() async throws {
    let pair = try makePair()
    let hostID = try await pair.host.deviceID()
    let viewerID = try await pair.viewer.deviceID()
    #expect(hostID != viewerID)
    #expect(try await pair.host.deviceID() == hostID)

    // Host publishes; the viewer reads it and never sees its own file.
    _ = try await pair.host.run()
    pair.clock.advance(5)
    let first = try #require(try await pair.viewer.run())
    #expect(first.devices?.map(\.deviceID) == [hostID])
    #expect(first.devices?[0].deviceName == "Mac mini")
    #expect(first.devices?[0].acceptsCommands == true)
    #expect(first.devices?[0].accounts.first { $0.profileID == workID }?.autoRedeemEnabled == false)
    let hostView = try #require(try await pair.host.run())
    #expect(hostView.devices?.map(\.deviceID) == [viewerID])
    #expect(hostView.devices?[0].accounts.isEmpty == true)

    // Viewer asks for Auto-redeem on Work.
    let sent = try await pair.viewer.send(.setAutoRedeem(profileID: workID, enabled: true), to: hostID)
    let pending = PendingRemoteCommand(commandID: sent.id, enabled: true, issuedAt: sent.issuedAt)
    let waitingPass = try #require(try await pair.viewer.run())
    let waiting = try #require(waitingPass.devices?[0])
    let work = try #require(waiting.accounts.first { $0.profileID == workID })
    #expect(RemoteAccountState.classify(account: work, in: waiting, pending: pending, now: pair.clock.now) == .pending(enabled: true))

    // Host applies it through the injected switch path exactly once and acknowledges it.
    pair.clock.advance(30)
    let handled = try #require(try await pair.host.run())
    #expect(handled.decisions == [.apply(profileID: workID, enabled: true)])
    #expect(await pair.fake.applied.map(\.0) == [workID])
    #expect(try pair.shared.commands(for: hostID).isEmpty)

    pair.clock.advance(5)
    let acknowledgedPass = try #require(try await pair.viewer.run())
    let acknowledged = try #require(acknowledgedPass.devices?[0])
    #expect(acknowledged.appliedCommandIDs.contains(sent.id))
    let updated = try #require(acknowledged.accounts.first { $0.profileID == workID })
    #expect(updated.autoRedeemEnabled == true)
    #expect(RemoteAccountState.classify(account: updated, in: acknowledged, pending: pending, now: pair.clock.now).isSettled)

    // The same command file delivered again (a late iCloud copy) is never applied twice.
    try pair.shared.send(sent, to: hostID)
    let replay = try #require(try await pair.host.run())
    #expect(replay.decisions == [.reject(.alreadyApplied)])
    #expect(await pair.fake.applied.count == 1)
    #expect(try pair.shared.commands(for: hostID).isEmpty)
    #expect(pair.viewerApplied() == 0)
}

@Test func hostRejectsExpiredUnknownAndConflictingCommandsWithoutApplying() async throws {
    let pair = try makePair()
    let hostID = try await pair.host.deviceID()
    let viewerID = try await pair.viewer.deviceID()

    // A third Mac already redeems Work.
    let other = SyncDeviceID()
    try pair.shared.publish(DeviceSnapshot(
        deviceID: other,
        deviceName: "Studio iMac",
        publishedAt: start,
        accounts: [SharedAccount(
            profileID: UUID(), provider: .codex, displayName: "Work", email: "Work@Example.com",
            autoRedeemEnabled: true, windows: []
        )],
        appliedCommandIDs: []
    ))

    let expired = RemoteCommand(issuedBy: viewerID, issuedAt: start.addingTimeInterval(-31 * 60), action: .setAutoRedeem(profileID: workID, enabled: false))
    let unknown = RemoteCommand(issuedBy: viewerID, issuedAt: start, action: .setAutoRedeem(profileID: UUID(), enabled: true))
    let conflict = RemoteCommand(issuedBy: viewerID, issuedAt: start, action: .setAutoRedeem(profileID: workID, enabled: true))
    for command in [expired, unknown, conflict] { try pair.shared.send(command, to: hostID) }
    // A file that is not a command is removed without effect.
    let junk = pair.shared.root.appendingPathComponent("commands/\(hostID)/\(UUID().uuidString.lowercased()).json")
    try Data("{\"nope\":true}".utf8).write(to: junk)

    let pass = try #require(try await pair.host.run())
    #expect(Set(pass.decisions.map { "\($0)" }) == Set([
        CommandDecision.reject(.expired),
        .reject(.unknownProfile),
        .reject(.autoRedeemOnElsewhere(deviceName: "Studio iMac")),
    ].map { "\($0)" }))
    #expect(await pair.fake.applied.isEmpty)
    #expect(try pair.shared.commands(for: hostID).isEmpty)

    // Rejections are acknowledged too, so the sender stops waiting at once.
    let seen = try #require(try await pair.viewer.run()).devices?.first { $0.deviceID == hostID }
    #expect(Set(seen?.appliedCommandIDs ?? []) == Set([expired.id, unknown.id, conflict.id]))
}

@Test func syncFolderSkipsPlaceholdersMislabelledAndOwnSnapshots() async throws {
    let root = try makeDirectory()
    let folder = DeviceSyncFolder(root: root)
    let me = SyncDeviceID()
    let other = SyncDeviceID()
    let snapshot = { (id: SyncDeviceID) in
        DeviceSnapshot(deviceID: id, deviceName: "Mac", publishedAt: start, accounts: [], appliedCommandIDs: [])
    }
    try folder.publish(snapshot(me))
    try folder.publish(snapshot(other))
    let devices = root.appendingPathComponent("devices")
    // A file renamed to claim another device, and a not-yet-downloaded iCloud placeholder.
    try FileManager.default.copyItem(
        at: devices.appendingPathComponent("\(other).json"),
        to: devices.appendingPathComponent("\(SyncDeviceID()).json")
    )
    try Data().write(to: devices.appendingPathComponent(".\(SyncDeviceID()).json.icloud"))
    var newer = snapshot(SyncDeviceID())
    newer.schemaVersion = DeviceSnapshot.currentSchemaVersion + 1
    try folder.publish(newer)

    #expect(try folder.readSnapshots(excluding: me).map(\.deviceID) == [other])
    try folder.removeSnapshot(for: other)
    try folder.removeSnapshot(for: other)
    #expect(try folder.readSnapshots(excluding: me).isEmpty)
}

@Test(arguments: ["devices", "commands"])
func unreadableSyncFolderStillPublishesWithoutAcceptingCommands(_ blocked: String) async throws {
    let pair = try makePair()
    let hostID = try await pair.host.deviceID()
    let viewerID = try await pair.viewer.deviceID()
    let ready = try #require(try await pair.host.run())
    #expect(ready.acceptsCommands && ready.readFailure == nil && ready.publishFailure == nil)

    // A command waits in the inbox; the host must not act on it while it cannot read everything.
    let waiting = RemoteCommand(issuedBy: viewerID, issuedAt: start, action: .setAutoRedeem(profileID: workID, enabled: true))
    try pair.shared.send(waiting, to: hostID)
    let directory = blocked == "devices"
        ? pair.shared.root.appendingPathComponent("devices")
        : pair.shared.root.appendingPathComponent("commands/\(hostID)")
    // Like the Mini: listing fails while writing still works. Write and search, but no read.
    #expect(chmod(directory.path, blocked == "devices" ? 0o300 : 0o000) == 0)
    pair.clock.advance(30)
    let pass = try #require(try await pair.host.run())
    #expect(chmod(directory.path, 0o700) == 0)

    #expect(pass.readFailure?.domain == NSCocoaErrorDomain)
    #expect(pass.publishFailure == nil)
    #expect(!pass.acceptsCommands)
    #expect(pass.devices == nil)
    #expect(pass.decisions.isEmpty)
    #expect(await pair.fake.applied.isEmpty)

    // The snapshot was still published, newer, and says it does not accept commands.
    let published = try #require(try pair.shared.readSnapshots(excluding: viewerID).first { $0.deviceID == hostID })
    #expect(published.publishedAt == start.addingTimeInterval(30))
    #expect(!published.acceptsCommands)

    // Once readable again the command is handled and the flag comes back.
    let recovered = try #require(try await pair.host.run())
    #expect(recovered.acceptsCommands)
    #expect(recovered.decisions == [.apply(profileID: workID, enabled: true)])
}

@Test func hostCreatesItsCommandFolderBeforeAnyoneSends() async throws {
    let pair = try makePair()
    let hostID = try await pair.host.deviceID()
    let inbox = pair.shared.root.appendingPathComponent("commands/\(hostID)")
    #expect(!FileManager.default.fileExists(atPath: inbox.path))
    let pass = try #require(try await pair.host.run())
    #expect(FileManager.default.fileExists(atPath: inbox.path))
    #expect(pass.commandsListed == 0 && pass.commandsDecoded == 0)
}

@Test func hostRemovesAnAccountOnRequestAndPublishesWithoutIt() async throws {
    let root = try makeDirectory()
    let shared = DeviceSyncFolder(root: root.appendingPathComponent("iCloud/Second Wind", isDirectory: true))
    let clock = Clock()
    let fake = FakeHost()
    // The roster still lists the account for a moment after removal, as the app's may.
    let host = DeviceSyncService(
        folder: shared,
        stateURL: root.appendingPathComponent("mini/sync-state.json"),
        deviceName: "Mac mini",
        now: { clock.now },
        localAccounts: { await fake.accounts() },
        applyAutoRedeem: { await fake.apply($0, $1) },
        applyRemoval: { await fake.remove($0) }
    )
    let viewer = DeviceSyncService(
        folder: shared,
        stateURL: root.appendingPathComponent("laptop/sync-state.json"),
        deviceName: "MacBook Pro",
        now: { clock.now },
        localAccounts: { [] },
        applyAutoRedeem: { _, _ in false }
    )
    let hostID = try await host.deviceID()
    _ = try await viewer.run()
    _ = try await host.run()
    let seen = try #require(try await viewer.run()?.devices?.first)
    #expect(seen.acceptsRemoval)

    let sent = try await viewer.send(.removeAccount(profileID: workID), to: hostID)
    clock.advance(10)
    let handled = try #require(try await host.run())
    #expect(handled.decisions == [.remove(profileID: workID)])
    #expect(await fake.removed == [workID])

    let after = try #require(try await viewer.run()?.devices?.first)
    #expect(after.appliedCommandIDs.contains(sent.id))
    #expect(!after.accounts.contains { $0.profileID == workID })
    #expect(after.accounts.contains { $0.profileID == personalID })

    // Delivered twice, it is not removed twice.
    try shared.send(sent, to: hostID)
    let again = try #require(try await host.run())
    #expect(again.decisions == [.reject(.alreadyApplied)])
    #expect(await fake.removed == [workID])
}

@Test func aHostThatCannotRemoveSaysSoAndRefusesTheRequest() async throws {
    let pair = try makePair()
    let hostID = try await pair.host.deviceID()
    _ = try await pair.viewer.run()
    _ = try await pair.host.run()
    let seen = try #require(try await pair.viewer.run()?.devices?.first)
    #expect(!seen.acceptsRemoval)

    _ = try await pair.viewer.send(.removeAccount(profileID: workID), to: hostID)
    let handled = try #require(try await pair.host.run())
    #expect(handled.decisions == [.reject(.removalUnsupported)])
    let after = try #require(try await pair.viewer.run()?.devices?.first)
    #expect(after.accounts.contains { $0.profileID == workID })
}
