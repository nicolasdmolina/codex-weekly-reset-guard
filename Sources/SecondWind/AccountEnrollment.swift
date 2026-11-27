import AppKit
import Foundation
import SecondWindCore

/// Where one account's own sign-in stands. Rows keep their own status line; the add-account
/// flow and the reopen-after-sign-in behaviour read this instead of parsing row text.
enum SignInState: Equatable, Sendable {
    /// The browser sign-in is under way.
    case waiting
    /// Signed in; Second Wind is reading the account.
    case checking
    case connected
    /// Not signed in: never started, cancelled or did not finish.
    case signedOut
    /// A reconnect signed in with a different account from the one this profile watches.
    case wrongAccount(found: String?)
    /// A new profile's first sign-in was an account another profile already watches.
    case alreadyAdded(found: String?)
    /// Claude only: the sign-in has no Pro or Max plan, so there are no limits to read.
    case noPlan
    case failed(String)

    /// Finished one way or the other, so the user has a result to read or a decision to make.
    var isSettled: Bool {
        switch self {
        case .waiting, .checking: false
        case .connected, .signedOut, .wrongAccount, .alreadyAdded, .noPlan, .failed: true
        }
    }

    var isUnderWay: Bool { !isSettled }
}

/// The add-account flow. It lives on the model, not the view, because the popover closes as
/// soon as the browser takes focus and must reopen on the same step.
struct EnrollmentFlow: Equatable {
    enum Step: Equatable {
        case choose
        /// Saving the new account and opening its sign-in.
        case starting(ProviderKind)
        /// The new account could not be saved, so no sign-in started.
        case couldNotStart(ProviderKind, String)
        case signIn(AccountRef)
    }

    var step: Step
    /// Codex returns its sign-in page; Claude Code reports its own once it has opened it.
    var signInURL: URL?
    /// From a start or Try again until the account reports a sign-in under way, so the
    /// signed-out state it starts in never reads as a failure.
    var isStarting = false
    /// The account was saved but its sign-in page could not be opened.
    var startFailure: String?
    /// The popover reopens once per settled sign-in, not on every later snapshot.
    var hasSettled = false
    /// The browser is still signed in to another account, so the link goes to the clipboard for
    /// a private window instead of opening in that browser.
    var usesPrivateWindow = false
    var hasCopiedLink = false

    var hasStartedSignIn: Bool {
        switch step {
        case .choose, .couldNotStart: false
        case .starting, .signIn: true
        }
    }
}

/// What the flow shows, derived from its step and the account's live sign-in state.
enum EnrollmentPhase: Equatable {
    case choose
    /// The account is nil while it is still being saved.
    case waiting(ProviderKind, AccountRef?, checking: Bool)
    case connected(AccountRef)
    case problem(ProviderKind, AccountRef?, SignInState)

    var account: AccountRef? {
        switch self {
        case .choose: nil
        case let .waiting(_, ref, _), let .problem(_, ref, _): ref
        case let .connected(ref): ref
        }
    }

    var provider: ProviderKind? {
        switch self {
        case .choose: nil
        case let .waiting(provider, _, _), let .problem(provider, _, _): provider
        case let .connected(ref): ref.provider
        }
    }
}

extension ProviderKind {
    /// The account a person signs in with, which is not always the product's own name.
    var signInAccountName: String {
        switch self {
        case .codex: "ChatGPT"
        case .claude: "Claude"
        }
    }

    var glyph: String {
        switch self {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "sparkle"
        }
    }
}

/// Names for new accounts. An account starts with a provisional name and takes one from its
/// email at its first sign-in, so adding an account asks for nothing.
enum AccountNaming {
    /// Until the first sign-in says whose account this is.
    static let provisionalName = "New account"

