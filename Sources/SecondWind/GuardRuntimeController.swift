import AppKit
import SecondWindCore
import Foundation

enum GuardOperationMode: String, Codable, Equatable, Sendable {
    case readOnly
    case production
}

struct GuardRuntimeConfiguration: Equatable, Sendable {
    var operationMode: GuardOperationMode
    var codexExecutableURL: URL
    var applicationSupportDirectory: URL
    var profilesDirectory: URL

    init(
        operationMode: GuardOperationMode = .readOnly,
        codexExecutableURL: URL = Self.defaultCodexExecutableURL,
        applicationSupportDirectory: URL = ProfileConfiguration.defaultApplicationSupportDirectory,
        profilesDirectory: URL = ProfileConfiguration.defaultProfilesDirectory
    ) {
        self.operationMode = operationMode
        self.codexExecutableURL = codexExecutableURL.standardizedFileURL
        self.applicationSupportDirectory = applicationSupportDirectory.standardizedFileURL
        self.profilesDirectory = profilesDirectory.standardizedFileURL
    }

    static var defaultCodexExecutableURL: URL {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/codex", isDirectory: false),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
        ]
        return candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) ?? candidates[0]
    }

    static func production(
        codexExecutableURL: URL = Self.defaultCodexExecutableURL
    ) -> GuardRuntimeConfiguration {
        GuardRuntimeConfiguration(
            operationMode: .production,
            codexExecutableURL: codexExecutableURL
        )
    }
}

enum GuardRuntimeConnectionStatus: String, Equatable, Sendable {
    case connecting
    case verified
    case authenticationRequired
    case identityMismatch
    case failed
}

struct GuardRuntimeProfileSnapshot: Equatable, Sendable {
    let id: UUID
    let displayName: String
    let accountHint: String
    let connectionStatus: GuardRuntimeConnectionStatus
    let weeklyRemainingPercent: Double?
    let naturalResetAt: Date?
    let availableResetCount: Int
    let nearestResetExpiry: Date?
    let phase: MonitorPhase
    let detail: String
    let autoResetEnabled: Bool
    /// Display, alert and preflight evidence. Never an input to redemption.
    let quota: QuotaAccountRecord
    var removalKeepsResetRecord = false
}

struct GuardRuntimeEvent: Equatable, Identifiable, Sendable {
    let id: UUID
    let occurredAt: Date
    let profileID: UUID?
    let summary: String
}

struct GuardRuntimeSnapshot: Equatable, Sendable {
    var profiles: [GuardRuntimeProfileSnapshot]
    var history: [GuardRuntimeEvent]
    var isChecking: Bool
    var lastCheckedAt: Date?
    var banner: String?
    /// The runtime clock when this snapshot was published; quota readings derive at this time.
    var generatedAt: Date? = nil
    var hasLoadedProfiles = true

    static let empty = GuardRuntimeSnapshot(
        profiles: [],
        history: [],
        isChecking: false,
        lastCheckedAt: nil,
        banner: nil,
        hasLoadedProfiles: false
    )
}

enum GuardRuntimeError: Error, Equatable, LocalizedError, Sendable {
    case profileNotFound
    case authenticationRequired
    case identityMismatch
    case missingExpectedIdentity
    case missingResetCreditInventory
    case rejectedWeeklyLimit(String)
    case runtimeNotInitialized
    case runtimeStopped
    case settingSuperseded

    var errorDescription: String? {
        switch self {
        case .profileNotFound:
            "The selected Codex profile no longer exists."
        case .authenticationRequired:
            "This profile needs a fresh Codex sign-in."
        case .identityMismatch:
            "The signed-in Codex account does not match this profile."
        case .missingExpectedIdentity:
            "This profile has no expected account identity."
        case .missingResetCreditInventory:
            "Codex did not return authoritative saved-reset inventory."
        case let .rejectedWeeklyLimit(reason):
            "The Codex weekly limit could not be classified safely (\(reason))."
        case .runtimeNotInitialized:
            "Second Wind has not finished starting."
        case .runtimeStopped:
            "Second Wind is stopping or has stopped."
        case .settingSuperseded:
            "A newer profile action replaced this setting change."
        }
    }
}

enum GuardPollingSchedule {
    static func interval(
        remainingPercent: Double?,
        phase: MonitorPhase,
        connectionStatus: GuardRuntimeConnectionStatus
    ) -> TimeInterval {
        guard connectionStatus == .verified else { return 60 }
        if [.confirming, .redeeming, .verifying].contains(phase) { return 5 }
        guard let remainingPercent else { return 60 }
        if remainingPercent <= 3 { return 5 }
        if remainingPercent <= 10 { return 15 }
        return 60
    }
}

enum GuardRedemptionSafetyGate {
    static let minimumNaturalResetHeadroom: TimeInterval = 5 * 60

    static func allowsConsume(
        weeklyLimit: CanonicalWeeklyLimit,
        inventory: ResetCreditInventory,
        state: MonitorState,
        attempt: RedemptionAttempt,
        policy: ResetPolicyEngine,
        now: Date,
        minimumNaturalResetHeadroom: TimeInterval = minimumNaturalResetHeadroom
    ) -> Bool {
        guard state.isEnabled,
              attempt.schemaVersion == RedemptionAttempt.currentSchemaVersion,
              attempt.profileID == state.profileID,
              weeklyLimit.remainingPercent <= policy.redemptionThresholdPercent,
              abs(weeklyLimit.durationMinutes - RateLimitClassifier.weeklyDurationMinutes)
                <= RateLimitClassifier.weeklyDurationMinutes * 0.05,
              weeklyLimit.resetsAt == attempt.weeklyResetAtBefore,
              weeklyLimit.resetsAt.timeIntervalSince(now) >= minimumNaturalResetHeadroom,
              now.timeIntervalSince(weeklyLimit.observedAt) <= policy.maximumReadingAge,
              now.timeIntervalSince(weeklyLimit.observedAt) >= -policy.maximumFutureSkew,
              inventory.availableCount > 0,
              let confirmation = state.confirmation,
              confirmation.weeklyResetAt == weeklyLimit.resetsAt,
              confirmation.count >= policy.requiredConfirmations,
              !attempt.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }

        guard weeklyLimit.observedAt >= confirmation.lastObservedAt else { return false }
        // An in-flight write may have committed without a send. Retrying never refreshes the
        // original confirmation evidence; stale ambiguous attempts must reconcile read-only.
        if !policy.hasFreshConfirmation(confirmation, for: weeklyLimit.resetsAt, at: now) {
            return false
        }

        if let credits = inventory.credits {
            guard let creditID = attempt.creditID else { return false }
            return credits.contains { credit in
                credit.id == creditID
                    && credit.kind == .codexRateLimits
                    && credit.status == .available
                    && (credit.expiresAt.map { $0 > now } ?? true)
            }
        }
        return attempt.creditID == nil
    }
}

protocol GuardAppServerSession: Sendable {
    func start() async throws
    func shutdown() async
    func notifications() async -> AsyncStream<AppServerNotification>
    func accountRead(refreshToken: Bool) async throws -> RPCAccountReadResponse
    func startChatGPTLogin(
        useHostedLoginSuccessPage: Bool,
        appBrand: String
    ) async throws -> RPCChatGPTLoginStartResponse
    func readRateLimits() async throws -> RPCRateLimitsReadResponse
    func consumeReset(idempotencyKey: String, creditID: String?) async throws
        -> RPCConsumeResetOutcome
}

private actor ProductionGuardAppServerSession: GuardAppServerSession {
    private let client: AppServerClient

    init(client: AppServerClient) {
        self.client = client
    }

    func start() async throws { try await client.start() }
    func shutdown() async { await client.shutdown() }
    func notifications() async -> AsyncStream<AppServerNotification> {
        await client.notifications()
    }
    func accountRead(refreshToken: Bool) async throws -> RPCAccountReadResponse {
        try await client.accountRead(refreshToken: refreshToken)
    }
    func startChatGPTLogin(
        useHostedLoginSuccessPage: Bool,
        appBrand: String
    ) async throws -> RPCChatGPTLoginStartResponse {
        try await client.startChatGPTLogin(
            useHostedLoginSuccessPage: useHostedLoginSuccessPage,
            appBrand: appBrand
        )
    }
    func readRateLimits() async throws -> RPCRateLimitsReadResponse {
        try await client.readRateLimits()
    }
    func consumeReset(idempotencyKey: String, creditID: String?) async throws
        -> RPCConsumeResetOutcome
    {
        try await client.consumeReset(idempotencyKey: idempotencyKey, creditID: creditID)
    }
}

/// A read that began before a reconnect; its result belongs to the previous sign-in.
private struct DiscardedRead: Error {}

typealias GuardAppServerSessionFactory = @Sendable (ProfileConfiguration) throws
    -> any GuardAppServerSession
