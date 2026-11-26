import Foundation
import SecondWindCore

/// Where Claude resets are redeemed. Anthropic offers no supported way to redeem one outside
/// claude.ai or Claude Desktop, so Second Wind opens this page instead of acting on its own.
let claudeUsageSettingsURL = URL(string: "https://claude.ai/settings/usage")!

enum ClaudeConnectionStatus: Equatable, Sendable {
    case checking
    case notSignedIn
    case signingIn
    case verified
    case identityMismatch(found: String?)
    case notSubscription
    case stopped
    case failed(String)
}

struct ClaudeProfileSnapshot: Equatable, Sendable {
    let id: UUID
    var displayName: String
    var expectedEmail: String?
    var planName: String?
    var report: ClaudeUsageReport?
    var status: ClaudeConnectionStatus
    var signInURL: URL?
    /// Display, alert and preflight evidence: the persisted report plus this session's failures.
    var quota: QuotaAccountRecord
}

struct ClaudeMonitorSnapshot: Equatable, Sendable {
    var profiles: [ClaudeProfileSnapshot]
    var isChecking: Bool
    /// The monitor clock when this snapshot was taken; quota readings derive at this time.
    var generatedAt: Date? = nil
}

enum ClaudeMonitorError: Error, LocalizedError, Equatable {
    case invalidEmail
    case duplicateEmail
    case readOnly
    case unknownProfile
    case stateUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidEmail: "Enter the email address you use to sign in to Claude."
        case .duplicateEmail: "That Claude account is already listed."
        case .readOnly: "Diagnostics mode cannot add accounts or sign in."
        case .unknownProfile: "That Claude account is no longer listed."
        case .stateUnavailable: "Second Wind could not read its saved Claude accounts. Try again."
        }
    }
}

struct ClaudeMonitorConfiguration: Sendable {
    var isReadOnly: Bool
    var executableURL: URL
    var applicationSupportDirectory: URL
    var pollInterval: Duration = .seconds(300)

    var stateURL: URL {
        applicationSupportDirectory.appendingPathComponent("claude-state.json", isDirectory: false)
    }

    var profilesRoot: URL {
        ClaudeProfileConfiguration.defaultRootDirectory(applicationSupportDirectory: applicationSupportDirectory)
    }
}

