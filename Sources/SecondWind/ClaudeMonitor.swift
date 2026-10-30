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
}

struct ClaudeMonitorSnapshot: Equatable, Sendable {
    var profiles: [ClaudeProfileSnapshot]
    var isChecking: Bool
}

enum ClaudeMonitorError: Error, LocalizedError, Equatable {
    case invalidEmail
    case duplicateEmail
    case readOnly
    case unknownProfile

    var errorDescription: String? {
        switch self {
        case .invalidEmail: "Enter the email address you use to sign in to Claude."
        case .duplicateEmail: "That Claude account is already listed."
        case .readOnly: "Diagnostics mode cannot add accounts or sign in."
        case .unknownProfile: "That Claude account is no longer listed."
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
    private let notificationHandler: @Sendable (String, String) -> Void
    private let now: @Sendable () -> Date

    private var state = ClaudePersistentState()
    private var statuses: [UUID: ClaudeConnectionStatus] = [:]
    private var signInURLs: [UUID: URL] = [:]
    private var loginSessions: [UUID: ClaudeLoginSession] = [:]
    private var isChecking = false
    private var pollTask: Task<Void, Never>?

    init(
        configuration: ClaudeMonitorConfiguration,
        cli: ClaudeCLI? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        updateHandler: @escaping @Sendable (ClaudeMonitorSnapshot) async -> Void,
        notificationHandler: @escaping @Sendable (String, String) -> Void
    ) {
        self.configuration = configuration
        self.cli = cli ?? ClaudeCLI(runner: ProcessClaudeCommandRunner(executableURL: configuration.executableURL))
        self.store = SecureStateStore(fileURL: configuration.stateURL, maximumBytes: 1_024 * 1_024)
        self.now = now
        self.updateHandler = updateHandler
        self.notificationHandler = notificationHandler
    }

    func start() async throws {
        state = try await store.load() ?? ClaudePersistentState()
        await publish()
        guard !state.profiles.isEmpty else { return schedulePolling() }
        await checkNow()
        schedulePolling()
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
                    signInURL: signInURLs[profile.id]
                )
            },
            isChecking: isChecking
        )
    }

    func checkNow() async {
        guard !isChecking else { return }
        isChecking = true
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
        var next = state
        next.profiles.append(profile)
        try await store.save(next)
        state = next
        statuses[profile.id] = .notSignedIn
        await publish()
        return profile.id
    }

    /// Signs the profile in through `claude auth login`. Claude Code opens the browser itself.
    func connect(profileID: UUID) async {
        guard !configuration.isReadOnly, loginSessions[profileID] == nil,
              let profile = state.profiles.first(where: { $0.id == profileID })
        else { return }
        let directory: URL
        do {
            directory = try profile.prepareConfigDirectory(root: configuration.profilesRoot)
        } catch {
            statuses[profileID] = .failed("Could not prepare this account's private folder.")
            return await publish()
        }

        // Reconnecting is how a user resumes monitoring after Claude Code changed under it.
        var saved = state.state(for: profileID)
        if saved.monitoringStopped {
            saved.monitoringStopped = false
            var next = state
            next.setState(saved, for: profileID)
            try? await store.save(next)
            state = next
        }

        let session = ClaudeLoginSession(
            executableURL: configuration.executableURL,
            configDirectory: directory,
            email: profile.expectedEmail
        )
        loginSessions[profileID] = session
        statuses[profileID] = .signingIn
        signInURLs[profileID] = nil
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
        var saved = state.state(for: profile.id)
        guard !saved.monitoringStopped else {
            statuses[profile.id] = .stopped
            return
        }
        let directory = profile.configDirectoryURL(root: configuration.profilesRoot)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            statuses[profile.id] = .notSignedIn
            return
        }

        do {
            let auth = try await cli.authStatus(configDirectory: directory)
            guard auth.loggedIn else {
                statuses[profile.id] = .notSignedIn
                return
            }
            guard auth.usesSubscription else {
                statuses[profile.id] = .notSubscription
                return
            }
            let found = auth.email.map(MonitorPersistence.normalizedEmail)
            if let expected = profile.expectedEmail, found != expected {
                statuses[profile.id] = .identityMismatch(found: found)
                return
            }
            saved.verifiedEmail = found
            saved.planName = auth.planName

            let report = try await cli.usage(configDirectory: directory, observedAt: now())
            saved.lastReport = report
            statuses[profile.id] = .verified
            var next = state
            next.setState(saved, for: profile.id)
            let alerts = profile.alertsEnabled && !configuration.isReadOnly
                ? ClaudeAlertPolicy.newAlerts(for: report, alreadySent: Set(state.sentAlertKeys))
                : []
            next.rememberAlerts(alerts.map(\.key))
            try await store.save(next)
            state = next
            for alert in alerts {
                notificationHandler(Self.alertTitle(for: alert.window), Self.alertBody(for: alert.window, profile: profile))
            }
        } catch ClaudeUsageParseError.notLocalCommand {
            saved.monitoringStopped = true
            var next = state
            next.setState(saved, for: profile.id)
            try? await store.save(next)
            state = next
            statuses[profile.id] = .stopped
        } catch {
            statuses[profile.id] = .failed(
                (error as? LocalizedError)?.errorDescription ?? "Could not read Claude usage."
            )
        }
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
        await updateHandler(snapshot())
    }

    static func defaultName(for email: String) -> String {
        let local = email.split(separator: "@").first.map(String.init) ?? "Claude"
        return local.prefix(1).uppercased() + local.dropFirst()
    }

    static func windowName(_ scope: ClaudeUsageWindow.Scope) -> String {
        switch scope {
        case .session: "5-hour"
        case .weekly: "weekly"
        case let .modelWeekly(name): "\(name) weekly"
        }
    }

    static func alertTitle(for window: ClaudeUsageWindow) -> String {
        "Claude \(windowName(window.scope)) limit is low"
    }

    static func alertBody(for window: ClaudeUsageWindow, profile: ClaudeProfileConfiguration) -> String {
        let remaining = Int(window.remainingPercent.rounded(.down))
        var body = "\(profile.displayName) has \(remaining)% left."
        if let reset = window.resetsAt {
            body += " Resets \(reset.formatted(.relative(presentation: .named)))."
        }
        body += " Open Second Wind to use a reset if you have one."
        return body
    }
}

