import Foundation

/// Routes the popover's rename and remove requests to the controller that owns each provider.
/// Every closure throws only `AccountLifecycleError`.
struct AccountLifecycleHandlers: Sendable {
    let rename: @Sendable (AccountRef, String) async throws -> Void
    let remove: @Sendable (AccountRef) async throws -> Void

    /// `onNotice` receives the outcome's leftover sentence (for example a Claude sign-in that may
    /// still be in the Keychain) after a successful removal.
    init(
        codex: GuardRuntimeController,
        claude: ClaudeMonitorController?,
        antigravity: AntigravityMonitor? = nil,
        onNotice: (@MainActor @Sendable (AccountRef, String) -> Void)? = nil
    ) {
        rename = { [weak codex, weak claude, weak antigravity] account, name in
            switch account.provider {
            case .codex:
                guard let codex else { throw AccountLifecycleError.unavailable }
                _ = try await codex.renameProfile(profileID: account.id, displayName: name)
            case .claude:
                guard let claude else { throw AccountLifecycleError.unavailable }
                try await claude.renameProfile(profileID: account.id, displayName: name)
            case .antigravity:
                guard let antigravity else { throw AccountLifecycleError.unavailable }
                try await antigravity.rename(account.id, to: name)
            }
        }
        remove = { [weak codex, weak claude, weak antigravity] account in
            let outcome: AccountRemovalOutcome
            switch account.provider {
            case .codex:
                guard let codex else { throw AccountLifecycleError.unavailable }
                outcome = try await codex.removeProfile(profileID: account.id)
            case .claude:
                guard let claude else { throw AccountLifecycleError.unavailable }
                outcome = try await claude.removeProfile(profileID: account.id)
            case .antigravity:
                guard let antigravity else { throw AccountLifecycleError.unavailable }
                try await antigravity.remove(account.id)
                outcome = .complete
            }
            if let notice = outcome.notice, let onNotice {
                await onNotice(account, notice)
            }
        }
    }
}