typealias GuardRuntimeUpdateHandler = @MainActor @Sendable (GuardRuntimeSnapshot) -> Void
typealias GuardRuntimeNotificationHandler = @Sendable (AlertPost) -> Void

actor GuardRuntimeController {
    private enum Lifecycle: Sendable {
        case idle
        case starting
        case running
        case stopping
        case stopped
    }

    private struct LiveProfileState: Sendable {
        var connectionStatus: GuardRuntimeConnectionStatus = .connecting
        var weeklyLimit: CanonicalWeeklyLimit?
        var inventory: ResetCreditInventory?
        var detail = "Preparing an isolated Codex session…"
        var pendingLoginID: String?
    }

    private struct Reading: Sendable {
        let weeklyLimit: CanonicalWeeklyLimit
        let inventory: ResetCreditInventory
    }

    private let configuration: GuardRuntimeConfiguration
    private let persistence: MonitorPersistence
    private let eventLog: RedactedEventLog
    private let sessionFactory: GuardAppServerSessionFactory
    private let updateHandler: GuardRuntimeUpdateHandler
    private let notificationHandler: GuardRuntimeNotificationHandler
    private let classifier: RateLimitClassifier
    private let policy: ResetPolicyEngine
    private let now: @Sendable () -> Date
    private let startupGate: @Sendable () async -> Void

    private var persistentState: GuardPersistentState?
    private var sessions: [UUID: any GuardAppServerSession] = [:]
    private var liveProfiles: [UUID: LiveProfileState] = [:]
    /// Per-account quota evidence, stamped at the read boundary. Kept apart from the policy
    /// reading so a missing inventory or rejected weekly window never erases a good read.
    private var quotaRecords: [UUID: QuotaAccountRecord] = [:]
    /// Bumped when a reconnect starts. A read that began under an older generation is discarded,
    /// so it can never mark the account verified or current while the new sign-in is pending.
    private var readGenerations: [UUID: UInt64] = [:]
    /// Accounts waiting for their reconnect's login completion. Their reads are suppressed.
    private var awaitingLogin = Set<UUID>()
    private var pollingTasks: [UUID: Task<Void, Never>] = [:]
    private var notificationTasks: [UUID: Task<Void, Never>] = [:]
    private var checksInFlight = Set<UUID>()
    private var lastLoggedFailure: [UUID: String] = [:]
    private var checkFailureBanners: [UUID: String] = [:]
    private var lastCheckedAt: Date?
    private var banner: String?
    private var latestSnapshot: GuardRuntimeSnapshot = .empty
    private var initialized = false
    private var monitoring = false
    private var lifecycle: Lifecycle = .idle
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set synchronously before a disable write begins so no pending check can cross the network
    /// boundary while the durable setting is still being changed.
    private var redemptionKillSwitches = Set<UUID>()
    /// Reconnect and toggle intent is assigned before any await. An older enable must never
    /// overwrite a newer pause after its identity request resumes.
    private var profileControlIntents: [UUID: UUID] = [:]
    /// Accounts whose removal is under way. No check, sign-in, toggle or rename starts for them,
    /// and their redemption boundary stays closed.
    private var profilesBeingRemoved = Set<UUID>()
    private var removalDrainTimeout: Duration = .seconds(20)

    init(
        configuration: GuardRuntimeConfiguration,
        persistence: MonitorPersistence? = nil,
        eventLog: RedactedEventLog? = nil,
        sessionFactory: GuardAppServerSessionFactory? = nil,
        classifier: RateLimitClassifier = RateLimitClassifier(),
        policy: ResetPolicyEngine = ResetPolicyEngine(),
        now: @escaping @Sendable () -> Date = Date.init,
        startupGate: @escaping @Sendable () async -> Void = {},
        updateHandler: @escaping GuardRuntimeUpdateHandler = { _ in },
        notificationHandler: @escaping GuardRuntimeNotificationHandler = { _ in }
    ) {
        self.configuration = configuration
        self.persistence = persistence ?? MonitorPersistence(
            stateFileURL: configuration.applicationSupportDirectory
                .appendingPathComponent("state.json", isDirectory: false),
            profilesDirectory: configuration.profilesDirectory
        )
        let resolvedLog = eventLog ?? RedactedEventLog(
            fileURL: configuration.applicationSupportDirectory
                .appendingPathComponent("events.json", isDirectory: false)
        )
        self.eventLog = resolvedLog
        if let sessionFactory {
            self.sessionFactory = sessionFactory
        } else {
            let executableURL = configuration.codexExecutableURL
            let profilesDirectory = configuration.profilesDirectory
            let clientEventLog: RedactedEventLog? = configuration.operationMode == .production
                ? resolvedLog
                : nil
            self.sessionFactory = { profile in
                let client = try AppServerClient(
                    profile: profile,
                    codexExecutableURL: executableURL,
                    profilesDirectory: profilesDirectory,
                    eventLog: clientEventLog
                )
                return ProductionGuardAppServerSession(client: client)
            }
        }
        self.classifier = classifier
        self.policy = policy
        self.now = now
        self.startupGate = startupGate
        self.updateHandler = updateHandler
        self.notificationHandler = notificationHandler
    }

    /// Loads enrolled app-owned profiles and begins adaptive recurring monitoring.
    @discardableResult
    func start() async throws -> GuardRuntimeSnapshot {
        switch lifecycle {
        case .running:
            return latestSnapshot
        case .stopping, .stopped:
            throw GuardRuntimeError.runtimeStopped
        case .starting:
            throw GuardRuntimeError.runtimeNotInitialized
        case .idle:
            break
        }

        lifecycle = .starting
        do {
            try await initializeIfNeeded()
            guard lifecycle == .starting, !Task.isCancelled else {
                throw GuardRuntimeError.runtimeStopped
            }
            monitoring = true
            lifecycle = .running
            await startNotificationListeners()
            guard lifecycle == .running, !Task.isCancelled else {
                throw GuardRuntimeError.runtimeStopped
            }
            startPollingLoops()
            await publish()
            guard lifecycle == .running, !Task.isCancelled else {
                throw GuardRuntimeError.runtimeStopped
            }
            return latestSnapshot
        } catch {
            if lifecycle == .starting {
                lifecycle = .idle
            }
            throw error
        }
    }

    /// Performs a one-shot identity and rate-limit diagnosis. This method has a hard no-consume
    /// override even when the controller was constructed in production mode.
    @discardableResult
    func diagnose() async throws -> GuardRuntimeSnapshot {
        let wasInitialized = initialized
        try await initializeIfNeeded(allowBootstrap: false)
        await checkEveryProfile(allowConsume: false, recordSideEffects: false)
        let result = latestSnapshot
        if !wasInitialized && !monitoring {
            await closeSessions(keepSnapshot: true)
        }
        return result
    }

    /// Immediately checks enrolled profiles. Production policy actions remain impossible unless the
    /// controller was explicitly initialized with `.production`.
    @discardableResult
    func checkNow() async -> GuardRuntimeSnapshot {
        guard initialized else {
            banner = "Second Wind is still starting."
            await publish()
            return latestSnapshot
        }
        let allowConsume = configuration.operationMode == .production
        await checkEveryProfile(allowConsume: allowConsume)
        return latestSnapshot
    }

    @discardableResult
    func addProfile(expectedEmail: String, displayName: String) async throws -> GuardRuntimeSnapshot {
        guard initialized else { throw GuardRuntimeError.runtimeNotInitialized }
        guard lifecycle == .running else { throw GuardRuntimeError.runtimeStopped }
        do {
            adoptPersistentState(try await persistence.addProfile(
                expectedEmail: expectedEmail,
                displayName: displayName,
                now: now()
            ))
        } catch {
            // A rename may have committed even if its durability check failed. Reflect the saved
            // disabled profile so retrying cannot create a second monitor for the same account.
            if let latest = try? await persistence.snapshot() {
                adoptPersistentState(latest)
            }
            installEnrolledProfilePresentations()
            await publish()
            throw error
        }
        installEnrolledProfilePresentations()
        banner = "Profile added. Connect it to verify the account, then choose whether to enable Auto-redeem."
        await publish()
        return latestSnapshot
    }

    private func installEnrolledProfilePresentations() {
        for profile in persistentState?.profiles ?? [] where liveProfiles[profile.id] == nil {
            redemptionKillSwitches.insert(profile.id)
            liveProfiles[profile.id] = LiveProfileState(
                connectionStatus: .authenticationRequired,
                detail: "Sign in to start monitoring."
            )
        }
    }

    /// Starts a fresh browser OAuth flow in this profile's isolated `CODEX_HOME` and returns the
    /// official HTTPS authorization URL. No existing Codex or CodexBar credential is read or copied.
    func beginConnection(profileID: UUID) async throws -> URL {
        guard initialized else { throw GuardRuntimeError.runtimeNotInitialized }
        guard lifecycle != .stopping, lifecycle != .stopped else {
            throw GuardRuntimeError.runtimeStopped
        }
        guard let profile = persistentState?.profiles.first(where: { $0.id == profileID }) else {
            throw GuardRuntimeError.profileNotFound
        }
        guard !profilesBeingRemoved.contains(profileID) else {
            throw AccountLifecycleError.busy
        }

        // OAuth can replace credentials inside the isolated home. Install the in-memory stop
        // synchronously, then durably pause before any login/session await. Login completion stays
        // paused until the user explicitly re-enables after the expected identity is verified.
        redemptionKillSwitches.insert(profileID)
        let controlIntent = UUID()
        profileControlIntents[profileID] = controlIntent
        readGenerations[profileID, default: 0] &+= 1
        let generation = readGenerations[profileID, default: 0]
        awaitingLogin.insert(profileID)
        var loginStarted = false
        defer {
            // Without a started login nothing will complete it; let ordinary reads resume unless a
            // newer reconnect owns the marker.
            if !loginStarted, readGenerations[profileID, default: 0] == generation {
                awaitingLogin.remove(profileID)
            }
        }
        do {
            adoptPersistentState(try await persistence.setProfileEnabled(
                profileID,
                enabled: false,
                now: now()
            ))
        } catch {
            // The pause write had an ambiguous durability result. Never reopen the boundary from
            // a recovery snapshot: only a later explicit, successful enable may clear this stop.
            redemptionKillSwitches.insert(profileID)
            if let latest = try? await persistence.snapshot() {
                adoptPersistentState(latest)
            }
            throw error
        }

        var live = liveProfiles[profileID] ?? LiveProfileState()
        live.connectionStatus = .connecting
        live.weeklyLimit = nil
        live.inventory = nil
        live.detail = "Waiting for browser sign-in…"
        liveProfiles[profileID] = live
        recordQuotaFailure(.signInRequired, profileID: profileID)
        await publish()

        guard lifecycle == .running, !Task.isCancelled else {
            throw GuardRuntimeError.runtimeStopped
        }
        guard profileControlIntents[profileID] == controlIntent else {
            throw GuardRuntimeError.settingSuperseded
        }
        let session: any GuardAppServerSession
        if let existing = sessions[profileID] {
            session = existing
        } else {
            session = try sessionFactory(profile)
            sessions[profileID] = session
        }
        try await session.start()
        guard lifecycle == .running, !Task.isCancelled else {
            await session.shutdown()
            throw GuardRuntimeError.runtimeStopped
        }
        guard profileControlIntents[profileID] == controlIntent else {
            throw GuardRuntimeError.settingSuperseded
        }
        await startNotificationListener(profileID: profileID, session: session)
        guard lifecycle == .running, !Task.isCancelled else {
            throw GuardRuntimeError.runtimeStopped
        }
        guard profileControlIntents[profileID] == controlIntent else {
            throw GuardRuntimeError.settingSuperseded
        }
        let login = try await session.startChatGPTLogin(
            useHostedLoginSuccessPage: true,
            appBrand: "codex"
        )
        loginStarted = true
        guard lifecycle == .running, !Task.isCancelled else {
            await session.shutdown()
            throw GuardRuntimeError.runtimeStopped
        }
        guard profileControlIntents[profileID] == controlIntent else {
            throw GuardRuntimeError.settingSuperseded
        }
        if monitoring { startPollingLoops() }
        var currentLive = liveProfiles[profileID] ?? live
        if currentLive.connectionStatus != .verified {
            currentLive.pendingLoginID = login.loginID
            liveProfiles[profileID] = currentLive
        }
        _ = try? await eventLog.append(
            profileID: profileID,
            kind: .authenticationRequired,
            message: "A fresh isolated Codex sign-in was started."
        )
        await publish()
        return login.authURL
    }

    @discardableResult
    func setEnabled(profileID: UUID, enabled: Bool) async throws -> GuardRuntimeSnapshot {
        guard initialized else { throw GuardRuntimeError.runtimeNotInitialized }
        guard lifecycle != .stopping, lifecycle != .stopped else {
            throw GuardRuntimeError.runtimeStopped
        }
        guard !profilesBeingRemoved.contains(profileID) else {
            throw AccountLifecycleError.busy
        }

        redemptionKillSwitches.insert(profileID)
        let controlIntent = UUID()
        profileControlIntents[profileID] = controlIntent
        var expectedRevision: UInt64?
        if enabled {
            // Opt-in is available only after this isolated session matches the enrolled identity.
            // Recheck before committing in case the account changed while the popover was open.
            guard !awaitingLogin.contains(profileID),
                  let profile = persistentState?.profiles.first(where: { $0.id == profileID }),
                  let session = sessions[profileID] else {
                throw GuardRuntimeError.authenticationRequired
            }
            do {
                try await verifyIdentity(profile: profile, session: session, refreshToken: true)
            } catch {
                // The old verified state must not outlive a failed identity check.
                await publishIdentityFailure(error, profileID: profileID)
                throw error
            }
            let latest = try await persistence.snapshot()
            guard lifecycle != .stopping, lifecycle != .stopped, !Task.isCancelled else {
                throw GuardRuntimeError.runtimeStopped
            }
            guard profileControlIntents[profileID] == controlIntent else {
                throw GuardRuntimeError.settingSuperseded
            }
            // A later pause that reaches disk between this snapshot and the enable transaction
            // invalidates the enable. Ordinary policy writes may also defer opt-in safely.
            expectedRevision = latest.revision ?? 0
        }

        do {
            adoptPersistentState(try await persistence.setProfileEnabled(
                profileID,
                enabled: enabled,
                now: now(),
                expectedRevision: expectedRevision
            ))
        } catch {
            // A settings write that throws is not proven durable. Close the boundary regardless
            // of whether a recovery read sees the old or newly renamed file. A subsequent
            // explicit successful enable is the only path that removes this kill switch.
            redemptionKillSwitches.insert(profileID)
            if let latest = try? await persistence.snapshot() {
                adoptPersistentState(latest)
            }
            await publish()
            throw error
        }
        if enabled {
            guard profileControlIntents[profileID] == controlIntent,
                  lifecycle == .running, !Task.isCancelled else {
                throw GuardRuntimeError.settingSuperseded
            }
            redemptionKillSwitches.remove(profileID)
        }
        banner = enabled ? "Automatic weekly reset enabled." : "Automatic weekly reset paused."
        await publish()
        if enabled {
            await checkProfile(profileID, allowConsume: configuration.operationMode == .production)
        }
        return latestSnapshot
    }

    /// Renames one Codex account. Only its display name changes.
    @discardableResult
    func renameProfile(profileID: UUID, displayName: String) async throws -> GuardRuntimeSnapshot {
        guard configuration.operationMode == .production else {
            throw AccountLifecycleError.readOnly
        }
        guard initialized, lifecycle == .running else { throw AccountLifecycleError.unavailable }
        guard !profilesBeingRemoved.contains(profileID) else { throw AccountLifecycleError.busy }
        do {
            adoptPersistentState(try await persistence.renameProfile(
                profileID,
                displayName: displayName,
                now: now()
            ))
        } catch {
            // The write may have committed before its durability check failed; show what is saved.
            if let latest = try? await persistence.snapshot() {
                adoptPersistentState(latest)
            }
            await publish()
            throw AccountLifecycleError(codexFailure: error)
        }
        await publish()
        return latestSnapshot
    }

    /// Removes one Codex account, its monitor state and its app-owned Codex home.
    ///
    /// The redemption boundary closes before any await. A check that is already running, possibly
    /// mid reset request, is allowed to finish and durably record its outcome first; cancelling
    /// it could turn a clean answer into an ambiguous one. The removal is then committed in one
    /// write that keeps any uncertain redemption for this email (see
    /// `MonitorPersistence.removeProfile`). Only after that commit are the session, tasks and
    /// private folder discarded, so a failed write leaves the account fully intact.
    func removeProfile(profileID: UUID) async throws -> AccountRemovalOutcome {
        guard configuration.operationMode == .production else {
            throw AccountLifecycleError.readOnly
        }
        guard initialized, lifecycle == .running else { throw AccountLifecycleError.unavailable }
        guard persistentState?.profiles.contains(where: { $0.id == profileID }) == true else {
            throw AccountLifecycleError.accountNotFound
        }
        guard profilesBeingRemoved.insert(profileID).inserted else {
            throw AccountLifecycleError.busy
        }
        defer { profilesBeingRemoved.remove(profileID) }

        let hadKillSwitch = redemptionKillSwitches.contains(profileID)
        let removalIntent = UUID()
        redemptionKillSwitches.insert(profileID)
        profileControlIntents[profileID] = removalIntent

        guard await waitForCheckToDrain(profileID) else {
            // Nothing durable changed. Reopen the boundary only if no other action touched it.
            if !hadKillSwitch, profileControlIntents[profileID] == removalIntent {
                redemptionKillSwitches.remove(profileID)
            }
            await publish()
            throw AccountLifecycleError.busy
        }
        guard lifecycle == .running else { throw AccountLifecycleError.unavailable }

        let key = GuardPersistentState.key(for: profileID)
        let keptResetRecord: Bool
        do {
            let removal = try await persistence.removeProfile(profileID, now: now())
            adoptPersistentState(removal.state)
            keptResetRecord = removal.keptResetRecord
        } catch {
            if let latest = try? await persistence.snapshot() {
                adoptPersistentState(latest)
            }
            guard let current = persistentState,
                  !current.profiles.contains(where: { $0.id == profileID }) else {
                await publish()
                throw AccountLifecycleError(codexFailure: error)
            }
            // The removal reached disk even though its durability check failed. Finish cleanup.
            keptResetRecord = current.retainedRedemptions?
                .contains { $0.formerProfileID == key } ?? false
        }

        pollingTasks.removeValue(forKey: profileID)?.cancel()
        notificationTasks.removeValue(forKey: profileID)?.cancel()
        let session = sessions.removeValue(forKey: profileID)
        liveProfiles.removeValue(forKey: profileID)
        quotaRecords.removeValue(forKey: profileID)
        lastLoggedFailure.removeValue(forKey: profileID)
        checkFailureBanners.removeValue(forKey: profileID)
        profileControlIntents.removeValue(forKey: profileID)
        // The kill switch stays: the UUID never returns, and a stale task must stay harmless.
        await session?.shutdown()

        var outcome = AccountRemovalOutcome(keptResetRecord: keptResetRecord)
        do {
            let remaining = try await persistence.discardPendingProfileHomes(now: now())
            outcome.folderCleanupPending = remaining.contains(profileID)
        } catch {
            outcome.folderCleanupPending = true
        }
        if let latest = try? await persistence.snapshot() {
            adoptPersistentState(latest)
            if latest.pendingHomeDiscards?.contains(key) == true {
                outcome.folderCleanupPending = true
            }
        }
        await publish()
        return outcome
    }

    func overrideRemovalDrainTimeoutForTesting(_ timeout: Duration) {
        removalDrainTimeout = timeout
    }

    private func waitForCheckToDrain(_ profileID: UUID) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: removalDrainTimeout)
        while checksInFlight.contains(profileID) {
            guard clock.now < deadline, lifecycle == .running else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    func stop() async {
        if lifecycle == .stopped { return }
        if lifecycle == .stopping {
            await withCheckedContinuation { stopWaiters.append($0) }
            return
        }
        lifecycle = .stopping
        monitoring = false
        if let profiles = persistentState?.profiles {
            redemptionKillSwitches.formUnion(profiles.map(\.id))
        }
        let activePollingTasks = Array(pollingTasks.values)
        let activeNotificationTasks = Array(notificationTasks.values)
        for task in activePollingTasks { task.cancel() }
        for task in activeNotificationTasks { task.cancel() }
        pollingTasks.removeAll()
        notificationTasks.removeAll()
        let activeSessions = Array(sessions.values)
        sessions.removeAll()
        initialized = false
        for session in activeSessions { await session.shutdown() }
        for task in activePollingTasks { await task.value }
        for task in activeNotificationTasks { await task.value }
        checksInFlight.removeAll()
        lifecycle = .stopped
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func snapshot() -> GuardRuntimeSnapshot {
        latestSnapshot
    }

    private func initializeIfNeeded(allowBootstrap: Bool = true) async throws {
        guard !initialized else { return }
        guard lifecycle != .stopping, lifecycle != .stopped else {
            throw GuardRuntimeError.runtimeStopped
        }
        let state = if allowBootstrap {
            try await persistence.loadOrBootstrap(now: now())
        } else {
            try await persistence.snapshot()
        }
        await startupGate()
        guard lifecycle != .stopping, lifecycle != .stopped, !Task.isCancelled else {
            throw GuardRuntimeError.runtimeStopped
        }
        var newSessions: [UUID: any GuardAppServerSession] = [:]
        var newLiveProfiles: [UUID: LiveProfileState] = [:]
        do {
            for profile in state.profiles {
                newSessions[profile.id] = try sessionFactory(profile)
                newLiveProfiles[profile.id] = LiveProfileState()
            }
        } catch {
            for session in newSessions.values { await session.shutdown() }
            throw error
        }
        persistentState = state
        sessions = newSessions
        liveProfiles = newLiveProfiles
        redemptionKillSwitches = Set(state.profiles.filter { !$0.isEnabled }.map(\.id))
        initialized = true
        banner = configuration.operationMode == .production
            ? nil
            : "Read-only mode: resets cannot be redeemed."
        await publish()
        guard lifecycle != .stopping, lifecycle != .stopped, !Task.isCancelled else {
            throw GuardRuntimeError.runtimeStopped
        }
    }

    private func startPollingLoops() {
        guard let profiles = persistentState?.profiles else { return }
        for profile in profiles where pollingTasks[profile.id] == nil && sessions[profile.id] != nil {
            let profileID = profile.id
            pollingTasks[profileID] = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    await self.checkProfile(
                        profileID,
                        allowConsume: await self.operationModeIsProduction()
                    )
                    let seconds = await self.nextPollingInterval(for: profileID)
                    do {
                        try await Task.sleep(for: .milliseconds(Int64(seconds * 1_000)))
                    } catch {
                        return
                    }
                }
            }
        }
    }

    private func operationModeIsProduction() -> Bool {
        configuration.operationMode == .production
    }

    private func startNotificationListeners() async {
        for (profileID, session) in sessions where notificationTasks[profileID] == nil {
            await startNotificationListener(profileID: profileID, session: session)
        }
    }

    private func startNotificationListener(
        profileID: UUID,
        session: any GuardAppServerSession
    ) async {
        guard notificationTasks[profileID] == nil else { return }
        // The provider may complete sign-in as soon as login starts. Register the stream first.
        let notifications = await session.notifications()
        guard lifecycle == .running, sessions[profileID] != nil,
              !profilesBeingRemoved.contains(profileID), notificationTasks[profileID] == nil else { return }
        notificationTasks[profileID] = Task { [weak self] in
            for await notification in notifications {
                guard !Task.isCancelled else { return }
                await self?.handle(notification, profileID: profileID)
            }
        }
    }

    private func handle(_ notification: AppServerNotification, profileID: UUID) async {
        switch notification {
        case let .loginCompleted(completion):
            guard var live = liveProfiles[profileID] else { return }
            if let expectedLoginID = live.pendingLoginID,
               let completedLoginID = completion.loginID,
               expectedLoginID != completedLoginID {
                return
            }
            live.pendingLoginID = nil
            liveProfiles[profileID] = live
            awaitingLogin.remove(profileID)
            guard completion.success else {
                setConnectionFailure(
                    profileID: profileID,
                    status: .authenticationRequired,
                    detail: "Codex sign-in did not complete. Try Connect again."
                )
                await publish()
                return
            }
            await checkProfile(
                profileID,
                allowConsume: false,
                refreshIdentity: true
            )
        case .accountUpdated:
            await checkProfile(
                profileID,
                allowConsume: configuration.operationMode == .production,
                refreshIdentity: true
            )
        case .rateLimitsUpdated:
            await checkProfile(
                profileID,
                allowConsume: configuration.operationMode == .production
            )
        case .unhandled:
            break
        }
    }

    private func checkEveryProfile(
        allowConsume: Bool,
        recordSideEffects: Bool = true
    ) async {
        guard let profileIDs = persistentState?.profiles.map(\.id) else { return }
        await withTaskGroup(of: Void.self) { group in
            for profileID in profileIDs {
                group.addTask { [weak self] in
                    await self?.checkProfile(
                        profileID,
                        allowConsume: allowConsume,
                        recordSideEffects: recordSideEffects
                    )
                }
            }
        }
    }

    private func checkProfile(
        _ profileID: UUID,
        allowConsume: Bool,
        refreshIdentity: Bool = false,
        recordSideEffects: Bool = true
    ) async {
        guard initialized, !checksInFlight.contains(profileID),
              !profilesBeingRemoved.contains(profileID),
              !awaitingLogin.contains(profileID),
              let profile = persistentState?.profiles.first(where: { $0.id == profileID }),
              let session = sessions[profileID] else {
            return
        }
        checksInFlight.insert(profileID)
        let generation = readGenerations[profileID, default: 0]
        await publish()

        do {
            let reading = try await readVerified(
                profile: profile,
                session: session,
                refreshIdentity: refreshIdentity,
                generation: generation
            )
            guard readGenerations[profileID, default: 0] == generation else {
                throw DiscardedRead()
            }
            var live = liveProfiles[profileID] ?? LiveProfileState()
            live.connectionStatus = .verified
            live.weeklyLimit = reading.weeklyLimit
            live.inventory = reading.inventory
            live.detail = "Weekly usage and saved resets are current."
            liveProfiles[profileID] = live
            lastLoggedFailure[profileID] = nil
            checkFailureBanners[profileID] = nil

            guard let monitorState = persistentState?.monitorState(for: profileID) else {
                throw MonitorPersistenceError.missingMonitorState(profileID)
            }

            if allowConsume && configuration.operationMode == .production,
               lifecycle == .running, monitoring, !Task.isCancelled {
                try await applyPolicy(
                    profile: profile,
                    session: session,
                    reading: reading,
                    monitorState: monitorState,
                    generation: generation
                )
            }
            lastCheckedAt = now()
        } catch {
            if !(error is DiscardedRead),
               readGenerations[profileID, default: 0] == generation,
               lifecycle != .stopping, lifecycle != .stopped, !Task.isCancelled {
                if recordSideEffects {
                    await recordCheckFailure(error, profileID: profileID)
                } else {
                    recordDiagnosticFailure(error, profileID: profileID)
                }
            }
        }

        checksInFlight.remove(profileID)
        await publish()
    }

    /// `generation` is the originating check's reconnect generation, captured before its first
    /// await. Quota evidence is stamped only while it is still current.
    private func readVerified(
        profile: ProfileConfiguration,
        session: any GuardAppServerSession,
        refreshIdentity: Bool,
        generation: UInt64
    ) async throws -> Reading {
        let response: RPCRateLimitsReadResponse
        do {
            try await verifyIdentity(
                profile: profile,
                session: session,
                refreshToken: refreshIdentity
            )
            response = try await session.readRateLimits()
        } catch {
            if readGenerations[profile.id, default: 0] == generation {
                recordQuotaFailure(Self.quotaFailureReason(error), profileID: profile.id)
            }
            throw error
        }
        let observedAt = now()
        let evidenceIsCurrent = readGenerations[profile.id, default: 0] == generation
        guard let canonicalSnapshot = response.canonicalCodexRateLimits else {
            if evidenceIsCurrent { recordQuotaFailure(.unreadable, profileID: profile.id) }
            throw GuardRuntimeError.rejectedWeeklyLimit("canonical Codex bucket missing")
        }
        let snapshot = canonicalSnapshot.domainValue(observedAt: observedAt)
        // Display evidence only. The policy below still trusts nothing but `classify`.
        if evidenceIsCurrent {
            if let observation = response.quotaObservation(observedAt: observedAt, classifier: classifier) {
                var record = quotaRecords[profile.id]
                    ?? QuotaAccountRecord(provider: .codex, accountID: profile.id)
                record.recordSuccess(observation)
                quotaRecords[profile.id] = record
            } else {
                recordQuotaFailure(.unreadable, profileID: profile.id)
            }
        }
        let weeklyLimit: CanonicalWeeklyLimit
        switch classifier.classify(snapshot, now: observedAt) {
        case let .canonical(value):
            weeklyLimit = value
        case let .rejected(failure):
            throw GuardRuntimeError.rejectedWeeklyLimit(Self.safeClassificationReason(failure))
        }
        guard let inventory = response.rateLimitResetCredits?.domainValue() else {
            throw GuardRuntimeError.missingResetCreditInventory
        }
        return Reading(weeklyLimit: weeklyLimit, inventory: inventory)
    }

    private func verifyIdentity(
        profile: ProfileConfiguration,
        session: any GuardAppServerSession,
        refreshToken: Bool
    ) async throws {
        guard let expectedEmail = profile.expectedEmail,
              !MonitorPersistence.normalizedEmail(expectedEmail).isEmpty else {
            throw GuardRuntimeError.missingExpectedIdentity
        }
        let response = try await session.accountRead(refreshToken: refreshToken)
        guard let account = response.account,
              account.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == "chatgpt",
              let actualEmail = account.email else {
            throw GuardRuntimeError.authenticationRequired
        }
        guard MonitorPersistence.normalizedEmail(actualEmail)
            == MonitorPersistence.normalizedEmail(expectedEmail) else {
            throw GuardRuntimeError.identityMismatch
        }
    }

    private func applyPolicy(
        profile: ProfileConfiguration,
        session: any GuardAppServerSession,
        reading: Reading,
        monitorState: MonitorState,
        generation: UInt64
    ) async throws {
        let evaluationTime = now()
        let evaluation = policy.evaluate(
            weeklyLimit: reading.weeklyLimit,
            inventory: reading.inventory,
            state: monitorState,
            now: evaluationTime,
            newIdempotencyKey: "weekly-reset-\(UUID().uuidString.lowercased())"
        )

        let savedEvaluation = try await persistence.saveMonitorState(
            evaluation.state,
            now: evaluationTime
        )
        adoptPersistentState(savedEvaluation)
        guard let persistedMonitorState = savedEvaluation.monitorState(for: profile.id) else {
            throw MonitorPersistenceError.missingMonitorState(profile.id)
        }
        updateLiveDetail(profileID: profile.id, state: persistedMonitorState)
        try await logPolicyTransition(
            profileID: profile.id,
            prior: monitorState,
            evaluation: evaluation,
            reading: reading
        )

        switch evaluation.action {
        case .none:
            return
        case let .readForVerification(attempt):
            try await reconcileVerification(
                profileID: profile.id,
                state: persistedMonitorState,
                attempt: attempt,
                reading: reading
            )
        case let .persistThenConsume(attempt), let .retryConsume(attempt):
            if attempt.phase == .retryable || attempt.phase == .requestInFlight,
               hasPossibleRecovery(reading: reading, attempt: attempt) {
                try await reconcileAmbiguousAttempt(
                    profileID: profile.id,
                    state: persistedMonitorState,
                    reading: reading
                )
                return
            }
            try await consume(
                profile: profile,
                session: session,
                state: persistedMonitorState,
                attempt: attempt,
                generation: generation
            )
        }
    }

    private func consume(
        profile: ProfileConfiguration,
        session: any GuardAppServerSession,
        state: MonitorState,
        attempt: RedemptionAttempt,
        generation: UInt64
    ) async throws {
        guard isRedemptionBoundaryOpen(for: profile.id) else { return }

        // Surface the redeeming state before the final safety read. On the successful path,
        // nothing after the durable requestStarted transaction may await except consume itself.
        updateLiveDetail(profileID: profile.id, state: state)
        await publish()

        guard isRedemptionBoundaryOpen(for: profile.id) else { return }
        // This is intentionally a complete second boundary read: identity, authoritative `codex`
        // bucket, exact weekly classification, and saved-reset inventory are all refreshed.
        let finalReading = try await readVerified(
            profile: profile,
            session: session,
            refreshIdentity: false,
            generation: generation
        )
        guard isRedemptionBoundaryOpen(for: profile.id) else { return }

        if attempt.phase != .prepared,
           hasPossibleRecovery(reading: finalReading, attempt: attempt) {
            try await reconcileAmbiguousAttempt(
                profileID: profile.id,
                state: state,
                reading: finalReading
            )
            return
        }

        let latestState = try await persistence.snapshot()
        adoptPersistentState(latestState)
        guard isRedemptionBoundaryOpen(for: profile.id),
              let latestProfile = latestState.profiles.first(where: { $0.id == profile.id }),
              latestProfile.isEnabled,
              let latestMonitorState = latestState.monitorState(for: profile.id),
              latestMonitorState.isEnabled,
              let latestAttempt = latestMonitorState.attempt,
              latestAttempt.idempotencyKey == attempt.idempotencyKey else {
            return
        }

        let boundaryTime = now()
        guard GuardRedemptionSafetyGate.allowsConsume(
            weeklyLimit: finalReading.weeklyLimit,
            inventory: finalReading.inventory,
            state: latestMonitorState,
            attempt: latestAttempt,
            policy: policy,
            now: boundaryTime
        ) else {
            if latestAttempt.phase == .prepared {
                try await disarmPreparedAttempt(
                    profileID: profile.id,
                    state: latestMonitorState,
                    reading: finalReading
                )
            } else {
                try await reconcileAmbiguousAttempt(
                    profileID: profile.id,
                    state: latestMonitorState,
                    reading: finalReading
                )
            }
            return
        }

        let requestStarted = try policy.markRequestStarted(
            in: latestMonitorState,
            at: boundaryTime
        )
        let durableRequestStarted: GuardPersistentState
        do {
            // Compare-and-swap closes the race with a profile toggle. This durable save is the
            // final awaited side effect on the path that sends the network request.
            durableRequestStarted = try await persistence.saveMonitorState(
                requestStarted,
                now: boundaryTime,
                expectedRevision: latestState.revision ?? 0
            )
        } catch MonitorPersistenceError.concurrentModification {
            if let refreshed = try? await persistence.snapshot() {
                adoptPersistentState(refreshed)
            }
            return
        }
        adoptPersistentState(durableRequestStarted)
        guard isRedemptionBoundaryOpen(for: profile.id), !Task.isCancelled else {
            // The durable in-flight state is conservative: on restart it can only reuse this key.
            return
        }

        guard GuardRedemptionSafetyGate.allowsConsume(
            weeklyLimit: finalReading.weeklyLimit,
            inventory: finalReading.inventory,
            state: latestMonitorState,
            attempt: latestAttempt,
            policy: policy,
            now: now()
        ) else {
            redemptionKillSwitches.insert(profile.id)
            try await failClosedBeforeConsume(
                profileID: profile.id,
                state: requestStarted,
                message: "Automatic redemption stopped because its safety checks expired before sending."
            )
            return
        }

        let outcome: RPCConsumeResetOutcome
        do {
            outcome = try await session.consumeReset(
                idempotencyKey: latestAttempt.idempotencyKey,
                creditID: latestAttempt.creditID
            )
        } catch {
            if Self.isDefiniteConsumeRejection(error) {
                let rejected = try policy.recordDefiniteRejection(
                    in: requestStarted,
                    at: now()
                )
                adoptPersistentState(try await persistence.saveMonitorState(rejected, now: now()))
                updateLiveDetail(profileID: profile.id, state: rejected)
                _ = try? await eventLog.append(
                    profileID: profile.id,
                    kind: .redemptionFailed,
                    message: "Codex rejected the reset request; it will not be retried automatically."
                )
            } else {
                let retryable = try policy.recordAmbiguousFailure(in: requestStarted, at: now())
                adoptPersistentState(try await persistence.saveMonitorState(retryable, now: now()))
                updateLiveDetail(profileID: profile.id, state: retryable)
                _ = try? await eventLog.append(
                    profileID: profile.id,
                    kind: .redemptionDeferred,
                    message: "The reset response was uncertain; any retry will reuse its saved key."
                )
            }
            return
        }

        _ = try? await eventLog.append(
            profileID: profile.id,
            kind: .redemptionStarted,
            message: "A confirmed canonical weekly reset request reached Codex."
        )

        let recorded = try policy.recordConsumeOutcome(
            outcome.domainValue,
            in: requestStarted,
            at: now()
        )
        adoptPersistentState(try await persistence.saveMonitorState(recorded, now: now()))
        updateLiveDetail(profileID: profile.id, state: recorded)

        guard recorded.attempt?.phase == .awaitingVerification else {
            let kind: RedactedEventRecord.Kind = outcome == .noCredit
                ? .redemptionDeferred
                : .redemptionDeferred
            _ = try? await eventLog.append(
                profileID: profile.id,
                kind: kind,
                message: outcome == .noCredit
                    ? "No saved reset was available."
                    : "Codex reported that there was nothing eligible to reset yet."
            )
            return
        }

        try? await Task.sleep(for: .milliseconds(500))
        do {
            let verificationReading = try await readVerified(
                profile: profile,
                session: session,
                refreshIdentity: false,
                generation: generation
            )
            try await reconcileVerification(
                profileID: profile.id,
                state: recorded,
                attempt: latestAttempt,
                reading: verificationReading
            )
        } catch {
            // The awaiting-verification phase stays durable; a later poll performs another safe read.
            updateLiveDetail(profileID: profile.id, state: recorded)
        }
    }

    private func disarmPreparedAttempt(
        profileID: UUID,
        state: MonitorState,
        reading: Reading
    ) async throws {
        var disarmed = state
        guard disarmed.attempt?.phase == .prepared else { return }
        disarmed.attempt = nil
        disarmed.confirmation = nil
        let evaluation = policy.evaluate(
            weeklyLimit: reading.weeklyLimit,
            inventory: reading.inventory,
            state: disarmed,
            now: now(),
            newIdempotencyKey: nil
        )
        let saved = try await persistence.saveMonitorState(evaluation.state, now: now())
        adoptPersistentState(saved)
        if let current = saved.monitorState(for: profileID) {
            updateLiveDetail(profileID: profileID, state: current)
        }
        _ = try? await eventLog.append(
            profileID: profileID,
            kind: .redemptionDeferred,
            message: "A prepared reset was safely disarmed after the final weekly-only check changed."
        )
    }

    private func isRedemptionBoundaryOpen(for profileID: UUID) -> Bool {
        lifecycle == .running
            && monitoring
            && !redemptionKillSwitches.contains(profileID)
            && !Task.isCancelled
    }

    private nonisolated static func isDefiniteConsumeRejection(_ error: any Error) -> Bool {
        guard let clientError = error as? AppServerClientError else { return false }
        return switch clientError {
        case .rpc, .invalidTimeout, .codexHomeMismatch, .invalidLoginResponse:
            true
        case .shutDown, .transportClosed, .transportFailure, .timedOut,
             .invalidMessage, .unexpectedResponse:
            false
        }
    }

    private func reconcileVerification(
        profileID: UUID,
        state: MonitorState,
        attempt: RedemptionAttempt,
        reading: Reading
    ) async throws {
        guard attempt.idempotencyKey == state.attempt?.idempotencyKey else {
            throw ResetPolicyTransitionError.invalidIdempotencyKey
        }
        let wasVerificationFailure = state.attempt?.phase == .verificationFailed
        let reconciled = try policy.reconcileVerification(
            weeklyLimit: reading.weeklyLimit,
            inventory: reading.inventory,
            in: state,
            now: now()
        )
        adoptPersistentState(try await persistence.saveMonitorState(reconciled, now: now()))
        var live = liveProfiles[profileID] ?? LiveProfileState()
        live.weeklyLimit = reading.weeklyLimit
        live.inventory = reading.inventory
        live.connectionStatus = .verified
        liveProfiles[profileID] = live
        updateLiveDetail(profileID: profileID, state: reconciled)

        let target = AccountRef(provider: .codex, id: profileID)
        let name = persistentState?.profiles.first { $0.id == profileID }?.displayName ?? "Codex account"
        if reconciled.phase == .verified {
            _ = try? await eventLog.append(
                profileID: profileID,
                kind: .redemptionSucceeded,
                message: "The weekly allowance recovered and the saved reset count decreased."
            )
            notificationHandler(.resetApplied(target, name: name))
        } else if reconciled.phase == .attentionRequired, !wasVerificationFailure {
            _ = try? await eventLog.append(
                profileID: profileID,
                kind: .verificationFailed,
                message: "The weekly reset outcome could not be verified safely."
            )
            notificationHandler(.resetNeedsAttention(target, name: name))
        }
    }

    private func reconcileAmbiguousAttempt(
        profileID: UUID,
        state: MonitorState,
        reading: Reading
    ) async throws {
        guard var attempt = state.attempt else {
            throw ResetPolicyTransitionError.missingAttempt
        }
        var verificationState = state
        attempt.phase = .awaitingVerification
        verificationState.attempt = attempt
        verificationState.phase = .verifying
        adoptPersistentState(try await persistence.saveMonitorState(verificationState, now: now()))
        try await reconcileVerification(
            profileID: profileID,
            state: verificationState,
            attempt: attempt,
            reading: reading
        )
    }

    private func failClosedBeforeConsume(
        profileID: UUID,
        state: MonitorState,
        message: String
    ) async throws {
        var failedState = state
        if var attempt = failedState.attempt {
            attempt.phase = .verificationFailed
            attempt.updatedAt = now()
            failedState.attempt = attempt
        }
        failedState.phase = .attentionRequired
        failedState.attentionMessage = message
        adoptPersistentState(try await persistence.saveMonitorState(failedState, now: now()))
        updateLiveDetail(profileID: profileID, state: failedState)
        _ = try? await eventLog.append(
            profileID: profileID,
            kind: .redemptionFailed,
            message: "A changed weekly-only safety condition blocked redemption."
        )
    }

    private func hasPossibleRecovery(reading: Reading, attempt: RedemptionAttempt) -> Bool {
        reading.weeklyLimit.resetsAt != attempt.weeklyResetAtBefore
            || reading.weeklyLimit.usedPercent < attempt.weeklyUsedPercentBefore
            || reading.inventory.availableCount < attempt.availableCreditCountBefore
    }

    private func recordCheckFailure(_ error: any Error, profileID: UUID) async {
        let status: GuardRuntimeConnectionStatus
        let detail: String
        switch error {
        case GuardRuntimeError.authenticationRequired:
            status = .authenticationRequired
            detail = "Sign in again to keep monitoring."
        case GuardRuntimeError.identityMismatch:
            status = .identityMismatch
            detail = "Wrong Codex account signed in. Reconnect with the expected profile."
        case GuardRuntimeError.missingResetCreditInventory:
            status = .failed
            detail = "Saved-reset inventory was missing, so redemption is blocked."
        case is GuardRuntimeError:
            status = .failed
            detail = "The weekly limit could not be classified safely. Redemption is blocked."
        default:
            status = .failed
            detail = "Codex could not be checked. The app will retry without redeeming."
        }
        setConnectionFailure(profileID: profileID, status: status, detail: detail)

        if var monitorState = persistentState?.monitorState(for: profileID),
           monitorState.attempt == nil {
            monitorState.confirmation = nil
            monitorState.phase = .attentionRequired
            monitorState.attentionMessage = detail
            if let saved = try? await persistence.saveMonitorState(monitorState, now: now()) {
                adoptPersistentState(saved)
            }
        }

        let fingerprint = "\(status.rawValue):\(detail)"
        if lastLoggedFailure[profileID] != fingerprint {
            lastLoggedFailure[profileID] = fingerprint
            let kind: RedactedEventRecord.Kind = status == .authenticationRequired
                ? .authenticationRequired
                : .checkFailed
            _ = try? await eventLog.append(
                profileID: profileID,
                kind: kind,
                message: detail
            )
        }
        checkFailureBanners[profileID] = detail
        lastCheckedAt = now()
    }

    private func recordDiagnosticFailure(_ error: any Error, profileID: UUID) {
        let status: GuardRuntimeConnectionStatus
        let detail: String
        switch error {
        case GuardRuntimeError.authenticationRequired:
            status = .authenticationRequired
            detail = "Sign in again to keep monitoring."
        case GuardRuntimeError.identityMismatch:
            status = .identityMismatch
            detail = "Wrong Codex account signed in. Reconnect with the expected profile."
        case GuardRuntimeError.missingResetCreditInventory:
            status = .failed
            detail = "Saved-reset inventory was missing, so redemption is blocked."
        case is GuardRuntimeError:
            status = .failed
            detail = "The weekly limit could not be classified safely. Redemption is blocked."
        default:
            status = .failed
            detail = "Codex could not be checked. No reset request was made."
        }
        setConnectionFailure(profileID: profileID, status: status, detail: detail)
        checkFailureBanners[profileID] = detail
        lastCheckedAt = now()
    }

    private func setConnectionFailure(
        profileID: UUID,
        status: GuardRuntimeConnectionStatus,
        detail: String
    ) {
        var live = liveProfiles[profileID] ?? LiveProfileState()
        live.connectionStatus = status
        if status == .authenticationRequired || status == .identityMismatch {
            live.weeklyLimit = nil
            live.inventory = nil
            recordQuotaFailure(
                status == .identityMismatch ? .wrongAccount : .signInRequired,
                profileID: profileID
            )
        }
        live.detail = detail
        liveProfiles[profileID] = live
    }

    /// Publishes a failed identity check so an earlier verified state cannot linger. The read
    /// generation advances first, so only a check that starts after this failure can clear it.
    private func publishIdentityFailure(_ error: any Error, profileID: UUID) async {
        guard lifecycle != .stopping, lifecycle != .stopped, !Task.isCancelled else { return }
        switch error {
        case GuardRuntimeError.authenticationRequired, GuardRuntimeError.missingExpectedIdentity,
             GuardRuntimeError.identityMismatch:
            readGenerations[profileID, default: 0] &+= 1
        default:
            return
        }
        switch error {
        case GuardRuntimeError.authenticationRequired, GuardRuntimeError.missingExpectedIdentity:
            setConnectionFailure(
                profileID: profileID,
                status: .authenticationRequired,
                detail: "Sign in again to keep monitoring."
            )
        case GuardRuntimeError.identityMismatch:
            setConnectionFailure(
                profileID: profileID,
                status: .identityMismatch,
                detail: "Wrong Codex account signed in. Reconnect with the expected profile."
            )
        default:
            return
        }
        await publish()
    }

    /// Keeps the last good reading, now marked historical. Shutdown errors are not failures.
    private func recordQuotaFailure(_ reason: QuotaFailureReason, profileID: UUID) {
        guard lifecycle != .stopping, lifecycle != .stopped, !Task.isCancelled else { return }
        var record = quotaRecords[profileID]
            ?? QuotaAccountRecord(provider: .codex, accountID: profileID)
        record.recordFailure(reason, at: now())
        quotaRecords[profileID] = record
    }

    private nonisolated static func quotaFailureReason(_ error: any Error) -> QuotaFailureReason {
        switch error {
        case GuardRuntimeError.authenticationRequired, GuardRuntimeError.missingExpectedIdentity:
            .signInRequired
        case GuardRuntimeError.identityMismatch:
            .wrongAccount
        case is GuardRuntimeError, AppServerClientError.invalidMessage,
             AppServerClientError.unexpectedResponse:
            .unreadable
        default:
            .unavailable
        }
    }

    private func updateLiveDetail(profileID: UUID, state: MonitorState) {
        var live = liveProfiles[profileID] ?? LiveProfileState()
        switch state.phase {
        case .disabled:
            live.detail = "Automatic weekly reset is paused."
        case .healthy:
            live.detail = "Weekly allowance is safely above the reset threshold."
        case .nearLimit:
            live.detail = "Weekly allowance is near the reset threshold."
        case .confirming:
            live.detail = "Confirming the weekly balance with a second fresh reading."
        case .redeeming:
            live.detail = "Redeeming one saved weekly reset with a durable request."
        case .verifying:
            live.detail = "Verifying weekly recovery and saved-reset inventory."
        case .verified:
            live.detail = "The saved weekly reset was verified."
        case .noCredits:
            live.detail = "No eligible saved weekly resets are available."
        case .attentionRequired:
            live.detail = state.attentionMessage ?? "Automatic redemption stopped safely."
        }
        liveProfiles[profileID] = live
    }

    private func logPolicyTransition(
        profileID: UUID,
        prior: MonitorState,
        evaluation: ResetPolicyEvaluation,
        reading: Reading
    ) async throws {
        guard prior.phase != evaluation.state.phase else { return }
        switch evaluation.state.phase {
        case .confirming:
            _ = try await eventLog.append(
                profileID: profileID,
                kind: .thresholdConfirmed,
                message: "The canonical weekly balance crossed the configured threshold.",
                fields: [
                    "remainingPercent": String(format: "%.1f", reading.weeklyLimit.remainingPercent),
                    "confirmationCount": String(evaluation.state.confirmation?.count ?? 0),
                ]
            )
        case .noCredits:
            _ = try await eventLog.append(
                profileID: profileID,
                kind: .redemptionDeferred,
                message: "The weekly threshold was confirmed, but no saved reset was available."
            )
        default:
            break
        }
    }

    private func nextPollingInterval(for profileID: UUID) -> TimeInterval {
        let live = liveProfiles[profileID] ?? LiveProfileState()
        let phase = persistentState?.monitorState(for: profileID)?.phase ?? .attentionRequired
        return GuardPollingSchedule.interval(
            remainingPercent: live.weeklyLimit?.remainingPercent,
            phase: phase,
            connectionStatus: live.connectionStatus
        )
    }

    private func publish() async {
        let records = persistentState == nil ? [] : (try? await eventLog.entries(limit: 12)) ?? []
        guard let state = persistentState else {
            latestSnapshot = .empty
            await updateHandler(latestSnapshot)
            return
        }
        let snapshot = GuardRuntimeSnapshot(
            profiles: state.profiles.map { profile in
                profileSnapshot(profile: profile, state: state)
            },
            history: records.reversed().map { record in
                GuardRuntimeEvent(
                    id: record.id,
                    occurredAt: record.timestamp,
                    profileID: record.profileID,
                    summary: Self.summary(for: record.kind)
                )
            },
            isChecking: !checksInFlight.isEmpty,
            lastCheckedAt: lastCheckedAt,
            banner: state.profiles.compactMap { checkFailureBanners[$0.id] }.first ?? banner,
            generatedAt: now()
        )
        latestSnapshot = snapshot
        await updateHandler(snapshot)
    }

    private func profileSnapshot(
        profile: ProfileConfiguration,
        state: GuardPersistentState
    ) -> GuardRuntimeProfileSnapshot {
        let live = liveProfiles[profile.id] ?? LiveProfileState()
        let monitorState = state.monitorState(for: profile.id)
            ?? MonitorState(profileID: GuardPersistentState.key(for: profile.id), isEnabled: false)
        // Display only: a date only when it is the soonest of every saved reset. A capped list or
        // a row without its expiry gives none. The policy keeps its own credit choice.
        let nearestExpiry: Date? = if case let .reported(saved)? = quotaRecords[profile.id]?.lastSuccess?.inventory {
            saved.nextExpiry(after: now())
        } else {
            nil
        }
        return GuardRuntimeProfileSnapshot(
            id: profile.id,
            displayName: profile.displayName,
            accountHint: Self.maskedAccountHint(profile.expectedEmail),
            connectionStatus: live.connectionStatus,
            weeklyRemainingPercent: live.weeklyLimit?.remainingPercent,
            naturalResetAt: live.weeklyLimit?.resetsAt,
            availableResetCount: live.inventory?.availableCount ?? 0,
            nearestResetExpiry: nearestExpiry,
            phase: monitorState.phase,
            detail: live.detail,
            autoResetEnabled: profile.isEnabled,
            quota: quotaRecords[profile.id]
                ?? QuotaAccountRecord(provider: .codex, accountID: profile.id),
            removalKeepsResetRecord: state.removalKeepsResetRecord(for: profile.id)
        )
    }

    private func adoptPersistentState(_ candidate: GuardPersistentState) {
        let currentRevision = persistentState?.revision ?? 0
        let candidateRevision = candidate.revision ?? 0
        guard persistentState == nil || candidateRevision >= currentRevision else { return }
        persistentState = candidate
    }

    private func closeSessions(keepSnapshot: Bool) async {
        let activeSessions = Array(sessions.values)
        sessions.removeAll()
        initialized = false
        for session in activeSessions { await session.shutdown() }
        if !keepSnapshot {
            persistentState = nil
            liveProfiles.removeAll()
            quotaRecords.removeAll()
            checkFailureBanners.removeAll()
            latestSnapshot = .empty
        }
    }

    private nonisolated static func safeClassificationReason(
        _ failure: RateLimitClassificationFailure
    ) -> String {
        switch failure {
        case .nonCanonicalLimitID: "non-canonical limit identifier"
        case .nonCanonicalLimitName: "non-canonical limit name"
        case .weeklyWindowMissing: "weekly window missing"
        case .ambiguousWeeklyWindows: "ambiguous weekly windows"
        case .invalidWeeklyUsage: "invalid weekly usage"
        case .missingWeeklyReset: "weekly reset time missing"
        case .expiredWeeklyReset: "weekly reset time expired"
        }
    }

    private nonisolated static func summary(for kind: RedactedEventRecord.Kind) -> String {
        switch kind {
        case .profileConnected: "Connected an isolated Codex profile"
        case .profileDisconnected: "Codex profile disconnected"
        case .checkSucceeded: "Checked the weekly Codex allowance"
        case .checkFailed: "Weekly allowance check failed safely"
        case .thresholdConfirmed: "Weekly reset threshold observed"
        case .redemptionStarted: "Started saved weekly reset redemption"
        case .redemptionSucceeded: "Verified saved weekly reset"
        case .redemptionDeferred: "Deferred saved weekly reset"
        case .redemptionFailed: "Blocked saved weekly reset safely"
        case .verificationFailed: "Weekly reset verification needs attention"
        case .authenticationRequired: "Fresh Codex sign-in required"
        }
    }

    private nonisolated static func maskedAccountHint(_ email: String?) -> String {
        guard let email else { return "Expected Codex account" }
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, let first = parts[0].first else {
            return "Expected Codex account"
        }
        return "\(first)•••@\(parts[1])"
    }
}

