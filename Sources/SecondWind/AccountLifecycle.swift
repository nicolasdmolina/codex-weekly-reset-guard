import Foundation
import SecondWindCore

/// Errors from renaming or removing one account. Each message is a short recovery sentence the
/// popover shows after "Could not rename this account." or "Could not remove <name>.".
enum AccountLifecycleError: Error, Equatable, LocalizedError, Sendable {
    case accountNotFound
    case invalidName
    case busy
    case readOnly
    case unavailable
    case notSaved
    case signedOutButNotRemoved

    var errorDescription: String? {
        switch self {
        case .accountNotFound:
            "It is no longer in the list."
        case .invalidName:
            "Enter a name with at least one letter or number."
        case .busy:
            "This account is busy checking or signing in. Try again in a moment."
        case .readOnly:
            "Diagnostics mode cannot change accounts."
        case .unavailable:
            "Second Wind is still starting or is shutting down."
        case .notSaved:
            "The change could not be saved. Try again."
        case .signedOutButNotRemoved:
            "It was signed out of Claude but is still in the list. Try removing it again."
        }
    }
}

/// What a completed removal left behind. The account is off the list in every case.
struct AccountRemovalOutcome: Equatable, Sendable {
    /// The private folder could not be deleted yet. Codex retries at next launch; Claude sweeps
    /// the isolated leftover at next start.
    var folderCleanupPending = false
    /// Claude only: `claude auth logout` did not confirm, so the account's sign-in may still be
    /// in the login Keychain.
    var claudeSignInMayRemain = false
    /// Codex only: an unresolved reset record was kept for this email.
    var keptResetRecord = false

    static let complete = AccountRemovalOutcome()

    /// Extra sentence for the confirmation toast, or nil when nothing is left over.
    var notice: String? {
        if claudeSignInMayRemain {
            return "Its Claude sign-in may still be in your Keychain under a name starting with "
                + "\"Claude Code-credentials-\". You can delete it in Keychain Access."
        }
        if folderCleanupPending {
            return "Its private folder will be deleted the next time Second Wind starts."
        }
        return nil
    }
}

enum AccountNameRules {
    static let codexMaximumLength = 60
    static let claudeMaximumLength = 48

    /// Trims, folds whitespace and line breaks into single spaces, and caps the length.
    /// Returns nil when nothing printable is left.
    static func normalized(_ raw: String, maximumLength: Int) -> String? {
        let words = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.filter { !$0.unicodeScalars.allSatisfy(CharacterSet.controlCharacters.contains) } }
            .filter { !$0.isEmpty }
        let joined = words.joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        return String(joined.prefix(maximumLength)).trimmingCharacters(in: .whitespaces)
    }
}

/// Pure transforms on saved Claude state, applied by `ClaudeMonitorController` under its write gate.
enum ClaudeAccountLifecycle {
    /// Returns false when the profile is not listed.
    @discardableResult
    static func rename(
        _ profileID: UUID,
        to displayName: String,
        in state: inout ClaudePersistentState
    ) -> Bool {
        guard let index = state.profiles.firstIndex(where: { $0.id == profileID }) else {
            return false
        }
        state.profiles[index].displayName = displayName
        return true
    }

    /// Legacy alert keys have no account ID and stay until the bounded history expires them.
    @discardableResult
    static func remove(_ profileID: UUID, from state: inout ClaudePersistentState) -> Bool {
        guard let index = state.profiles.firstIndex(where: { $0.id == profileID }) else {
            return false
        }
        state.profiles.remove(at: index)
        state.states.removeValue(forKey: ClaudePersistentState.key(for: profileID))
        let prefix = ClaudePersistentState.key(for: profileID) + "|"
        state.sentAlertKeys.removeAll { $0.hasPrefix(prefix) }
        return true
    }
}

extension AccountLifecycleError {
    /// Maps a Codex persistence or runtime failure onto the account-level vocabulary.
    init(codexFailure error: any Error) {
        switch error {
        case let error as AccountLifecycleError:
            self = error
        case MonitorPersistenceError.profileNotFound,
             GuardRuntimeError.profileNotFound:
            self = .accountNotFound
        case MonitorPersistenceError.invalidDisplayName:
            self = .invalidName
        case GuardRuntimeError.runtimeNotInitialized,
             GuardRuntimeError.runtimeStopped:
            self = .unavailable
        default:
            self = .notSaved
        }
    }
}
