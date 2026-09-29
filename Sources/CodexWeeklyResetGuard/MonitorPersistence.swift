import CodexWeeklyResetGuardCore
import Foundation

struct GuardPersistentState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var profiles: [ProfileConfiguration]
    var monitorStates: [String: MonitorState]
    /// Monotonic durable revision used to reject stale whole-state snapshots after actor reentry.
    var revision: UInt64?
    let createdAt: Date
    var updatedAt: Date

    init(
        schemaVersion: Int = currentSchemaVersion,
        profiles: [ProfileConfiguration],
        monitorStates: [String: MonitorState],
        revision: UInt64? = 0,
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.monitorStates = monitorStates
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    static func key(for profileID: UUID) -> String {
        profileID.uuidString.lowercased()
    }

    func monitorState(for profileID: UUID) -> MonitorState? {
        monitorStates[Self.key(for: profileID)]
    }
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

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "The saved monitor state uses unsupported schema version \(version)."
        case .stateNotInitialized:
            "Open Reset Guard to set up your first profile."
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
        }
    }
}

enum MonitorPersistenceTestingFault: Equatable, Sendable {
    case beforeAddProfileWrite
    case afterAddProfileWrite
    case beforeSetProfileEnabledWrite
    case afterSetProfileEnabledWrite
    case beforeMonitorStateWrite(RedemptionAttemptPhase)
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
            return state
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
            state.monitorStates[GuardPersistentState.key(for: id)] = MonitorState(
                profileID: GuardPersistentState.key(for: id),
                isEnabled: false
            )
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
