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
    case wrongAccount(found: String?)
    /// Claude only: the sign-in has no Pro or Max plan, so there are no limits to read.
    case noPlan
    case failed(String)

    /// Finished one way or the other, so the user has a result to read or a decision to make.
    var isSettled: Bool {
        switch self {
        case .waiting, .checking: false
        case .connected, .signedOut, .wrongAccount, .noPlan, .failed: true
        }
    }

    var isUnderWay: Bool { !isSettled }
}

/// The add-account flow. It lives on the model, not the view, because the popover closes as
/// soon as the browser takes focus and must reopen on the same step.
struct EnrollmentFlow: Equatable {
    enum Step: Equatable {
        case choose
        case email(ProviderKind)
        case signIn(AccountRef)
    }

    var step: Step
    /// The address being added, shown in full while signing in: the one line that prevents a
    /// sign-in with the browser's other account.
    var email = ""
    /// Codex returns its sign-in page; Claude Code reports its own once it has opened it.
    var signInURL: URL?
    /// From Continue or Try again until the account reports a sign-in under way, so the
    /// signed-out state it starts in never reads as a failure.
    var isStarting = false
    /// The sign-in page could not be opened at all.
    var startFailure: String?
    /// The popover reopens once per settled sign-in, not on every later snapshot.
    var hasSettled = false

    var hasStartedSignIn: Bool {
        if case .signIn = step { return true }
        return false
    }
}

/// What the flow shows, derived from its step and the account's live sign-in state.
enum EnrollmentPhase: Equatable {
    case choose
    case email(ProviderKind)
    case waiting(AccountRef, checking: Bool)
    case connected(AccountRef)
    case problem(AccountRef, SignInState)

