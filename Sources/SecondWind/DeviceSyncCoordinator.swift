import Foundation
import SecondWindCore

/// Runs sync while the user has it on: a pass every 30 seconds and whenever the popover opens.
/// Off means nothing is read from or written to iCloud Drive. Installed app only.
@MainActor
final class DeviceSyncCoordinator {
    static let interval: Duration = .seconds(30)

    private weak var model: GuardAppModel?
    private weak var interface: GuardInterfaceModel?
    private let alerts: AlertRouter
    private let stateURL: URL
    private let locateFolder: @Sendable () -> DeviceSyncFolder?
    private let log: RedactedEventLog?
    private var service: DeviceSyncService?
    private var loop: Task<Void, Never>?
    /// Devices missing from the latest pass. One missed read (a placeholder, a busy file) keeps
    /// the last snapshot on screen; a second drops it.
    private var missedPasses: [SyncDeviceID: Int] = [:]

    init(
        model: GuardAppModel,
        interface: GuardInterfaceModel,
        alerts: AlertRouter,
        stateURL: URL,
        log: RedactedEventLog? = nil,
        locateFolder: @escaping @Sendable () -> DeviceSyncFolder? = { DeviceSyncFolder.iCloud() }
    ) {
        self.log = log
        self.model = model
        self.interface = interface
        self.alerts = alerts
        self.stateURL = stateURL
        self.locateFolder = locateFolder
    }

    func start() {
        if interface?.syncEnabled == true { setEnabled(true) }
    }