    private static let personalDomains: Set<String> = [
        "aol.com", "duck.com", "fastmail.com", "gmail.com", "gmx.com", "googlemail.com", "hey.com",
        "hotmail.com", "icloud.com", "live.com", "mac.com", "me.com", "msn.com", "outlook.com",
        "pm.me", "proton.me", "protonmail.com", "yahoo.com", "yandex.com", "zoho.com",
        // Reserved documentation domains never name an organisation.
        "example.com", "example.net", "example.org",
    ]
    /// Second-level labels that sit in front of a country code, as in "acme.co.uk".
    private static let genericSecondLevels: Set<String> = ["ac", "co", "com", "edu", "gov", "net", "org"]

    /// "Personal" for a consumer mailbox, otherwise the organisation in the domain ("Acme" for
    /// ana@mail.acme.co.uk). A name already in use gets a number.
    static func suggestedName(for email: String, taken: [String], maximumLength: Int) -> String {
        let parts = email.lowercased().split(separator: "@", maxSplits: 1).map(String.init)
        var base = "Personal"
        if parts.count == 2, !personalDomains.contains(parts[1]) {
            var labels = parts[1].split(separator: ".").map(String.init)
            if labels.count > 1 { labels.removeLast() }
            if labels.count > 1, let last = labels.last, genericSecondLevels.contains(last) { labels.removeLast() }
            if let organisation = labels.last, !organisation.isEmpty {
                base = organisation.prefix(1).uppercased() + organisation.dropFirst()
            }
        }
        base = String(base.prefix(maximumLength - 3))
        let used = Set(taken.map { $0.lowercased() })
        guard used.contains(base.lowercased()) else { return base }
        var number = 2
        while used.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }
}

@MainActor
extension GuardAppModel {
    // MARK: Reading the flow

    /// The flow on screen, or nil for the account list. With no accounts the flow is always open.
    var activeEnrollment: EnrollmentFlow? {
        enrollment ?? (hasAccounts ? nil : EnrollmentFlow(step: .choose))
    }

    var enrollmentPhase: EnrollmentPhase? {
        guard let flow = activeEnrollment else { return nil }
        switch flow.step {
        case .choose:
            return .choose
        case let .starting(provider):
            return .waiting(provider, nil, checking: false)
        case let .couldNotStart(provider, message):
            return .problem(provider, nil, .failed(message))
        case let .signIn(ref):
            if let failure = flow.startFailure { return .problem(ref.provider, ref, .failed(failure)) }
            guard !flow.isStarting, let state = signInState(for: ref) else {
                return .waiting(ref.provider, ref, checking: false)
            }
            switch state {
            case .waiting: return .waiting(ref.provider, ref, checking: false)
            case .checking: return .waiting(ref.provider, ref, checking: true)
            case .connected: return .connected(ref)
            default: return .problem(ref.provider, ref, state)
            }
        }
    }

    func signInState(for ref: AccountRef) -> SignInState? {
        let raw = ref.id.uuidString.lowercased()
        switch ref.provider {
        case .codex: return profiles.first { $0.id == raw }?.signIn
        case .claude: return claudeProfiles.first { $0.id == raw }?.signIn
        }
    }

    /// The URL to reopen or copy while waiting: the flow's own, or the one Claude Code reported.
    func signInURL(for ref: AccountRef) -> URL? {
        if let url = enrollment?.signInURL { return url }
        guard ref.provider == .claude else { return nil }
        return claudeProfiles.first { $0.id == ref.id.uuidString.lowercased() }?.signInURL
    }

    /// Codex adds wait for its runtime to load; Claude reports its own unloaded state.
    func canAdd(_ provider: ProviderKind) -> Bool {
        !isReadOnly && (provider == .claude || isReady)
    }

    // MARK: Moving through the flow

    /// Saves a new account for the service and opens its browser sign-in. Whose account it is
    /// comes from that sign-in, so nothing is asked first.
    func startEnrollment(_ provider: ProviderKind) {
        guard canAdd(provider), !isAddingProfile else { return }
        enrollment = EnrollmentFlow(step: .starting(provider))
        if isPreview {
            simulateEnrollment(provider: provider)
            return
        }
        isAddingProfile = true
        switch provider {
        case .codex: onAddProfile?()
        case .claude: onAddClaudeProfile?()
        }
    }

