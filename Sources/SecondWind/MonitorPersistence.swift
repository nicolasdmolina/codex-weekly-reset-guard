import SecondWindCore
import Foundation

/// An uncertain Codex redemption kept after its account was removed. Re-adding the same email
/// reattaches it, so the same idempotency key is reused and a reset is never requested twice.
struct RetainedRedemption: Codable, Equatable, Sendable {
    /// Normalized email of the removed account.
    var expectedEmail: String
    var formerProfileID: String
    var attempt: RedemptionAttempt
    var confirmation: ThresholdConfirmation?
    var lastWeeklyLimit: CanonicalWeeklyLimit?
    var retainedAt: Date
}

struct GuardPersistentState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var profiles: [ProfileConfiguration]
    var monitorStates: [String: MonitorState]
    /// Monotonic durable revision used to reject stale whole-state snapshots after actor reentry.
    var revision: UInt64?
    let createdAt: Date
    var updatedAt: Date
    /// Uncertain redemptions of removed accounts. Optional and omitted when empty, so saved
    /// state from before account removal still decodes unchanged.
    var retainedRedemptions: [RetainedRedemption]?
    /// Lowercased UUIDs of removed profiles whose app-owned Codex homes still need deleting.
    /// Written in the same transaction as the removal, cleared once the folder is gone.
    var pendingHomeDiscards: [String]?

    init(
        schemaVersion: Int = currentSchemaVersion,
        profiles: [ProfileConfiguration],
        monitorStates: [String: MonitorState],
        revision: UInt64? = 0,
        createdAt: Date,
        updatedAt: Date? = nil,
        retainedRedemptions: [RetainedRedemption]? = nil,
        pendingHomeDiscards: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.monitorStates = monitorStates
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.retainedRedemptions = retainedRedemptions
        self.pendingHomeDiscards = pendingHomeDiscards
    }

    static func key(for profileID: UUID) -> String {
        profileID.uuidString.lowercased()
    }

    func monitorState(for profileID: UUID) -> MonitorState? {
        monitorStates[Self.key(for: profileID)]
    }

    /// True when removing this profile would keep an uncertain redemption record.
    func removalKeepsResetRecord(for profileID: UUID) -> Bool {
        guard let phase = monitorState(for: profileID)?.attempt?.phase else { return false }
        return MonitorPersistence.mustRetainOnRemoval(phase)
    }
}

/// The durable result of removing one Codex profile.
struct ProfileRemovalResult: Equatable, Sendable {
    let state: GuardPersistentState
    let keptResetRecord: Bool
}

enum MonitorPersistenceError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchemaVersion(Int)
    case stateNotInitialized
    case duplicateProfileIdentifier
    case duplicateExpectedIdentity
    case invalidExpectedIdentity
    case missingMonitorState(UUID)
    case invalidMonitorState(UUID)
    case concurrentModification(expected: UInt64, actual: UInt64)
    case revisionExhausted
    case profileNotFound(UUID)
    case invalidDisplayName
    case invalidRetainedRedemption
    case invalidPendingHomeDiscard

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "The saved monitor state uses unsupported schema version \(version)."
        case .stateNotInitialized:
            "Open Second Wind to set up your first account."
        case .duplicateProfileIdentifier:
            "The saved profile identifiers are not unique."
        case .duplicateExpectedIdentity:
            "That account already has a profile. Connect its existing profile instead."
        case .invalidExpectedIdentity:
            "Enter the email address you use to sign in to Codex."
        case let .missingMonitorState(profileID):
            "The saved state is missing monitor data for profile \(profileID.uuidString)."
        case let .invalidMonitorState(profileID):
            "The saved monitor data does not belong to profile \(profileID.uuidString)."
        case let .concurrentModification(expected, actual):
            "The saved monitor state changed concurrently (expected revision \(expected), found \(actual))."
        case .revisionExhausted:
            "The saved monitor revision is invalid."
        case .profileNotFound:
            "That Codex account is no longer in the list."
        case .invalidDisplayName:
            "Enter a name with at least one letter or number."
        case .invalidRetainedRedemption:
            "A saved reset record from a removed account is invalid."
        case .invalidPendingHomeDiscard:
            "A saved folder cleanup entry is invalid."
        }
    }
}

