import Foundation
import Testing
@testable import SecondWind
import SecondWindCore

@Test @MainActor func anUnloadedCodexRosterCannotLookLikeZeroEnrolledAccounts() {
    let model = GuardAppModel()
    var published: [QuotaProvider] = []
    model.onQuotaRecordsChanged = { provider, _ in published.append(provider) }
    model.apply(GuardRuntimeSnapshot.empty)
    #expect(published.isEmpty && !model.isReady)
    var knownEmpty = GuardRuntimeSnapshot.empty
    knownEmpty.hasLoadedProfiles = true
    model.apply(knownEmpty)
    #expect(published == [.codex] && model.isReady)
}

@Test @MainActor func preflightPublishesRosterChangesInOrderAndClearsOnQuit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = PreflightSnapshotFile.url(applicationSupportDirectory: root)
    let instant = Date(timeIntervalSince1970: 1_900_000_000)
    let codex = QuotaAccountRecord(provider: .codex, accountID: UUID())
    let claude = QuotaAccountRecord(provider: .claude, accountID: UUID())
    let updates = LiveQuotaUpdates(
        snapshotFile: file,
        now: { instant },
        reportWriteFailure: { Issue.record("Could not publish the temporary snapshot") }
    )
    updates.receive(.codex, [codex])
    await updates.flush()
    let first = try PreflightSnapshotFile.read(from: file).get()
    updates.receive(.claude, [claude])
    await updates.flush()
    let both = try PreflightSnapshotFile.read(from: file).get()
    updates.receive(.codex, [])
    await updates.flush()
    let removed = try PreflightSnapshotFile.read(from: file).get()
    await updates.stop()

    #expect([first, both, removed].map { Set($0.accounts.map(\.accountID)) } == [
        Set([codex.accountID]), Set([codex.accountID, claude.accountID]), Set([claude.accountID]),
    ])
    #expect(first.providers == [.codex])
    #expect(removed.providers == [.codex, .claude])
    let stopped = try PreflightSnapshotFile.read(from: file).get()
    #expect(stopped.providers.isEmpty && stopped.accounts.isEmpty)
}

@Test @MainActor func retryAfterAWriteFailureAlwaysPublishesTheLatestAccounts() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let support = root.appendingPathComponent("support")
    let saved = root.appendingPathComponent("previous")
    let file = PreflightSnapshotFile.url(applicationSupportDirectory: support)
    let a = QuotaAccountRecord(provider: .codex, accountID: UUID())
    let b = QuotaAccountRecord(provider: .codex, accountID: UUID())
    let claude = QuotaAccountRecord(provider: .claude, accountID: UUID())
    var failures = 0
    let updates = LiveQuotaUpdates(snapshotFile: file) { failures += 1 }
    updates.receive(.codex, [a])
    await updates.flush()
    for keepB in [false, true] {
        try fm.moveItem(at: support, to: saved)
        try Data().write(to: support)
        updates.receive(.codex, [a, b])
        await updates.flush()
        try fm.removeItem(at: support)
        try fm.moveItem(at: saved, to: support)
        if !keepB { updates.receive(.codex, [a]) }
        updates.receive(.claude, [claude])
        await updates.flush()
        let actual = try PreflightSnapshotFile.read(from: file).get()
        #expect(Set(actual.accounts.map(\.accountID)) == Set((keepB ? [a, b, claude] : [a, claude]).map(\.accountID)))
    }
    #expect(failures == 2)
    await updates.stop()
}

@Test @MainActor func liveAccountActionsUpdateTheMenuAndThePreflightFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = URL(fileURLWithPath: "/usr/bin/false")
    let configuration = GuardRuntimeConfiguration(
        operationMode: .production, codexExecutableURL: executable,
        applicationSupportDirectory: root, profilesDirectory: root.appendingPathComponent("profiles")
    )
    let claudeConfiguration = ClaudeMonitorConfiguration(
        isReadOnly: false, executableURL: executable, applicationSupportDirectory: root
    )
    let profile = ClaudeProfileConfiguration(displayName: "Original", expectedEmail: "test@example.com")
    try await SecureStateStore<ClaudePersistentState>(fileURL: claudeConfiguration.stateURL)
        .save(ClaudePersistentState(profiles: [profile]))
    let model = GuardAppModel()
    let codex = GuardRuntimeController(configuration: configuration, updateHandler: { model.apply($0) })
    let claude = ClaudeMonitorController(
        configuration: claudeConfiguration, updateHandler: { await model.apply($0) }, notificationHandler: { _ in }
    )
    var quiet = configuration
    quiet.operationMode = .readOnly
    let interface = GuardInterfaceModel(isPreview: false, isReadOnly: false, preferenceDefaults: nil)
    let delegate = AppDelegate(model: model, runtime: codex, claudeMonitor: claude, interface: interface)
    connectLiveFeatures(model: model, delegate: delegate, codex: codex, claude: claude,
                        alerts: makeAlertRouter(configuration: quiet), supportDirectory: root)
    let account = AccountRef(provider: .claude, id: profile.id)
    let file = PreflightSnapshotFile.url(applicationSupportDirectory: root)
    let request = try #require(PreflightRequest(minimumSessionPercent: 1, minimumWeeklyPercent: nil, accountID: account.id))
    func verdict() -> PreflightOutcome {
        PreflightEvaluator.evaluate(request, snapshot: PreflightSnapshotFile.read(from: file), now: Date())
    }

    // This fixture enrolls only Claude. Publish the empty local CLI roster as at app launch.
    model.onQuotaRecordsChanged?(.antigravity, [])
    _ = try await codex.start()
    interface.providerDidFail(.claude, reason: "Temporary test failure")
    try await claude.start()
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while verdict().reason != .refreshFailed && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(verdict().checks.first?.failure == .signInRequired)
    #expect(interface.allProvidersLoaded && interface.notices.isEmpty)
    try await interface.renameAccount?(account, "Renamed")
    #expect(model.claudeProfiles.first?.displayName == "Renamed")
    try await interface.removeAccount?(account)
    #expect(model.claudeProfiles.isEmpty)
    #expect(verdict().reason == .accountNotFound)
    await claude.stop()
    await codex.stop()
    await delegate.finishQuotaUpdates?()
    #expect(try PreflightSnapshotFile.read(from: file).get().providers.isEmpty)
}
