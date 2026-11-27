import Foundation
import SecondWindCore

@MainActor
func connectLiveFeatures(
    model: GuardAppModel,
    delegate: AppDelegate,
    codex: GuardRuntimeController,
    claude: ClaudeMonitorController,
    alerts: AlertRouter,
    supportDirectory: URL
) {
    let interface = delegate.interface
    let updates = LiveQuotaUpdates(snapshotFile: PreflightSnapshotFile.url(applicationSupportDirectory: supportDirectory)) {
        [weak interface] in interface?.reportNotice("Could not save the reading for preflight. Check the account in Second Wind.")
    }
    let accounts = AccountLifecycleHandlers(codex: codex, claude: claude) { [weak interface] _, notice in
        interface?.reportNotice(notice)
    }
    interface.removalKeepsResetRecord = { [weak model] account in
        account.provider == .codex
            && model?.profiles.first { $0.id == account.id.uuidString.lowercased() }?.removalKeepsResetRecord == true
    }
    interface.renameAccount = accounts.rename
    interface.removeAccount = { ref in
        try await accounts.remove(ref)
        alerts.forget(ref)
        await updates.flush()
    }
    model.onDiscardUnfinishedAccount = interface.removeAccount
    interface.preflightCommand = { ref in
        guard let path = Bundle.main.executablePath,
              let provider = QuotaProvider(rawValue: ref.provider.rawValue) else { return nil }
        return PreflightCommandLine.suggestedCommand(executablePath: path, provider: provider, accountID: ref.id)
    }
    interface.readNotificationPermission = { await alerts.permission() }
    interface.requestNotificationPermission = { await alerts.requestPermission() }
    interface.openNotificationSettings = { NotificationSettingsLink.open() }
    interface.sendTestNotification = { try await alerts.sendTest() }
    interface.readAlertPreferences = { await alerts.preferences() }
    interface.setAlertPreferences = { try await alerts.setPreferences($0) }
    model.onAccountActionFailure = { [weak interface] account, message in
        interface?.reportFailure(message, for: account)
    }
    model.onQuotaRecordsChanged = { [weak model, weak interface] provider, records in
        let kind: ProviderKind = provider == .codex ? .codex : .claude
        if interface?.providerStates[kind] != .loaded { interface?.providerDidLoad(kind) }
        let profiles = switch provider {
        case .codex: model?.profiles.map { ($0.id, $0.displayName) } ?? []
        case .claude: model?.claudeProfiles.map { ($0.id, $0.displayName) } ?? []
        }
        var names: [UUID: String] = [:]
        for (rawID, name) in profiles {
            if let id = UUID(uuidString: rawID) { names[id] = name }
        }
        alerts.ingest(provider, records: records, names: names)
        updates.receive(provider, records)
    }
    let sync = DeviceSyncCoordinator(
        model: model,
        interface: interface,
        alerts: alerts,
        stateURL: supportDirectory.appendingPathComponent("sync-state.json", isDirectory: false),
        log: RedactedEventLog(
            fileURL: supportDirectory.appendingPathComponent("sync-events.json", isDirectory: false),
            maximumEntries: 1_000
        )
    )
    interface.changeSync = { sync.setEnabled($0) }
    model.onSyncNow = { sync.syncNow() }
    model.onSetRemoteAutoReset = { device, account, enabled in
        sync.send(to: device, account: account, enabled: enabled)
    }
    delegate.onPopoverOpen = { sync.syncNow() }
    sync.start()
    delegate.finishQuotaUpdates = {
        await updates.stop()
        await alerts.settled()
    }
}