@MainActor
extension GuardAppModel {
    func apply(_ snapshot: ClaudeMonitorSnapshot) {
        claudeProfiles = snapshot.profiles.map(Self.presentation(for:))
        isCheckingClaude = snapshot.isChecking
    }

    static func presentation(for profile: ClaudeProfileSnapshot) -> ClaudeProfilePresentation {
        var windows: [ClaudeWindowPresentation] = []
        if let report = profile.report {
            windows = report.allWindows.map { window in
                ClaudeWindowPresentation(
                    id: window.scope.key,
                    label: Self.windowLabel(window.scope),
                    remainingPercent: window.remainingPercent,
                    resetsAt: window.resetsAt
                )
            }
        }
        let lowest = windows.map(\.remainingPercent).min()
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
            if let lowest, lowest <= ClaudeProfilePresentation.lowThresholdPercent {
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
            signInURL: profile.signInURL
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
func makeClaudeMonitor(model: GuardAppModel, configuration: ClaudeMonitorConfiguration) -> ClaudeMonitorController {
    let monitor = ClaudeMonitorController(
        configuration: configuration,
        updateHandler: { [weak model] snapshot in
            await MainActor.run { model?.apply(snapshot) }
        },
        notificationHandler: { title, body in
            guard !configuration.isReadOnly else { return }
            GuardNotifications.send(title: title, body: body)
        }
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
                GuardNotifications.requestAuthorization()
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
