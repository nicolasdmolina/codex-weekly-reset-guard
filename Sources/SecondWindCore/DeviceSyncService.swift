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

public struct DeviceSyncPass: Equatable, Sendable {
    public var deviceID: SyncDeviceID
    /// Other Macs' snapshots, newest-forgotten ones left out.
    public var devices: [DeviceSnapshot]
    public var decisions: [CommandDecision]
}

/// One sync pass: read the other Macs, handle commands addressed to this one, then publish this
/// Mac's snapshot. The only side effect a command can have is `applyAutoRedeem`, which the app
/// wires to the same function its own Auto-redeem switch uses.
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

    /// Returns nil when a pass is already running; that pass will publish.
    public func run() async throws -> DeviceSyncPass? {
        guard !isRunning, !isWithdrawn else { return nil }
        isRunning = true
        defer { isRunning = false }

        var state = try await loadState()
        let device = state.deviceID
        let devices = folder.readSnapshots(excluding: device).filter {
            now().timeIntervalSince($0.publishedAt) < DeviceSyncPolicy.forgetDeviceAfter
        }

        var decisions: [CommandDecision] = []
        let pending = folder.commands(for: device)
        if !pending.isEmpty {
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
        let snapshot = DeviceSnapshot(
            deviceID: device,
            deviceName: deviceName,
            publishedAt: now(),
            accounts: await localAccounts(),
            appliedCommandIDs: state.handledCommandIDs
        )
        guard !isWithdrawn else { return nil }
        try folder.publish(snapshot)
        return DeviceSyncPass(deviceID: device, devices: devices, decisions: decisions)
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