    /// One step back: the service list to the accounts. Back from a sign-in cancels it and
    /// drops the unfinished account; from the result it is the same as Done.
    func enrollmentBack() {
        guard let flow = activeEnrollment, !isAddingProfile else { return }
        switch flow.step {
        case .choose, .couldNotStart:
            enrollment = hasAccounts ? nil : EnrollmentFlow(step: .choose)
        case .starting:
            break
        case let .signIn(ref):
            if signInState(for: ref) == .connected { finishEnrollment() } else { cancelEnrollment() }
        }
    }

    /// Called by a provider once the account is saved and its sign-in has started (or is about
    /// to: Claude Code opens the browser itself a moment later).
    func enrollmentDidStartSignIn(_ ref: AccountRef, url: URL?, awaitingStart: Bool) {
        var flow = activeEnrollment ?? EnrollmentFlow(step: .signIn(ref))
        flow.step = .signIn(ref)
        flow.signInURL = url
        flow.isStarting = awaitingStart
        flow.startFailure = nil
        flow.hasSettled = false
        enrollment = flow
        refreshSignIns()
    }

    /// The account was saved but its sign-in page could not be opened.
    func enrollmentDidFailToStart(_ ref: AccountRef, message: String) {
        var flow = activeEnrollment ?? EnrollmentFlow(step: .signIn(ref))
        flow.step = .signIn(ref)
        flow.isStarting = false
        flow.startFailure = message
        enrollment = flow
    }

    /// The account could not be saved at all.
    func enrollmentCouldNotStart(_ provider: ProviderKind, message: String) {
        enrollment = EnrollmentFlow(step: .couldNotStart(provider, message))
    }

    /// Try again after a problem: a fresh sign-in for the same new account, or a fresh start if
    /// none was saved. In a private window the link is copied rather than opened, so the
    /// browser's current account cannot answer for it.
    func retryEnrollment(inPrivateWindow: Bool = false) {
        guard var flow = enrollment else { return }
        switch flow.step {
        case let .couldNotStart(provider, _):
            startEnrollment(provider)
        case let .signIn(ref):
            flow.isStarting = true
            flow.startFailure = nil
            flow.hasSettled = false
            flow.signInURL = nil
            flow.usesPrivateWindow = inPrivateWindow
            flow.hasCopiedLink = false
            enrollment = flow
            if isPreview {
                simulateSignIn(ref)
                return
            }
            let raw = ref.id.uuidString.lowercased()
            switch ref.provider {
            case .codex: onReconnect?(raw)
            case .claude: onConnectClaude?(raw)
            }
        case .choose, .starting:
            break
        }
    }

    /// Stops the sign-in and drops the account it created, which the user never saw in the
    /// list. A failed removal leaves the account listed with its own Connect button.
    func cancelEnrollment() {
        guard let flow = activeEnrollment else { return }
        guard case let .signIn(ref) = flow.step else {
            enrollment = hasAccounts ? nil : EnrollmentFlow(step: .choose)
            return
        }
        let raw = ref.id.uuidString.lowercased()
        if ref.provider == .claude, signInState(for: ref)?.isUnderWay == true {
            onCancelClaudeSignIn?(raw)
        }
        let othersRemain = profiles.contains { $0.id != raw } || claudeProfiles.contains { $0.id != raw }
        enrollment = othersRemain ? nil : EnrollmentFlow(step: .choose)
        if isPreview {
            profiles.removeAll { $0.id == raw }
            claudeProfiles.removeAll { $0.id == raw }
            return
        }
        guard let discard = onDiscardUnfinishedAccount else { return }
        Task { @MainActor [weak self] in
            do {
                try await discard(ref)
            } catch {
                self?.reportActionFailure(
                    "Could not remove the unfinished account. \((error as? LocalizedError)?.errorDescription ?? "Remove it from its menu.")",
                    for: ref
                )
            }
        }
    }

    /// Puts the sign-in link on the clipboard for a private window.
    func copyPrivateWindowLink(_ url: URL) {
        if !isPreview { copySignInLink(url) }
        enrollment?.hasCopiedLink = true
    }

