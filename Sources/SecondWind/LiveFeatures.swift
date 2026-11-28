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
    let antigravity = AntigravityMonitor(model: model, didEnroll: {
        Task { _ = await alerts.requestPermission() }
    }) {
        try await AntigravityCLI.usage(in: supportDirectory.appendingPathComponent("agy", isDirectory: true))
    }
    let accounts = AccountLifecycleHandlers(codex: codex, claude: claude, antigravity: antigravity) { [weak interface] _, notice in
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
        guard let path = Bundle.main.executablePath else { return nil }
        return PreflightCommandLine.suggestedCommand(executablePath: path, provider: ref.provider, accountID: ref.id)
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
        if interface?.providerStates[provider] != .loaded { interface?.providerDidLoad(provider) }
        let profiles = switch provider {
        case .codex: model?.profiles.map { ($0.id, $0.displayName) } ?? []
        case .claude: model?.claudeProfiles.map { ($0.id, $0.displayName) } ?? []
        case .antigravity: model?.antigravity.map { [($0.ref.id.uuidString, $0.name)] } ?? []
        }
        var names: [UUID: String] = [:]
        for (rawID, name) in profiles {
            if let id = UUID(uuidString: rawID) { names[id] = name }
        }
        alerts.ingest(provider, records: records, names: names)
        updates.receive(provider, records)
    }
    delegate.antigravity = antigravity
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
    model.onSetRemoteAutoReset = { device, account, enabled, card in
        sync.send(to: device, account: account, enabled: enabled, reportingTo: card)
    }
    // Another Mac's removal request runs the same path as this Mac's own Remove.
    model.removeLocalAccount = interface.removeAccount
    model.onRemoveRemoteAccount = { device, account, card in
        sync.sendRemoval(to: device, account: account, reportingTo: card)
    }
    delegate.onPopoverOpen = { sync.syncNow() }
    sync.start()
    delegate.finishQuotaUpdates = {
        await updates.stop()
        await alerts.settled()
    }
}