@MainActor
extension GuardAppModel {
    func apply(_ snapshot: GuardRuntimeSnapshot) {
        let names = Dictionary(uniqueKeysWithValues: snapshot.profiles.map { ($0.id, $0.displayName) })
        let readingTime = snapshot.generatedAt ?? referenceDate ?? Date()
        profiles = snapshot.profiles.map { profile in
            let reading = profile.quota.reading(at: readingTime)
            let quotaWarning = Self.monitorWarning(for: profile, reading: reading)
            return GuardProfilePresentation(
                id: profile.id.uuidString.lowercased(),
                displayName: profile.displayName,
                accountHint: profile.accountHint,
                weeklyRemainingPercent: profile.weeklyRemainingPercent,
                naturalResetAt: profile.naturalResetAt,
                availableResetCount: profile.availableResetCount,
                nearestResetExpiry: profile.nearestResetExpiry,
                status: quotaWarning == nil ? Self.presentationStatus(for: profile) : .nearLimit,
                detail: quotaWarning.map {
                    Self.quotaDetail(
                        for: $0,
                        inventory: reading.inventory,
                        autoResetEnabled: profile.autoResetEnabled
                    )
                } ?? profile.detail,
                autoResetEnabled: profile.autoResetEnabled,
                identityVerified: profile.connectionStatus == .verified,
                quota: profile.quota,
                removalKeepsResetRecord: profile.removalKeepsResetRecord
            )
        }
        history = snapshot.history.map { event in
            GuardHistoryEvent(
                id: event.id,
                occurredAt: event.occurredAt,
                profileName: event.profileID.flatMap { names[$0] } ?? "Second Wind",
                summary: event.summary
            )
        }
        isChecking = snapshot.isChecking
        lastCheckedAt = snapshot.lastCheckedAt
        banner = snapshot.banner
        isReady = snapshot.hasLoadedProfiles
        if snapshot.hasLoadedProfiles {
            onQuotaRecordsChanged?(.codex, snapshot.profiles.map(\.quota))
        }
    }