/// Watches Claude plan limits through Claude Code's local `/usage` command and alerts when a
/// window runs low. It never redeems anything; redemption stays a deliberate click on claude.ai.
actor ClaudeMonitorController {
    private let configuration: ClaudeMonitorConfiguration
    private let cli: ClaudeCLI
    private let store: SecureStateStore<ClaudePersistentState>
    private let updateHandler: @Sendable (ClaudeMonitorSnapshot) async -> Void
    private let notificationHandler: @Sendable (AlertPost) -> Void
    private let now: @Sendable () -> Date

    private var state = ClaudePersistentState()
    private var statuses: [UUID: ClaudeConnectionStatus] = [:]
    /// The latest failed refresh per account, cleared by the next good read. Not persisted: after a
    /// relaunch the saved report reads as stale with its own timestamp.
    private var refreshFailures: [UUID: QuotaRefreshFailure] = [:]
    /// Accounts with a live, verified report this session. Until then a saved report is shown as
    /// restored and unverified, never as current.
    private var verifiedThisSession = Set<UUID>()
    /// Bumped when a sign-in starts. A check that began earlier must not record anything after it:
    /// its result belongs to the previous sign-in.
    private var signInGenerations: [UUID: UInt64] = [:]
    /// False until the saved roster loads. Nothing is refreshed, published or saved before that,
    /// so an unreadable store can never look like "no Claude accounts" or be overwritten.
    private var isRosterLoaded = false
    private var signInURLs: [UUID: URL] = [:]
    private var loginSessions: [UUID: ClaudeLoginSession] = [:]
    private var isChecking = false
    private var pollTask: Task<Void, Never>?
    /// Accounts being removed: no check, sign-in or rename starts for them.
    private var removingProfiles = Set<UUID>()
    /// Running checks per account. A removal waits until no `claude` command uses the folder.
    private var activeChecks: [UUID: Int] = [:]
    private var stateWriteLocked = false
    private var stateWriteWaiters: [CheckedContinuation<Void, Never>] = []
    private var removalDrainTimeout: Duration = .seconds(20)

    init(
        configuration: ClaudeMonitorConfiguration,
        cli: ClaudeCLI? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        updateHandler: @escaping @Sendable (ClaudeMonitorSnapshot) async -> Void,
        notificationHandler: @escaping @Sendable (AlertPost) -> Void
    ) {
        self.configuration = configuration
        self.cli = cli ?? ClaudeCLI(runner: ProcessClaudeCommandRunner(executableURL: configuration.executableURL))
        self.store = SecureStateStore(fileURL: configuration.stateURL, maximumBytes: 1_024 * 1_024)
        self.now = now
        self.updateHandler = updateHandler
        self.notificationHandler = notificationHandler
    }

    func start() async throws {
        try await loadRoster()
        await publish()
        guard !state.profiles.isEmpty else { return schedulePolling() }
        await checkNow()
        schedulePolling()
    }

    private func loadRoster() async throws {
        guard !isRosterLoaded else { return }
        let saved = try await store.load()
        guard !isRosterLoaded else { return }
        if let saved, !configuration.isReadOnly {
            _ = try OwnedProfileDirectory.recoverInterruptedDiscards(
                root: configuration.profilesRoot, enrolledIDs: Set(saved.profiles.map(\.id))
            )
        }
        state = saved ?? ClaudePersistentState()
        isRosterLoaded = true
        for profile in state.profiles where state.state(for: profile.id).monitoringStopped {
            recordFailure(.monitoringStopped, for: profile.id)
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        for session in loginSessions.values { session.cancel() }
        loginSessions.removeAll()
    }

    func snapshot() -> ClaudeMonitorSnapshot {
        ClaudeMonitorSnapshot(
            profiles: state.profiles.map { profile in
                let saved = state.state(for: profile.id)
                return ClaudeProfileSnapshot(
                    id: profile.id,
                    displayName: profile.displayName,
                    expectedEmail: profile.expectedEmail,
                    planName: saved.planName,
                    report: saved.lastReport,
                    status: statuses[profile.id] ?? (saved.monitoringStopped ? .stopped : .checking),
                    signInURL: signInURLs[profile.id],
                    quota: QuotaAccountRecord(
                        provider: .claude,
                        accountID: profile.id,
                        lastSuccess: saved.lastReport?.quotaObservation,
                        lastFailure: refreshFailures[profile.id],
                        lastSuccessRestored: !verifiedThisSession.contains(profile.id)
                    )
                )
            },
            isChecking: isChecking,
            generatedAt: now()
        )
    }

    func checkNow() async {
        guard !isChecking else { return }
        isChecking = true
        if !isRosterLoaded {
            // Retry the load a failed start left behind; without it there is nothing to check.
            guard (try? await loadRoster()) != nil else {
                isChecking = false
                return
            }
            if pollTask == nil { schedulePolling() }
        }
        await publish()
        for profile in state.profiles where loginSessions[profile.id] == nil {
            await check(profile)
            await publish()
        }
        isChecking = false
        await publish()
    }

    func addProfile(email rawEmail: String, displayName rawName: String) async throws -> UUID {
        guard !configuration.isReadOnly else { throw ClaudeMonitorError.readOnly }
        guard isRosterLoaded else { throw ClaudeMonitorError.stateUnavailable }
        guard MonitorPersistence.isValidEmail(rawEmail) else { throw ClaudeMonitorError.invalidEmail }
        let email = MonitorPersistence.normalizedEmail(rawEmail)
        guard !state.profiles.contains(where: { $0.expectedEmail == email }) else {
            throw ClaudeMonitorError.duplicateEmail
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = ClaudeProfileConfiguration(
            displayName: name.isEmpty ? Self.defaultName(for: email) : String(name.prefix(48)),
            expectedEmail: email
        )
        try await withStateWrite {
            guard !state.profiles.contains(where: { $0.expectedEmail == email }) else {
                throw ClaudeMonitorError.duplicateEmail
            }
            var next = state
            next.profiles.append(profile)
            try await store.save(next)
            state = next
        }
        statuses[profile.id] = .notSignedIn
        await publish()
        return profile.id
    }

    /// Signs the profile in through `claude auth login`. Claude Code opens the browser itself.
    func connect(profileID: UUID) async {
        guard !configuration.isReadOnly, isRosterLoaded, loginSessions[profileID] == nil,
              !removingProfiles.contains(profileID),
              let profile = state.profiles.first(where: { $0.id == profileID })
        else { return }
        signInGenerations[profileID, default: 0] &+= 1
        let directory: URL
        do {
            directory = try profile.prepareConfigDirectory(root: configuration.profilesRoot)
        } catch {
            statuses[profileID] = .failed("Could not prepare this account's private folder.")
            recordFailure(.unavailable, for: profileID)
            return await publish()
        }

        // Reconnecting is how a user resumes monitoring after Claude Code changed under it.
        if state.state(for: profileID).monitoringStopped {
            await withStateWrite {
                guard state.profiles.contains(where: { $0.id == profileID }) else { return }
                var saved = state.state(for: profileID)
                saved.monitoringStopped = false
                var next = state
                next.setState(saved, for: profileID)
                try? await store.save(next)
                state = next
            }
        }
        // A removal may have started while that write was suspended; never sign in after it.
        guard !removingProfiles.contains(profileID),
              state.profiles.contains(where: { $0.id == profileID }) else {
            return await publish()
        }

        let session = ClaudeLoginSession(
            executableURL: configuration.executableURL,
            configDirectory: directory,
            email: profile.expectedEmail
        )
        loginSessions[profileID] = session
        statuses[profileID] = .signingIn
        signInURLs[profileID] = nil
        recordFailure(.signInRequired, for: profileID)
        await publish()

        do {
            try await session.run { [weak self] url in
                Task { await self?.recordSignInURL(url, for: profileID) }
            }
            loginSessions[profileID] = nil
            signInURLs[profileID] = nil
            await check(profile)
        } catch {
            loginSessions[profileID] = nil
            signInURLs[profileID] = nil
            statuses[profileID] = (error as? ClaudeCLIError) == .loginCancelled
                ? .notSignedIn
                : .failed((error as? LocalizedError)?.errorDescription ?? "Claude sign-in did not finish.")
        }
        if !state.profiles.contains(where: { $0.id == profileID }) {
            statuses[profileID] = nil
        }
        await publish()
    }

    func cancelSignIn(profileID: UUID) async {
        loginSessions[profileID]?.cancel()
    }

    private func recordSignInURL(_ url: URL, for profileID: UUID) async {
        guard loginSessions[profileID] != nil else { return }
        signInURLs[profileID] = url
        await publish()
    }

    private func check(_ profile: ClaudeProfileConfiguration) async {
        guard !removingProfiles.contains(profile.id),
              state.profiles.contains(where: { $0.id == profile.id }) else { return }
        activeChecks[profile.id, default: 0] += 1
        defer {
            let remaining = (activeChecks[profile.id] ?? 1) - 1
            activeChecks[profile.id] = remaining > 0 ? remaining : nil
        }
        let generation = signInGenerations[profile.id, default: 0]
        func isCurrent() -> Bool { signInGenerations[profile.id, default: 0] == generation }
        var saved = state.state(for: profile.id)
        guard !saved.monitoringStopped else {
            statuses[profile.id] = .stopped
            recordFailure(.monitoringStopped, for: profile.id)
            return
        }
        let directory = profile.configDirectoryURL(root: configuration.profilesRoot)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            statuses[profile.id] = .notSignedIn
            recordFailure(.signInRequired, for: profile.id)
            return
        }

        do {
            let auth = try await cli.authStatus(configDirectory: directory)
            guard isCurrent() else { return }
            guard auth.loggedIn else {
                statuses[profile.id] = .notSignedIn
                recordFailure(.signInRequired, for: profile.id)
                return
            }
            guard auth.usesSubscription else {
                statuses[profile.id] = .notSubscription
                recordFailure(.noPlanLimits, for: profile.id)
                return
            }
            let found = auth.email.map(MonitorPersistence.normalizedEmail)
            if let expected = profile.expectedEmail, found != expected {
                statuses[profile.id] = .identityMismatch(found: found)
                recordFailure(.wrongAccount, for: profile.id)
                return
            }
            saved.verifiedEmail = found
            saved.planName = auth.planName

            let report = try await cli.usage(configDirectory: directory, observedAt: now())
            guard isCurrent() else { return }
            saved.lastReport = report
            let finished = saved
            let alerts = try await withStateWrite { () -> [(ClaudeAlertPolicy.Alert, ClaudeProfileConfiguration)] in
                guard isCurrent(),
                      let current = state.profiles.first(where: { $0.id == profile.id }),
                      !removingProfiles.contains(profile.id) else { return [] }
                var next = state
                next.setState(finished, for: profile.id)
                let alerts = current.alertsEnabled && !configuration.isReadOnly
                    ? ClaudeAlertPolicy.newAlerts(for: report, alreadySent: state.alertKeys(for: profile.id))
                    : []
                next.rememberAlerts(alerts.map(\.key), for: profile.id)
                try await store.save(next)
                state = next
                // A sign-in that started during the save owns the status from here.
                guard isCurrent() else { return [] }
                refreshFailures[profile.id] = nil
                verifiedThisSession.insert(profile.id)
                statuses[profile.id] = .verified
                return alerts.map { ($0, current) }
            }
            for (alert, current) in alerts {
                if let window = report.quotaObservation.windows.first(where: { $0.kind.key == alert.window.scope.key }) {
                    notificationHandler(.lowQuota(AccountRef(provider: .claude, id: profile.id),
                                                  name: current.displayName, window: window))
                }
            }
        } catch ClaudeUsageParseError.notLocalCommand {
            saved.monitoringStopped = true
            let stopped = saved
            await withStateWrite {
                guard state.profiles.contains(where: { $0.id == profile.id }) else { return }
                var next = state
                next.setState(stopped, for: profile.id)
                try? await store.save(next)
                state = next
                statuses[profile.id] = .stopped
                recordFailure(.monitoringStopped, for: profile.id)
            }
        } catch {
            guard isCurrent() else { return }
            statuses[profile.id] = .failed(
                (error as? LocalizedError)?.errorDescription ?? "Could not read Claude usage."
            )
            recordFailure(Self.failureReason(error), for: profile.id)
        }
    }

    /// `failedAt` marks when this run of failures began, so repeated polls keep it.
    private func recordFailure(_ reason: QuotaFailureReason, for profileID: UUID) {
        guard refreshFailures[profileID]?.reason != reason else { return }
        refreshFailures[profileID] = QuotaRefreshFailure(failedAt: now(), reason: reason)
    }

    private static func failureReason(_ error: any Error) -> QuotaFailureReason {
        switch error {
        case ClaudeUsageParseError.malformedOutput: .unreadable
        case ClaudeUsageParseError.noPlanLimits: .noPlanLimits
        default: .unavailable
        }
    }

    /// Renames one Claude account. Only its display name changes.
    func renameProfile(profileID: UUID, displayName rawName: String) async throws {
        guard !configuration.isReadOnly else { throw AccountLifecycleError.readOnly }
        guard isRosterLoaded else { throw AccountLifecycleError.unavailable }
        guard let name = AccountNameRules.normalized(
            rawName,
            maximumLength: AccountNameRules.claudeMaximumLength
        ) else {
            throw AccountLifecycleError.invalidName
        }
        guard !removingProfiles.contains(profileID) else { throw AccountLifecycleError.busy }
        try await withStateWrite {
            var next = state
            guard ClaudeAccountLifecycle.rename(profileID, to: name, in: &next) else {
                throw AccountLifecycleError.accountNotFound
            }
            guard next != state else { return }
            do {
                try await store.save(next)
            } catch {
                throw AccountLifecycleError.notSaved
            }
            state = next
        }
        await publish()
    }

    /// Removes one Claude account.
    ///
    /// Order: stop its sign-in and wait for running commands, sign it out through Claude Code so
    /// the Keychain item for its folder goes too, move the folder aside, save the shorter list,
    /// then delete the folder. If the save fails the folder is moved back. A missing or failing
    /// Claude Code never blocks removal; the outcome then says the sign-in may remain.
    func removeProfile(profileID: UUID) async throws -> AccountRemovalOutcome {
        guard !configuration.isReadOnly else { throw AccountLifecycleError.readOnly }
        guard isRosterLoaded else { throw AccountLifecycleError.unavailable }
        guard let profile = state.profiles.first(where: { $0.id == profileID }) else {
            throw AccountLifecycleError.accountNotFound
        }
        guard removingProfiles.insert(profileID).inserted else { throw AccountLifecycleError.busy }
        defer { removingProfiles.remove(profileID) }

        guard await waitUntilIdle(profileID) else {
            await publish()
            throw AccountLifecycleError.busy
        }

        var outcome = AccountRemovalOutcome()
        var signedOut = false
        let root = configuration.profilesRoot
        let directory = profile.configDirectoryURL(root: root)
        if OwnedProfileDirectory.isOwnedRealDirectory(profileID: profileID, root: root) {
            signedOut = (try? await cli.signOut(configDirectory: directory)) ?? false
            outcome.claudeSignInMayRemain = !signedOut
            if signedOut {
                statuses[profileID] = .notSignedIn
                recordFailure(.signInRequired, for: profileID)
            }
        } else if FileManager.default.fileExists(atPath: directory.path)
                    || (try? FileManager.default.destinationOfSymbolicLink(atPath: directory.path)) != nil {
            // Something other than the app's own folder sits at this path. Never point Claude
            // Code at it; the link or file itself is unlinked below.
            outcome.claudeSignInMayRemain = true
        }

        let isolated: Bool
        do {
            isolated = try OwnedProfileDirectory.isolate(profileID: profileID, root: root)
        } catch {
            await publish()
            throw signedOut ? AccountLifecycleError.signedOutButNotRemoved : .notSaved
        }
        do {
            try await withStateWrite {
                var next = state
                guard ClaudeAccountLifecycle.remove(profileID, from: &next) else { return }
                try await store.save(next)
                state = next
            }
        } catch {
            // The write can reach disk even when its durability check fails.
            if let saved = try? await store.load(),
               !saved.profiles.contains(where: { $0.id == profileID }) {
                await withStateWrite { _ = ClaudeAccountLifecycle.remove(profileID, from: &state) }
            } else {
                if isolated {
                    _ = try? OwnedProfileDirectory.restoreIsolated(profileID: profileID, root: root)
                }
                await publish()
                throw signedOut ? AccountLifecycleError.signedOutButNotRemoved : .notSaved
            }
        }

        statuses[profileID] = nil
        refreshFailures[profileID] = nil
        verifiedThisSession.remove(profileID)
        signInURLs[profileID] = nil
        do {
            try OwnedProfileDirectory.discardIsolated(profileID: profileID, root: root)
        } catch {
            outcome.folderCleanupPending = true
        }
        await publish()
        return outcome
    }

    func overrideRemovalDrainTimeoutForTesting(_ timeout: Duration) {
        removalDrainTimeout = timeout
    }

    private func waitUntilIdle(_ profileID: UUID) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: removalDrainTimeout)
        while loginSessions[profileID] != nil || activeChecks[profileID] != nil {
            loginSessions[profileID]?.cancel()
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Serializes every read-modify-write of `state` that spans `store.save`, so a rename or
    /// removal can never be overwritten by a check that copied the state before it.
    private func withStateWrite<T>(_ body: () async throws -> T) async rethrows -> T {
        while stateWriteLocked {
            await withCheckedContinuation { stateWriteWaiters.append($0) }
        }
        stateWriteLocked = true
        defer {
            stateWriteLocked = false
            if !stateWriteWaiters.isEmpty { stateWriteWaiters.removeFirst().resume() }
        }
        return try await body()
    }

    private func schedulePolling() {
        pollTask?.cancel()
        let interval = configuration.pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.checkNow()
            }
        }
    }

    private func publish() async {
        guard isRosterLoaded else { return }
        await updateHandler(snapshot())
    }

    static func defaultName(for email: String) -> String {
        let local = email.split(separator: "@").first.map(String.init) ?? "Claude"
        return local.prefix(1).uppercased() + local.dropFirst()
    }

}

