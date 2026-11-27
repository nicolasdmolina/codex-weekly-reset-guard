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
    private var service: DeviceSyncService?
    private var loop: Task<Void, Never>?

    init(
        model: GuardAppModel,
        interface: GuardInterfaceModel,
        alerts: AlertRouter,
        stateURL: URL,
        locateFolder: @escaping @Sendable () -> DeviceSyncFolder? = { DeviceSyncFolder.iCloud() }
    ) {
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
            model?.remoteDevices = []
            model?.pendingRemoteCommands = [:]
            interface?.updateSyncStatus(.off)
            // Withdraw this Mac's snapshot so the others stop listing a Mac that left.
            Task { try? await service?.withdraw() }
            return
        }
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

    func send(to device: SyncDeviceID, account: SharedAccount, enabled: Bool) {
        let ref = AccountRef(provider: .codex, id: account.profileID)
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

    private func pass() async {
        guard let interface, interface.syncEnabled else { return }
        // Until both providers have answered, an empty roster would reject commands for real accounts.
        guard !interface.providerStates.values.contains(.loading) else { return }
        guard let service = await makeService() else {
            interface.updateSyncStatus(.unavailable)
            return
        }
        do {
            guard let result = try await service.run() else { return }
            guard interface.syncEnabled, self.service === service else { return }
            apply(result)
            interface.updateSyncStatus(.on)
        } catch {
            interface.updateSyncStatus(.failed("Could not reach iCloud Drive. Second Wind keeps trying."))
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
        model.remoteDevices = pass.devices
        model.pendingRemoteCommands = model.pendingRemoteCommands.filter { key, _ in
            for device in pass.devices {
                for account in device.accounts where GuardAppModel.remoteKey(device: device.deviceID, account: account) == key {
                    return !model.remoteState(of: account, in: device, now: now).isSettled
                }
            }
            return false
        }
        for device in pass.devices where device.freshness(at: now).isLive {
            for account in device.accounts {
                let reading = account.quotaRecord().reading(at: now, policy: .remote)
                for low in reading.currentLowWindows {
                    alerts.post(.remoteLowQuota(
                        RemoteAlertAccount(
                            device: device.deviceID,
                            deviceName: device.deviceName,
                            provider: account.provider == .codex ? .codex : .claude,
                            profileID: account.profileID,
                            name: account.displayName
                        ),
                        window: low.window
                    ))
                }
            }
        }
    }
}