    /// A current low window outranks a quiet automation phase. Monitoring warns whether or not
    /// Auto-redeem is on; redemption phases keep their own status because they are the fix.
    private static func monitorWarning(
        for profile: GuardRuntimeProfileSnapshot,
        reading: QuotaAccountReading
    ) -> QuotaWindowReading? {
        guard profile.connectionStatus == .verified,
              profile.phase == .disabled || profile.phase == .healthy,
              let warning = reading.warning, warning.isCurrent
        else {
            return nil
        }
        return warning
    }

    static func quotaDetail(
        for warning: QuotaWindowReading,
        inventory: ResetInventoryReading,
        autoResetEnabled: Bool
    ) -> String {
        let usedUp = warning.level == .exhausted
        switch warning.window.kind {
        case .session:
            return usedUp
                ? "5-hour limit is used up. It renews on its own."
                : "5-hour limit is running low."
        case .weekly, .modelWeekly:
            let state = usedUp ? "Weekly limit is used up." : "Weekly limit is running low."
            if !autoResetEnabled, case let .known(saved, _) = inventory, saved.availableCount > 0 {
                return state + " Turn on Auto-redeem to use a saved reset."
            }
            return state
        }
    }

    private static func presentationStatus(
        for profile: GuardRuntimeProfileSnapshot
    ) -> GuardProfileStatus {
        switch profile.connectionStatus {
        case .connecting, .authenticationRequired:
            return .disconnected
        case .identityMismatch, .failed:
            return .attention
        case .verified:
            break
        }
        return switch profile.phase {
        case .disabled, .healthy: .healthy
        case .nearLimit, .noCredits: .nearLimit
        case .confirming: .confirming
        case .redeeming, .verifying: .redeeming
        case .verified: .verified
        case .attentionRequired: .attention
        }
    }
}