@MainActor
extension GuardAppModel {
    func apply(_ snapshot: ClaudeMonitorSnapshot) {
        let readingTime = snapshot.generatedAt ?? referenceDate ?? Date()
        claudeProfiles = snapshot.profiles.map { Self.presentation(for: $0, at: readingTime) }
        isCheckingClaude = snapshot.isChecking
        onQuotaRecordsChanged?(.claude, snapshot.profiles.map(\.quota))
    }

    static func presentation(for profile: ClaudeProfileSnapshot, at now: Date) -> ClaudeProfilePresentation {
        let reading = profile.quota.reading(at: now)
        let current = Dictionary(
            reading.windows.map { ($0.window.kind.key, $0.isCurrent) },
            uniquingKeysWith: { first, _ in first }
        )
        var windows: [ClaudeWindowPresentation] = []
        if let report = profile.report {
            windows = report.allWindows.map { window in
                ClaudeWindowPresentation(
                    id: window.scope.key,
                    label: Self.windowLabel(window.scope),
                    remainingPercent: window.remainingPercent,
                    resetsAt: window.resetsAt,
                    isCurrent: current[window.scope.key] ?? false
                )
            }
        }
        let status: ClaudeProfileStatus
        let detail: String
        switch profile.status {
        case .checking:
            status = .checking
            detail = "Reading usage from Claude Code."
        case .notSignedIn:
            status = .signedOut
            detail = "Sign in to start monitoring."
        case .signingIn:
            status = .signingIn
            detail = "Finish signing in in your browser."
        case .verified:
            if let warning = reading.warning, warning.isCurrent {
                status = .low
                detail = "Use a reset from Claude settings if you have one."
            } else {
                status = .healthy
                detail = "Checked every 5 minutes."
            }
        case let .identityMismatch(found):
            status = .attention
            detail = found.map { "Signed in as \($0). Reconnect with the expected account." }
                ?? "Signed in to a different account. Reconnect with the expected account."
        case .notSubscription:
            status = .attention
            detail = "This sign-in has no Claude plan limits. Reconnect with a Pro or Max account."
        case .stopped:
            status = .attention
            detail = ClaudeUsageParseError.notLocalCommand.localizedDescription
        case let .failed(message):
            status = .attention
            detail = message
        }
        return ClaudeProfilePresentation(
            id: profile.id.uuidString.lowercased(),
            displayName: profile.displayName,
            accountHint: Self.maskedEmail(profile.expectedEmail),
            planName: profile.planName,
            windows: windows,
            status: status,
            detail: detail,
            signInURL: profile.signInURL,
            quota: profile.quota
        )
    }