    var account: AccountRef? {
        switch self {
        case .choose, .email: nil
        case let .waiting(ref, _), let .connected(ref), let .problem(ref, _): ref
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

/// A starting name for a new account, so enrollment asks for one field instead of two.
enum AccountNaming {
    private static let personalDomains: Set<String> = [
        "aol.com", "duck.com", "fastmail.com", "gmail.com", "gmx.com", "googlemail.com", "hey.com",
        "hotmail.com", "icloud.com", "live.com", "mac.com", "me.com", "msn.com", "outlook.com",
        "pm.me", "proton.me", "protonmail.com", "yahoo.com", "yandex.com", "zoho.com",
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
        case let .email(provider):
            return .email(provider)
        case let .signIn(ref):
            if let failure = flow.startFailure { return .problem(ref, .failed(failure)) }
            guard !flow.isStarting, let state = signInState(for: ref) else {
                return .waiting(ref, checking: false)
            }
            switch state {
            case .waiting: return .waiting(ref, checking: false)
            case .checking: return .waiting(ref, checking: true)
            case .connected: return .connected(ref)
            default: return .problem(ref, state)
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

    func beginEnrollment() {
        guard !isReadOnly else { return }
        enrollmentError = nil
        enrollment = EnrollmentFlow(step: .choose)
    }

    func chooseEnrollmentProvider(_ provider: ProviderKind) {
        guard !isReadOnly else { return }
        enrollmentError = nil
        var flow = activeEnrollment ?? EnrollmentFlow(step: .choose)
        flow.step = .email(provider)
        enrollment = flow
    }

    /// One step back: email to the service list, the list to the accounts.
    func enrollmentBack() {
        guard let flow = activeEnrollment, !isAddingProfile else { return }
        enrollmentError = nil
        switch flow.step {
        case .email:
            enrollment = EnrollmentFlow(step: .choose)
        case .choose:
            enrollment = nil
        case let .signIn(ref):
            // Back from a sign-in drops the unfinished account and keeps the typed email.
            if signInState(for: ref) != .connected { cancelEnrollment(returningTo: ref.provider) }
        }
    }

    /// Continue: saves the account under a suggested name and opens its browser sign-in.
    func addProfile() {
        guard !isAddingProfile, !isReadOnly else { return }
        let provider: ProviderKind = if case let .email(provider)? = activeEnrollment?.step { provider } else { .codex }
        guard canAdd(provider) else { return }
        guard MonitorPersistence.isValidEmail(profileEmail) else {
            enrollmentError = "Enter a full email address, like you@example.com."
            return
        }
        let email = MonitorPersistence.normalizedEmail(profileEmail)
        let taken = provider == .codex ? profiles.map(\.displayName) : claudeProfiles.map(\.displayName)
        let name = AccountNaming.suggestedName(
            for: email,
            taken: taken,
            maximumLength: GuardInterfaceModel.maximumNameLength(for: provider)
        )
        enrollmentError = nil
        var flow = activeEnrollment ?? EnrollmentFlow(step: .email(provider))
        flow.email = email
        enrollment = flow
        if isPreview {
            simulateEnrollment(provider: provider, email: email, name: name)
            return
        }
        isAddingProfile = true
        switch provider {
        case .codex: onAddProfile?(email, name)
        case .claude: onAddClaudeProfile?(email, name)
        }
    }

    /// Called by a provider once the account is saved and its sign-in has started (or is about
    /// to: Claude Code opens the browser itself a moment later).
    func enrollmentDidStartSignIn(_ ref: AccountRef, url: URL?, awaitingStart: Bool) {
        profileEmail = ""
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
        profileEmail = ""
        var flow = activeEnrollment ?? EnrollmentFlow(step: .signIn(ref))
        flow.step = .signIn(ref)
        flow.isStarting = false
        flow.startFailure = message
        enrollment = flow
    }

    /// A fresh sign-in for the flow's account after a problem.
    func retryEnrollmentSignIn() {
        guard var flow = enrollment, case let .signIn(ref) = flow.step else { return }
        flow.isStarting = true
        flow.startFailure = nil
        flow.hasSettled = false
        flow.signInURL = nil
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
    }

    /// Stops the sign-in and drops the account it created, which the user never saw in the
    /// list. A failed removal leaves the account listed with its own Connect button.
    func cancelEnrollment(returningTo provider: ProviderKind? = nil) {
        guard let flow = activeEnrollment else { return }
        enrollmentError = nil
        guard case let .signIn(ref) = flow.step else {
            enrollment = hasAccounts ? nil : EnrollmentFlow(step: .choose)
            return
        }
        let raw = ref.id.uuidString.lowercased()
        if ref.provider == .claude, signInState(for: ref)?.isUnderWay == true {
            onCancelClaudeSignIn?(raw)
        }
        let othersRemain = profiles.contains { $0.id != raw } || claudeProfiles.contains { $0.id != raw }
        if let provider {
            profileEmail = flow.email
            enrollment = EnrollmentFlow(step: .email(provider))
        } else {
            enrollment = othersRemain ? nil : EnrollmentFlow(step: .choose)
        }
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

    /// The sign-in came back as another Claude account the user may want instead: drop the
    /// unfinished one and add that account. Its browser session is already signed in.
    func adoptSignedInAccount(_ email: String) {
        guard case let .signIn(ref)? = enrollment?.step else { return }
        cancelEnrollment(returningTo: ref.provider)
        profileEmail = email
        addProfile()
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
    private func simulateEnrollment(provider: ProviderKind, email: String, name: String) {
        let ref = AccountRef(provider: provider, id: UUID())
        let hint = PreviewFixtures.maskedHint(email)
        switch provider {
        case .codex:
            profiles.append(PreviewFixtures.enrollingCodex(ref.id, name: name, hint: hint))
        case .claude:
            claudeProfiles.append(PreviewFixtures.enrollingClaude(ref.id, name: name, hint: hint))
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
            enrollment = flow
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard let self, self.signInState(for: ref) == .waiting else { return }
            switch ref.provider {
            case .codex:
                if let index = self.profiles.firstIndex(where: { $0.id == raw }) {
                    self.profiles[index] = PreviewFixtures.connectedCodex(self.profiles[index])
                }
            case .claude:
                if let index = self.claudeProfiles.firstIndex(where: { $0.id == raw }) {
                    self.claudeProfiles[index] = PreviewFixtures.connectedClaude(self.claudeProfiles[index])
                }
            }
        }
    }
}