@MainActor
func makeGuardRuntimeController(
    model: GuardAppModel,
    configuration: GuardRuntimeConfiguration,
    alerts: AlertRouter
) -> GuardRuntimeController {
    let controller = GuardRuntimeController(
        configuration: configuration,
        updateHandler: { [weak model] snapshot in
            model?.apply(snapshot)
        },
        notificationHandler: { alerts.post($0) }
    )
    model.onCheckNow = { [weak controller] in
        Task { _ = await controller?.checkNow() }
    }
    model.onAddProfile = { [weak controller, weak model] email, displayName in
        Task { @MainActor in
            defer { model?.isAddingProfile = false }
            do {
                guard let controller else { throw GuardRuntimeError.runtimeStopped }
                _ = try await controller.addProfile(expectedEmail: email, displayName: displayName)
                model?.profileEmail = ""
                model?.profileDisplayName = ""
                model?.isShowingAddProfile = false
                model?.enrollmentError = nil
            } catch {
                model?.isShowingAddProfile = true
                model?.enrollmentError = error is MonitorPersistenceError
                    ? error.localizedDescription
                    : "Could not confirm the profile was saved. Check the profile list before trying again."
            }
        }
    }
    model.onToggleAutoReset = { [weak controller, weak model] rawID, enabled in
        guard configuration.operationMode == .production else { return }
        guard let profileID = UUID(uuidString: rawID) else { return }
        Task { @MainActor in
            do {
                _ = try await controller?.setEnabled(profileID: profileID, enabled: enabled)
                if enabled { _ = await alerts.requestPermission() }
            } catch {
                if let snapshot = await controller?.snapshot() {
                    model?.apply(snapshot)
                }
                model?.reportActionFailure(
                    "Could not confirm the automatic reset setting. Redemption remains safely blocked.",
                    for: AccountRef(provider: .codex, id: profileID)
                )
            }
        }
    }
    model.onReconnect = { [weak controller, weak model] rawID in
        guard let profileID = UUID(uuidString: rawID) else { return }
        Task { @MainActor in
            do {
                guard let url = try await controller?.beginConnection(profileID: profileID) else {
                    return
                }
                NSWorkspace.shared.open(url)
            } catch {
                model?.reportActionFailure(
                    "Could not start the isolated Codex sign-in.",
                    for: AccountRef(provider: .codex, id: profileID)
                )
            }
        }
    }
    return controller
}