enum MonitorPersistenceTestingFault: Equatable, Sendable {
    case beforeAddProfileWrite
    case afterAddProfileWrite
    case beforeSetProfileEnabledWrite
    case afterSetProfileEnabledWrite
    case beforeMonitorStateWrite(RedemptionAttemptPhase)
    case beforeRenameProfileWrite
    case beforeRemoveProfileWrite
    case afterRemoveProfileWrite
    /// Simulates a crash after the removal committed but before its folder was deleted.
    case beforeProfileHomeDiscard
}

private enum MonitorPersistenceTestingFailure: Error {
    case injected
}

/// Owns the only durable policy-state write path.
///
/// `saveMonitorState` does not return until `SecureStateStore` has atomically renamed and fsynced
/// the state file. The runtime awaits it before issuing a consume request.
actor MonitorPersistence {
    nonisolated let stateFileURL: URL
    nonisolated let profilesDirectory: URL

    private let store: SecureStateStore<GuardPersistentState>
    private var testingFault: MonitorPersistenceTestingFault?
    private let afterMonitorStateWrite: @Sendable (MonitorState) -> Void

    init(
        stateFileURL: URL = ProfileConfiguration.defaultApplicationSupportDirectory
            .appendingPathComponent("state.json", isDirectory: false),
        profilesDirectory: URL = ProfileConfiguration.defaultProfilesDirectory,
        afterMonitorStateWrite: @escaping @Sendable (MonitorState) -> Void = { _ in }
    ) {
        self.stateFileURL = stateFileURL.standardizedFileURL
        self.profilesDirectory = profilesDirectory.standardizedFileURL
        self.store = SecureStateStore(fileURL: self.stateFileURL)
        self.testingFault = nil
        self.afterMonitorStateWrite = afterMonitorStateWrite
    }

    func injectTestingFault(_ fault: MonitorPersistenceTestingFault) {
        testingFault = fault
    }

    func loadOrBootstrap(
        now: Date = Date()
    ) async throws -> GuardPersistentState {
        if let state = try await store.load() {
            try Self.validate(state)
            for profile in state.profiles {
                try profile.prepareCodexHome(profilesDirectory: profilesDirectory)
            }
            guard !(state.pendingHomeDiscards ?? []).isEmpty else { return state }
            // Finish folder deletions that a crash or failed delete interrupted. Only folders
            // named in the durable list are touched, and a failure never blocks startup.
            _ = try? await discardPendingProfileHomes()
            return (try? await snapshot()) ?? state
        }

        let state = GuardPersistentState(
            profiles: [],
            monitorStates: [:],
            createdAt: now
        )
        // Preserve a state created by another pending initialization instead of overwriting it.
        return try await store.update(defaultValue: state) { current in
            try Self.validate(current)
            return current
        }
    }

    func snapshot() async throws -> GuardPersistentState {
        guard let state = try await store.load() else {
            throw MonitorPersistenceError.stateNotInitialized
        }
        try Self.validate(state)
        return state
    }

    /// Enrolls an identity only. Authentication remains an explicit browser action, and every new
    /// profile starts with automatic redemption disabled regardless of other profile settings.
    @discardableResult
    func addProfile(
        expectedEmail: String,
        displayName: String,
        id: UUID = UUID(),
        now: Date = Date()
    ) async throws -> GuardPersistentState {
        let email = Self.normalizedEmail(expectedEmail)
        guard Self.isValidEmail(email) else {
            throw MonitorPersistenceError.invalidExpectedIdentity
        }
        let baseline = try await snapshot()
        guard !baseline.profiles.contains(where: {
            Self.normalizedEmail($0.expectedEmail ?? "") == email
        }) else {
            throw MonitorPersistenceError.duplicateExpectedIdentity
        }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = ProfileConfiguration(
            id: id,
            displayName: name.isEmpty ? "Codex profile \(baseline.profiles.count + 1)" : String(name.prefix(60)),
            expectedEmail: email,
            isEnabled: false
        )
        let activeTestingFault = testingFault
        testingFault = nil
        if activeTestingFault == .beforeAddProfileWrite {
            throw MonitorPersistenceTestingFailure.injected
        }
        try profile.prepareCodexHome(profilesDirectory: profilesDirectory)
        let updated = try await store.update(defaultValue: baseline) { state in
            guard !state.profiles.contains(where: {
                Self.normalizedEmail($0.expectedEmail ?? "") == email
            }) else {
                throw MonitorPersistenceError.duplicateExpectedIdentity
            }
            state.profiles.append(profile)
            let key = GuardPersistentState.key(for: id)
            var monitorState = MonitorState(profileID: key, isEnabled: false)
            // Re-adding a removed account reattaches its uncertain redemption with the same
            // idempotency key. The profile still starts paused; reconciliation resumes only
            // after the user reconnects and turns automatic redemption back on.
            if var retained = state.retainedRedemptions,
               let index = retained.firstIndex(where: { $0.expectedEmail == email }) {
                let record = retained.remove(at: index)
                var attempt = record.attempt
                attempt.profileID = key
                monitorState.attempt = attempt
                monitorState.confirmation = record.confirmation
                monitorState.lastWeeklyLimit = record.lastWeeklyLimit
                state.retainedRedemptions = retained.isEmpty ? nil : retained
            }
            state.monitorStates[key] = monitorState
            guard (state.revision ?? 0) < UInt64.max else {
                throw MonitorPersistenceError.revisionExhausted
            }
            state.revision = (state.revision ?? 0) + 1
            state.updatedAt = now
            try Self.validate(state)
            return state
        }
        if activeTestingFault == .afterAddProfileWrite {
            throw MonitorPersistenceTestingFailure.injected
        }
        return updated
    }

    @discardableResult
    func saveMonitorState(
        _ monitorState: MonitorState,
        now: Date = Date(),
        expectedRevision: UInt64? = nil
    ) async throws
        -> GuardPersistentState
    {
        if case let .beforeMonitorStateWrite(phase) = testingFault,
           monitorState.attempt?.phase == phase {
            testingFault = nil
            throw MonitorPersistenceTestingFailure.injected
        }
        let baseline = try await snapshot()
        guard let profileID = UUID(uuidString: monitorState.profileID) else {
            throw MonitorPersistenceError.invalidMonitorState(
                UUID(uuidString: monitorState.profileID) ?? UUID()
            )
        }
        let saved = try await store.update(defaultValue: baseline) { state in
            let actualRevision = state.revision ?? 0
            if let expectedRevision, actualRevision != expectedRevision {
                throw MonitorPersistenceError.concurrentModification(
                    expected: expectedRevision,
                    actual: actualRevision
                )
            }
            guard let profile = state.profiles.first(where: { $0.id == profileID }) else {
                throw MonitorPersistenceError.invalidMonitorState(profileID)
            }
            var mergedState = monitorState
            // The profile setting is authoritative. A check that began before a disable must never
            // re-enable the monitor by saving a stale policy snapshot after the toggle commits.
            mergedState.isEnabled = profile.isEnabled
            if !profile.isEnabled {
                mergedState.phase = .disabled
                mergedState.attentionMessage = nil
                if mergedState.attempt?.phase == .prepared {
                    // Prepared means the network boundary was never crossed, so disabling can
                    // safely discard it. Ambiguous/in-flight attempts remain for reconciliation.
                    mergedState.attempt = nil
                    mergedState.confirmation = nil
                } else if mergedState.attempt == nil {
                    mergedState.confirmation = nil
                }
            }
            state.monitorStates[GuardPersistentState.key(for: profileID)] = mergedState
            guard (state.revision ?? 0) < UInt64.max else {
                throw MonitorPersistenceError.revisionExhausted
            }
            state.revision = (state.revision ?? 0) + 1
            state.updatedAt = now
            try Self.validate(state)
            return state
        }
        afterMonitorStateWrite(monitorState)
        return saved
    }

    @discardableResult
    func setProfileEnabled(
        _ profileID: UUID,
        enabled: Bool,
        now: Date = Date(),
        expectedRevision: UInt64? = nil
    ) async throws
        -> GuardPersistentState
    {
        let activeTestingFault = testingFault
        testingFault = nil
        if activeTestingFault == .beforeSetProfileEnabledWrite {
            throw MonitorPersistenceTestingFailure.injected
        }
        let baseline = try await snapshot()
        let updated = try await store.update(defaultValue: baseline) { state in
            let actualRevision = state.revision ?? 0
            if let expectedRevision, actualRevision != expectedRevision {
                throw MonitorPersistenceError.concurrentModification(
                    expected: expectedRevision,
                    actual: actualRevision
                )
            }
            guard let profileIndex = state.profiles.firstIndex(where: { $0.id == profileID }),
                  var monitorState = state.monitorState(for: profileID) else {
                throw MonitorPersistenceError.missingMonitorState(profileID)
            }

            state.profiles[profileIndex].isEnabled = enabled
            monitorState.isEnabled = enabled
            monitorState.phase = enabled ? .healthy : .disabled
            if !enabled {
                // A prepared request has not crossed the network boundary and can be safely disarmed.
                // In-flight, retryable, and verification attempts stay durable for later reconciliation.
                if let phase = monitorState.attempt?.phase,
                   [.prepared, .requestRejected].contains(phase) {
                    monitorState.attempt = nil
                    monitorState.confirmation = nil
                } else if monitorState.attempt == nil {
                    monitorState.confirmation = nil
                }
            } else if monitorState.attempt == nil {
                monitorState.confirmation = nil
            }
            monitorState.attentionMessage = nil
            state.monitorStates[GuardPersistentState.key(for: profileID)] = monitorState
            guard (state.revision ?? 0) < UInt64.max else {
                throw MonitorPersistenceError.revisionExhausted
            }
            state.revision = (state.revision ?? 0) + 1
            state.updatedAt = now
            try Self.validate(state)
            return state
        }
        if activeTestingFault == .afterSetProfileEnabledWrite {
            throw MonitorPersistenceTestingFailure.injected
        }
        return updated
    }

    /// Changes only the display name. Renaming to the current name writes nothing.
    @discardableResult
    func renameProfile(
        _ profileID: UUID,
        displayName: String,
        now: Date = Date()
    ) async throws -> GuardPersistentState {
        guard let name = AccountNameRules.normalized(
            displayName,
            maximumLength: AccountNameRules.codexMaximumLength
        ) else {
            throw MonitorPersistenceError.invalidDisplayName
        }
        let activeTestingFault = testingFault
        if activeTestingFault == .beforeRenameProfileWrite {
            testingFault = nil
            throw MonitorPersistenceTestingFailure.injected
        }
        let baseline = try await snapshot()
        guard let current = baseline.profiles.first(where: { $0.id == profileID }) else {
            throw MonitorPersistenceError.profileNotFound(profileID)
        }
        if current.displayName == name { return baseline }
        return try await store.update(defaultValue: baseline) { state in
            guard let index = state.profiles.firstIndex(where: { $0.id == profileID }) else {
                throw MonitorPersistenceError.profileNotFound(profileID)
            }
            state.profiles[index].displayName = name
            try Self.advanceRevision(&state, now: now)
            try Self.validate(state)
            return state
        }
    }

    /// Removes one profile and its monitor state in a single atomic write.
    ///
    /// An uncertain redemption (possibly sent, or sent but unproven) moves into
    /// `retainedRedemptions` in the same write, so it can never be orphaned. A prepared attempt
    /// never crossed the network boundary and a definite outcome needs no recovery, so both are
    /// discarded. The decision reads the latest durable attempt inside the transaction. The
    /// profile's private folder is named in `pendingHomeDiscards` in the same write; callers stop
    /// its Codex session and then call `discardPendingProfileHomes()`.
    @discardableResult
    func removeProfile(_ profileID: UUID, now: Date = Date()) async throws -> ProfileRemovalResult {
        let activeTestingFault = testingFault
        if activeTestingFault == .beforeRemoveProfileWrite
            || activeTestingFault == .afterRemoveProfileWrite {
            testingFault = nil
        }
        if activeTestingFault == .beforeRemoveProfileWrite {
            throw MonitorPersistenceTestingFailure.injected
        }
        let baseline = try await snapshot()
        let key = GuardPersistentState.key(for: profileID)
        let result = try await store.update(defaultValue: baseline) { state in
            guard let index = state.profiles.firstIndex(where: { $0.id == profileID }) else {
                throw MonitorPersistenceError.profileNotFound(profileID)
            }
            let profile = state.profiles.remove(at: index)
            let monitorState = state.monitorStates.removeValue(forKey: key)
            var keptResetRecord = false
            if let monitorState, let attempt = monitorState.attempt,
               Self.mustRetainOnRemoval(attempt.phase) {
                let email = Self.normalizedEmail(profile.expectedEmail ?? "")
                var retained = state.retainedRedemptions ?? []
                retained.append(RetainedRedemption(
                    expectedEmail: email,
                    formerProfileID: key,
                    attempt: attempt,
                    confirmation: monitorState.confirmation,
                    lastWeeklyLimit: monitorState.lastWeeklyLimit,
                    retainedAt: now
                ))
                state.retainedRedemptions = retained
                keptResetRecord = true
            }
            var discards = state.pendingHomeDiscards ?? []
            if !discards.contains(key) { discards.append(key) }
            state.pendingHomeDiscards = discards
            try Self.advanceRevision(&state, now: now)
            try Self.validate(state)
            return ProfileRemovalResult(state: state, keptResetRecord: keptResetRecord)
        }
        if activeTestingFault == .afterRemoveProfileWrite {
            throw MonitorPersistenceTestingFailure.injected
        }
        return result
    }

    /// Deletes the private folders of removed profiles and clears each entry once its folder is
    /// gone. Returns the profiles whose folders could not be deleted yet; they stay pending.
    /// Callers must have shut down the profile's Codex session first.
    @discardableResult
    func discardPendingProfileHomes(now: Date = Date()) async throws -> [UUID] {
        if testingFault == .beforeProfileHomeDiscard {
            testingFault = nil
            throw MonitorPersistenceTestingFailure.injected
        }
        let baseline = try await snapshot()
        let pending = baseline.pendingHomeDiscards ?? []
        guard !pending.isEmpty else { return [] }
        var discarded = Set<String>()
        var remaining: [UUID] = []
        for key in pending {
            // Validation guarantees a lowercased UUID that names no active profile.
            guard let profileID = UUID(uuidString: key) else { continue }
            do {
                try OwnedProfileDirectory.discard(profileID: profileID, root: profilesDirectory)
                discarded.insert(key)
            } catch {
                remaining.append(profileID)
            }
        }
        guard !discarded.isEmpty else { return remaining }
        let deletedKeys = discarded
        try await store.update(defaultValue: baseline) { state in
            let left = (state.pendingHomeDiscards ?? []).filter { !deletedKeys.contains($0) }
            state.pendingHomeDiscards = left.isEmpty ? nil : left
            try Self.advanceRevision(&state, now: now)
            try Self.validate(state)
        }
        return remaining
    }

    /// Uncertain phases: the request may have reached Codex, or reached it without proof yet.
    nonisolated static func mustRetainOnRemoval(_ phase: RedemptionAttemptPhase) -> Bool {
        switch phase {
        case .requestInFlight, .retryable, .awaitingVerification, .verificationFailed:
            true
        case .prepared, .succeeded, .nothingToReset, .noCredit, .requestRejected:
            false
        }
    }

    private nonisolated static func advanceRevision(
        _ state: inout GuardPersistentState,
        now: Date
    ) throws {
        guard (state.revision ?? 0) < UInt64.max else {
            throw MonitorPersistenceError.revisionExhausted
        }
        state.revision = (state.revision ?? 0) + 1
        state.updatedAt = now
    }

    private nonisolated static func validate(_ state: GuardPersistentState) throws {
        guard state.schemaVersion == GuardPersistentState.currentSchemaVersion else {
            throw MonitorPersistenceError.unsupportedSchemaVersion(state.schemaVersion)
        }
        guard Set(state.profiles.map(\.id)).count == state.profiles.count else {
            throw MonitorPersistenceError.duplicateProfileIdentifier
        }
        let identities = state.profiles.compactMap(\.expectedEmail).map(Self.normalizedEmail)
        guard Set(identities).count == identities.count else {
            throw MonitorPersistenceError.duplicateExpectedIdentity
        }

        for profile in state.profiles {
            guard let expectedEmail = profile.expectedEmail,
                  !Self.normalizedEmail(expectedEmail).isEmpty else {
                throw MonitorPersistenceError.invalidExpectedIdentity
            }
            guard let monitorState = state.monitorState(for: profile.id) else {
                throw MonitorPersistenceError.missingMonitorState(profile.id)
            }
            guard monitorState.schemaVersion == MonitorState.currentSchemaVersion,
                  monitorState.profileID == GuardPersistentState.key(for: profile.id),
                  monitorState.isEnabled == profile.isEnabled else {
                throw MonitorPersistenceError.invalidMonitorState(profile.id)
            }
            if let attempt = monitorState.attempt {
                guard attempt.schemaVersion == RedemptionAttempt.currentSchemaVersion,
                      attempt.profileID == monitorState.profileID else {
                    throw MonitorPersistenceError.invalidMonitorState(profile.id)
                }
            }
        }

        let activeKeys = Set(state.profiles.map { GuardPersistentState.key(for: $0.id) })
        let retained = state.retainedRedemptions ?? []
        let retainedEmails = retained.map(\.expectedEmail)
        guard Set(retainedEmails).count == retainedEmails.count,
              Set(retainedEmails).isDisjoint(with: identities) else {
            throw MonitorPersistenceError.invalidRetainedRedemption
        }
        for record in retained {
            guard isValidEmail(record.expectedEmail),
                  record.expectedEmail == normalizedEmail(record.expectedEmail),
                  record.attempt.schemaVersion == RedemptionAttempt.currentSchemaVersion,
                  record.attempt.profileID == record.formerProfileID,
                  mustRetainOnRemoval(record.attempt.phase),
                  !activeKeys.contains(record.formerProfileID) else {
                throw MonitorPersistenceError.invalidRetainedRedemption
            }
        }

        let discards = state.pendingHomeDiscards ?? []
        guard Set(discards).count == discards.count else {
            throw MonitorPersistenceError.invalidPendingHomeDiscard
        }
        for key in discards {
            guard UUID(uuidString: key).map(GuardPersistentState.key(for:)) == key,
                  !activeKeys.contains(key) else {
                throw MonitorPersistenceError.invalidPendingHomeDiscard
            }
        }
    }

    nonisolated static func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    nonisolated static func isValidEmail(_ value: String) -> Bool {
        let email = normalizedEmail(value)
        return email.count <= 254
            && email.range(
                of: #"^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?)+$"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            && !email.hasPrefix(".")
            && !email.contains("..")
            && !email.contains(".@")
    }
}