    static func windowLabel(_ scope: ClaudeUsageWindow.Scope) -> String {
        switch scope {
        case .session: "5-hour"
        case .weekly: "Weekly"
        case let .modelWeekly(name): name.replacingOccurrences(of: " only", with: "")
        }
    }

    static func maskedEmail(_ email: String?) -> String {
        guard let email else { return "Claude account" }
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, let first = parts[0].first else { return "Claude account" }
        return "\(first)•••@\(parts[1])"
    }
}

@MainActor
func makeClaudeMonitor(model: GuardAppModel, configuration: ClaudeMonitorConfiguration, alerts: AlertRouter) -> ClaudeMonitorController {
    let monitor = ClaudeMonitorController(
        configuration: configuration,
        updateHandler: { [weak model] snapshot in
            await MainActor.run { model?.apply(snapshot) }
        },
        notificationHandler: { alerts.post($0) }
    )
    model.onAddClaudeProfile = { [weak monitor, weak model] email, displayName in
        Task { @MainActor in
            defer { model?.isAddingProfile = false }
            do {
                guard let monitor else { throw ClaudeMonitorError.unknownProfile }
                let id = try await monitor.addProfile(email: email, displayName: displayName)
                model?.profileEmail = ""
                model?.profileDisplayName = ""
                model?.isShowingAddProfile = false
                model?.enrollmentError = nil
                Task { _ = await alerts.requestPermission() }
                Task { await monitor.connect(profileID: id) }
            } catch {
                model?.isShowingAddProfile = true
                model?.enrollmentError = (error as? LocalizedError)?.errorDescription
                    ?? "Could not save the Claude account."
            }
        }
    }
    model.onConnectClaude = { [weak monitor] rawID in
        guard let id = UUID(uuidString: rawID) else { return }
        Task { await monitor?.connect(profileID: id) }
    }
    model.onCancelClaudeSignIn = { [weak monitor] rawID in
        guard let id = UUID(uuidString: rawID) else { return }
        Task { await monitor?.cancelSignIn(profileID: id) }
    }
    return monitor
}