    func setEnabled(_ enabled: Bool) {
        loop?.cancel()
        loop = nil
        guard enabled else {
            let service = self.service
            self.service = nil
            missedPasses = [:]
            model?.remoteDevices = []
            model?.pendingRemoteCommands = [:]
            interface?.updateSyncStatus(.off)
            // Withdraw this Mac's snapshot so the others stop listing a Mac that left, even when
            // no pass has run yet this session.
            let locate = locateFolder
            let stateURL = stateURL
            Task.detached {
                if let service {
                    try? await service.withdraw()
                } else if let folder = locate(),
                          let state = try? await SecureStateStore<DeviceSyncState>(fileURL: stateURL).load() {
                    try? folder.removeSnapshot(for: state.deviceID)
                }
            }
            return
        }
        // Remote low-quota notices need permission even on a Mac with no accounts of its own.
        let alerts = alerts
        Task { _ = await alerts.requestPermission() }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pass()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func syncNow() {
        guard interface?.syncEnabled == true else { return }
        Task { await pass() }
    }

    func send(to device: SyncDeviceID, account: SharedAccount, enabled: Bool, reportingTo ref: AccountRef) {
        let deviceName = model?.remoteDevices.first { $0.deviceID == device }?.deviceName ?? "the other Mac"
        guard let service else {
            model?.reportActionFailure("Sync is not connected. Try again in a moment.", for: ref)
            return
        }
        interface?.dismissFeedback(for: ref)
        Task { @MainActor [weak self] in
            do {
                let command = try await service.send(.setAutoRedeem(profileID: account.profileID, enabled: enabled), to: device)
                self?.model?.pendingRemoteCommands[GuardAppModel.remoteKey(device: device, account: account)] =
                    PendingRemoteCommand(commandID: command.id, enabled: enabled, issuedAt: command.issuedAt)
            } catch {
                self?.model?.reportActionFailure("Could not send the change to \(deviceName). Try again.", for: ref)
            }
        }
    }

    static let unwritableMessage = "Second Wind can't write to iCloud Drive on this Mac. It keeps trying."

    func pass() async {
        guard let interface, interface.syncEnabled else { return }
        // Until both providers have answered, an empty roster would reject commands for real accounts.
        guard interface.providerStates[.codex] != .loading, interface.providerStates[.claude] != .loading else { return }
        guard let service = await makeService() else {
            interface.updateSyncStatus(.unavailable)
            await record(["publish": "skipped", "read": "skipped", "icloudDrive": "missing"])
            return
        }
        let result: DeviceSyncPass
        do {
            guard let pass = try await service.run() else { return }
            result = pass
        } catch {
            interface.updateSyncStatus(.failed(Self.unwritableMessage))
            var fields = ["publish": "failed", "read": "skipped"]
            Self.add(SyncFailure(error), prefix: "state", to: &fields)
            await record(fields)
            return
        }
        guard interface.syncEnabled, self.service === service else { return }
        apply(result)
        if result.publishFailure != nil {
            interface.updateSyncStatus(.failed(Self.unwritableMessage))
        } else if result.readFailure != nil {
            interface.updateSyncStatus(.readFailed)
        } else {
            interface.updateSyncStatus(.on)
        }
        var fields = [
            "publish": result.publishFailure == nil ? "ok" : "failed",
            "read": result.readFailure == nil ? "ok" : "failed",
            "acceptsCommands": String(result.acceptsCommands),
            "devices": result.devices.map { String($0.count) } ?? "-",
            "commandsListed": String(result.commandsListed),
            "commandsDecoded": String(result.commandsDecoded),
            "decisions": result.decisions.map(Self.describe).joined(separator: ","),
        ]
        if let failure = result.readFailure { Self.add(failure, prefix: "read", to: &fields) }
        if let failure = result.publishFailure { Self.add(failure, prefix: "publish", to: &fields) }
        await record(fields)
    }

    private static func add(_ failure: SyncFailure, prefix: String, to fields: inout [String: String]) {
        fields["\(prefix)ErrorDomain"] = failure.domain
        fields["\(prefix)ErrorCode"] = String(failure.code)
        if let domain = failure.underlyingDomain, let code = failure.underlyingCode {
            fields["\(prefix)UnderlyingDomain"] = domain
            fields["\(prefix)UnderlyingCode"] = String(code)
        }
    }

    /// One redacted line per pass for diagnosing sync on a Mac without its screen: counts,
    /// decision kinds and error codes only, never names, emails or identifiers.
    private func record(_ fields: [String: String]) async {
        _ = try? await log?.append(profileID: nil, kind: .syncPass, fields: fields)
    }

    static func describe(_ decision: CommandDecision) -> String {
        switch decision {
        case let .apply(_, enabled): enabled ? "apply:on" : "apply:off"
        case let .reject(reason):
            switch reason {
            case .alreadyApplied: "reject:alreadyApplied"
            case .issuedBySelf: "reject:issuedBySelf"
            case .expired: "reject:expired"
            case .issuedInFuture: "reject:issuedInFuture"
            case .unknownProfile: "reject:unknownProfile"
            case .unsupportedProfile: "reject:unsupportedProfile"
            case .autoRedeemOnElsewhere: "reject:autoRedeemOnElsewhere"
            }
        }
    }

    private func makeService() async -> DeviceSyncService? {
        if let service { return service }
        let locate = locateFolder
        guard let folder = await Task.detached(operation: { locate() }).value else { return nil }
        let name = await Task.detached(operation: { Host.current().localizedName ?? "Mac" }).value
        if let service { return service }
        let service = DeviceSyncService(
            folder: folder,
            stateURL: stateURL,
            deviceName: name,
            localAccounts: { [weak model] in
                await MainActor.run { model?.sharedAccounts() ?? [] }
            },
            applyAutoRedeem: { [weak model] profileID, enabled in
                await model?.applyRemoteAutoReset(profileID: profileID, enabled: enabled) ?? false
            }
        )
        self.service = service
        return service
    }

    private func apply(_ pass: DeviceSyncPass) {
        guard let model else { return }
        let now = Date()
        // A failed read leaves what is on screen; snapshots age into stale on their own.
        guard let read = pass.devices else { return }
        let seen = Set(read.map(\.deviceID))
        var devices = read
        for previous in model.remoteDevices where !seen.contains(previous.deviceID) {
            let missed = missedPasses[previous.deviceID, default: 0] + 1
            missedPasses[previous.deviceID] = missed
            if missed < 2 { devices.append(previous) }
        }
        for id in seen { missedPasses[id] = nil }
        model.remoteDevices = devices
        model.pendingRemoteCommands = model.pendingRemoteCommands.filter { key, _ in
            for device in devices {
                for account in device.accounts where GuardAppModel.remoteKey(device: device.deviceID, account: account) == key {
                    return !model.remoteState(of: account, in: device, now: now).isSettled
                }
            }
            return false
        }
        // Alerts come only from what this pass actually read, never for a window this Mac alerts
        // for itself. The alert key collapses the same window from several Macs into one notice.
        let fresh = read.filter { $0.freshness(at: now).isLive }
        for copy in model.remoteAlertSources(among: fresh, now: now) {
            let reading = copy.account.quotaRecord().reading(at: now, policy: .remote)
            for low in reading.currentLowWindows where !model.alertsLocally(copy.account, window: low.window.kind, now: now) {
                alerts.post(.remoteLowQuota(
                    RemoteAlertAccount(
                        device: copy.device.deviceID,
                        deviceName: copy.device.deviceName,
                        provider: copy.account.provider,
                        profileID: copy.account.profileID,
                        email: copy.account.email,
                        name: copy.account.displayName
                    ),
                    window: low.window
                ))
            }
        }
    }
}