    /// Done: closes the flow and returns the new account so the list can highlight it.
    @discardableResult
    func finishEnrollment() -> AccountRef? {
        guard let flow = enrollment else { return nil }
        enrollment = nil
        if case let .signIn(ref) = flow.step { return ref }
        return nil
    }

    // MARK: Sign-ins settling

    /// Follows the flow's account and any row reconnects as snapshots arrive. Each settled
    /// sign-in is announced once, so the app can come back in front of the browser.
    func refreshSignIns() {
        if var flow = enrollment, case let .signIn(ref) = flow.step, let state = signInState(for: ref) {
            var announce = false
            if flow.isStarting, state.isUnderWay { flow.isStarting = false }
            if !flow.isStarting, flow.startFailure == nil {
                if state.isSettled, !flow.hasSettled {
                    flow.hasSettled = true
                    announce = true
                } else if state.isUnderWay {
                    flow.hasSettled = false
                }
            }
            // Claude Code opens its own browser tab; in a private window its link is copied as
            // soon as it is known.
            if flow.usesPrivateWindow, !flow.hasCopiedLink, state.isUnderWay, let url = signInURL(for: ref) {
                if !isPreview { copySignInLink(url) }
                flow.hasCopiedLink = true
            }
            if flow != enrollment { enrollment = flow }
            if announce { onSignInSettled?(ref, true) }
        }
        for (ref, sawStart) in pendingReconnects {
            guard let state = signInState(for: ref) else {
                pendingReconnects[ref] = nil
                continue
            }
            if state.isUnderWay {
                if !sawStart { pendingReconnects[ref] = true }
            } else if sawStart {
                pendingReconnects[ref] = nil
                onSignInSettled?(ref, false)
            }
        }
    }

    // MARK: Preview

    /// Preview only: walks the flow with synthetic accounts and never touches a provider.
    private func simulateEnrollment(provider: ProviderKind) {
        let ref = AccountRef(provider: provider, id: UUID())
        switch provider {
        case .codex:
            profiles.append(PreviewFixtures.enrollingCodex(ref.id, name: AccountNaming.provisionalName, hint: "Expected Codex account"))
        case .claude:
            claudeProfiles.append(PreviewFixtures.enrollingClaude(ref.id, name: AccountNaming.provisionalName, hint: "Claude account"))
        }
        enrollmentDidStartSignIn(ref, url: PreviewFixtures.signInURL(for: provider), awaitingStart: false)
        simulateSignIn(ref)
    }

    private func simulateSignIn(_ ref: AccountRef) {
        let raw = ref.id.uuidString.lowercased()
        switch ref.provider {
        case .codex:
            if let index = profiles.firstIndex(where: { $0.id == raw }) { profiles[index].signIn = .waiting }
        case .claude:
            if let index = claudeProfiles.firstIndex(where: { $0.id == raw }) { claudeProfiles[index].signIn = .waiting }
        }
        if var flow = enrollment, case .signIn(ref) = flow.step {
            flow.signInURL = PreviewFixtures.signInURL(for: ref.provider)
            flow.hasCopiedLink = flow.usesPrivateWindow
            enrollment = flow
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard let self, self.signInState(for: ref) == .waiting else { return }
            self.lastCheckedAt = self.referenceDate ?? Date()
            let email = ref.provider == .codex ? "sample@gmail.com" : "you@studio.example"
            switch ref.provider {
            case .codex:
                if let index = self.profiles.firstIndex(where: { $0.id == raw }) {
                    let taken = self.profiles.filter { $0.id != raw }.map(\.displayName)
                    self.profiles[index] = PreviewFixtures.connectedCodex(self.profiles[index], email: email, taken: taken)
                }
            case .claude:
                if let index = self.claudeProfiles.firstIndex(where: { $0.id == raw }) {
                    let taken = self.claudeProfiles.filter { $0.id != raw }.map(\.displayName)
                    self.claudeProfiles[index] = PreviewFixtures.connectedClaude(self.claudeProfiles[index], email: email, taken: taken)
                }
            }
        }
    }
}
