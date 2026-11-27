import Foundation

/// This Mac's sync identity and the commands it has handled. Kept in local app state, never in
/// the shared folder.
public struct DeviceSyncState: Codable, Equatable, Sendable {
    public var deviceID: SyncDeviceID
    /// Handled command IDs, newest last, bounded to `DeviceSyncPolicy.rememberedCommands`.
    public var handledCommandIDs: [UUID]

    public init(deviceID: SyncDeviceID = SyncDeviceID(), handledCommandIDs: [UUID] = []) {
        self.deviceID = deviceID
        self.handledCommandIDs = handledCommandIDs
    }

    mutating func remember(_ id: UUID) {
        handledCommandIDs.removeAll { $0 == id }
        handledCommandIDs.append(id)
        if handledCommandIDs.count > DeviceSyncPolicy.rememberedCommands {
            handledCommandIDs.removeFirst(handledCommandIDs.count - DeviceSyncPolicy.rememberedCommands)
        }
    }
}

/// A failed file operation, kept as codes only so it can be logged without paths or names.
public struct SyncFailure: Equatable, Sendable {
    public var domain: String
    public var code: Int
    public var underlyingDomain: String?
    public var underlyingCode: Int?

    public init(_ error: Error) {
        let error = error as NSError
        domain = error.domain
        code = error.code
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        underlyingDomain = underlying?.domain
        underlyingCode = underlying?.code
    }
}

public struct DeviceSyncPass: Equatable, Sendable {
    public var deviceID: SyncDeviceID
    /// Other Macs' snapshots, newest-forgotten ones left out. Nil when reading failed.
    public var devices: [DeviceSnapshot]?
    /// Files found in this Mac's command folder, and how many of them were valid commands.
    public var commandsListed: Int
    public var commandsDecoded: Int
    public var decisions: [CommandDecision]
    public var readFailure: SyncFailure?
    public var publishFailure: SyncFailure?
    /// What this pass published: true only when it listed its own command folder.
    public var acceptsCommands: Bool
}

/// One sync pass: read the other Macs, handle commands addressed to this one, then publish this
/// Mac's snapshot. Reading and publishing fail separately: a Mac that cannot read the folder
/// still publishes, saying it does not accept commands. The only side effect a command can have
/// is `applyAutoRedeem`, which the app wires to the same function its own Auto-redeem switch uses.
public actor DeviceSyncService {
    public typealias AccountsProvider = @Sendable () async -> [SharedAccount]
    public typealias AutoRedeemApplier = @Sendable (_ profileID: UUID, _ enabled: Bool) async -> Bool

    private let folder: DeviceSyncFolder
    private let store: SecureStateStore<DeviceSyncState>
    private let deviceName: String
    private let now: @Sendable () -> Date
    private let localAccounts: AccountsProvider
    private let applyAutoRedeem: AutoRedeemApplier
    private var isRunning = false
    private var isWithdrawn = false

    public init(
        folder: DeviceSyncFolder,
        stateURL: URL,
        deviceName: String,
        now: @escaping @Sendable () -> Date = Date.init,
        localAccounts: @escaping AccountsProvider,
        applyAutoRedeem: @escaping AutoRedeemApplier
    ) {
        self.folder = folder
        self.store = SecureStateStore(fileURL: stateURL, maximumBytes: 64 * 1_024)
        self.deviceName = deviceName
        self.now = now
        self.localAccounts = localAccounts
        self.applyAutoRedeem = applyAutoRedeem
    }

    /// The device ID, created and saved on first use.
    public func deviceID() async throws -> SyncDeviceID {
        try await loadState().deviceID
    }

    /// Returns nil when a pass is already running; that pass will publish. Throws only when this
    /// Mac's own local sync state cannot be read or saved.
    public func run() async throws -> DeviceSyncPass? {
        guard !isRunning, !isWithdrawn else { return nil }
        isRunning = true
        defer { isRunning = false }

        var state = try await loadState()
        let device = state.deviceID
        try? folder.prepareInbox(for: device)

        // Commands are handled only when everything they depend on was read: the inbox, and the
        // other Macs' snapshots that the double Auto-redeem guard checks.
        var devices: [DeviceSnapshot]?
        var pending: [(url: URL, command: RemoteCommand?)] = []
        var readFailure: SyncFailure?
        do {
            devices = try folder.readSnapshots(excluding: device).filter {
                now().timeIntervalSince($0.publishedAt) < DeviceSyncPolicy.forgetDeviceAfter
            }
            pending = try folder.commands(for: device)
        } catch {
            devices = nil
            pending = []
            readFailure = SyncFailure(error)
        }

        var decisions: [CommandDecision] = []
        if let devices, !pending.isEmpty {
            let accounts = await localAccounts()
            for (url, command) in pending {
                guard let command else {
                    try? folder.delete(url)
                    continue
                }
                let decision = RemoteCommandPolicy.decide(
                    command,
                    host: device,
                    hostAccounts: accounts,
                    handledCommandIDs: state.handledCommandIDs,
                    otherDevices: devices,
                    now: now()
                )
                decisions.append(decision)
                if decision != .reject(.alreadyApplied) {
                    // Saved before acting, so a crash mid-apply can never apply it twice.
                    state.remember(command.id)
                    try await store.save(state)
                }
                if case let .apply(profileID, enabled) = decision {
                    _ = await applyAutoRedeem(profileID, enabled)
                }
                try? folder.delete(url)
            }
        }

        // Read after commands, so the acknowledgement carries the setting the host really has.
        let acceptsCommands = readFailure == nil
        let snapshot = DeviceSnapshot(
            deviceID: device,
            deviceName: deviceName,
            publishedAt: now(),
            accounts: await localAccounts(),
            appliedCommandIDs: state.handledCommandIDs,
            acceptsCommands: acceptsCommands
        )
        guard !isWithdrawn else { return nil }
        var publishFailure: SyncFailure?
        do {
            try folder.publish(snapshot)
        } catch {
            publishFailure = SyncFailure(error)
        }
        return DeviceSyncPass(
            deviceID: device,
            devices: devices,
            commandsListed: pending.count,
            commandsDecoded: pending.filter { $0.command != nil }.count,
            decisions: decisions,
            readFailure: readFailure,
            publishFailure: publishFailure,
            acceptsCommands: acceptsCommands
        )
    }

    /// Writes a command for `target` and returns what the sender should wait for.
    public func send(_ action: RemoteAction, to target: SyncDeviceID) async throws -> RemoteCommand {
        let command = RemoteCommand(issuedBy: try await deviceID(), issuedAt: now(), action: action)
        try folder.send(command, to: target)
        return command
    }

    /// Removes this Mac's snapshot when the user turns sync off. The service publishes nothing after.
    public func withdraw() async throws {
        isWithdrawn = true
        guard let state = try await store.load() else { return }
        try folder.removeSnapshot(for: state.deviceID)
    }

    private func loadState() async throws -> DeviceSyncState {
        if let state = try await store.load() { return state }
        return try await store.update(defaultValue: DeviceSyncState()) { $0 }
    }
}
