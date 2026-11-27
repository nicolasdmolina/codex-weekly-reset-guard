import Foundation
import Testing
@testable import SecondWind
@testable import SecondWindCore

// The add-account flow: suggested names, step navigation, sign-in progress, and the
// reopen-once announcement. Synthetic accounts only; no provider is started.

private let codexRef = AccountRef(provider: .codex, id: UUID(uuidString: "C0DE0000-0000-4000-8000-0000000000E1")!)
private let claudeRef = AccountRef(provider: .claude, id: UUID(uuidString: "C1A0DE00-0000-4000-8000-0000000000E1")!)

private func codexAccount(_ ref: AccountRef = codexRef, signIn: SignInState) -> GuardProfilePresentation {
    var profile = GuardProfilePresentation(
        id: ref.id.uuidString.lowercased(), displayName: "Personal", accountHint: "p•••@example.com",
        weeklyRemainingPercent: nil, naturalResetAt: nil, availableResetCount: 0, nearestResetExpiry: nil,
        status: .disconnected, detail: "", autoResetEnabled: false, identityVerified: false
    )
    profile.signIn = signIn
    return profile
}

private func claudeAccount(_ ref: AccountRef = claudeRef, signIn: SignInState) -> ClaudeProfilePresentation {
    ClaudeProfilePresentation(
        id: ref.id.uuidString.lowercased(), displayName: "Studio", accountHint: "s•••@example.com",
        planName: nil, windows: [], status: .signingIn, detail: "", signInURL: nil, signIn: signIn
    )
}

@MainActor
private func liveModel(
    profiles: [GuardProfilePresentation] = [],
    claudeProfiles: [ClaudeProfilePresentation] = []
) -> GuardAppModel {
    let model = GuardAppModel(profiles: profiles, claudeProfiles: claudeProfiles)
    model.isReady = true
    return model
}

@MainActor
private func settle(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
}

@Test func suggestedNamesFollowTheMailbox() {
    func name(_ email: String, _ taken: [String] = []) -> String {
        AccountNaming.suggestedName(for: email, taken: taken, maximumLength: 48)
    }
    #expect(name("sample@gmail.com") == "Personal")
    #expect(name("ana@acme.com") == "Acme")
    #expect(name("ana@mail.acme.co.uk") == "Acme")
    #expect(name("sample@icloud.com", ["Personal"]) == "Personal 2")
    #expect(name("sample@icloud.com", ["personal", "Personal 2"]) == "Personal 3")
}

@Test @MainActor func firstRunOpensOnTheServiceListAndCannotBackOutOfIt() {
    let model = liveModel()
    #expect(model.enrollmentPhase == .choose)
    model.enrollmentBack()
    #expect(model.enrollmentPhase == .choose)
}

@Test @MainActor func choosingAServiceStartsItsSignInWithoutAskingAnything() {
    let model = liveModel()
    var codexCalls = 0
    var claudeCalls = 0
    model.onAddProfile = { codexCalls += 1 }
    model.onAddClaudeProfile = { claudeCalls += 1 }
    model.startEnrollment(.claude)
    #expect(codexCalls == 0)
    #expect(claudeCalls == 1)
    #expect(model.isAddingProfile)
    // Saving: the browser is about to open, and there is nothing to go back to yet.
    #expect(model.enrollmentPhase == .waiting(.claude, nil, checking: false))
    model.startEnrollment(.claude)
    #expect(claudeCalls == 1, "A second press while saving starts nothing")
}

@Test @MainActor func anAccountThatCouldNotBeSavedOffersAFreshStart() {
    let model = liveModel(profiles: [codexAccount(signIn: .connected)])
    var calls = 0
    model.onAddProfile = { calls += 1 }
    model.startEnrollment(.codex)
    model.isAddingProfile = false
    model.enrollmentCouldNotStart(.codex, message: "Could not save the new account.")
    #expect(model.enrollmentPhase == .problem(.codex, nil, .failed("Could not save the new account.")))
    model.retryEnrollment()
    #expect(calls == 2)
    model.isAddingProfile = false
    model.enrollmentCouldNotStart(.codex, message: "Could not save the new account.")
    model.enrollmentBack()
    #expect(model.enrollmentPhase == nil, "With accounts listed, back returns to the list")
}

@Test @MainActor func claudeReadsAsWaitingUntilItsSignInStartsAndAnnouncesTheResultOnce() {
    let model = liveModel(claudeProfiles: [claudeAccount(signIn: .signedOut)])
    var announcements: [(AccountRef, Bool)] = []
    model.onSignInSettled = { announcements.append(($0, $1)) }
    model.enrollment = EnrollmentFlow(step: .starting(.claude))
    model.enrollmentDidStartSignIn(claudeRef, url: nil, awaitingStart: true)
    // Saved but not yet signing in: never a failure.
    #expect(model.enrollmentPhase == .waiting(.claude, claudeRef, checking: false))
    #expect(announcements.isEmpty)

    model.claudeProfiles = [claudeAccount(signIn: .waiting)]
    #expect(model.enrollment?.isStarting == false)
    model.claudeProfiles = [claudeAccount(signIn: .connected)]
    #expect(model.enrollmentPhase == .connected(claudeRef))
    model.claudeProfiles = [claudeAccount(signIn: .connected)]
    #expect(announcements.count == 1)
    #expect(announcements.first?.0 == claudeRef)
    #expect(announcements.first?.1 == true)

    #expect(model.finishEnrollment() == claudeRef)
    #expect(model.enrollmentPhase == nil)
}

@Test @MainActor func anAccountAlreadyWatchedOffersAFreshSignIn() {
    let model = liveModel(profiles: [codexAccount(signIn: .waiting)])
    var reconnects: [String] = []
    model.onReconnect = { reconnects.append($0) }
    model.enrollmentDidStartSignIn(codexRef, url: URL(string: "https://auth.example.com/start"), awaitingStart: false)
    #expect(model.signInURL(for: codexRef)?.host == "auth.example.com")
    model.profiles = [codexAccount(signIn: .alreadyAdded(found: nil))]
    #expect(model.enrollmentPhase == .problem(.codex, codexRef, .alreadyAdded(found: nil)))

    model.retryEnrollment()
    #expect(reconnects == [codexRef.id.uuidString.lowercased()])
    // The stale result is not shown again while the new sign-in starts.
    #expect(model.enrollmentPhase == .waiting(.codex, codexRef, checking: false))
    #expect(model.signInURL(for: codexRef) == nil)
}

@Test @MainActor func aSignInPageThatNeverOpenedIsAProblemNotAWait() {
    let model = liveModel(profiles: [codexAccount(signIn: .signedOut)])
    model.enrollmentDidFailToStart(codexRef, message: "Could not open the Codex sign-in page.")
    #expect(model.enrollmentPhase == .problem(.codex, codexRef, .failed("Could not open the Codex sign-in page.")))
}

@Test @MainActor func backDuringASignInStopsItAndDiscardsTheUnfinishedAccount() async {
    let model = liveModel(claudeProfiles: [claudeAccount(signIn: .waiting)])
    var cancelled: [String] = []
    var discarded: [AccountRef] = []
    model.onCancelClaudeSignIn = { cancelled.append($0) }
    model.onDiscardUnfinishedAccount = { discarded.append($0) }
    model.enrollmentDidStartSignIn(claudeRef, url: nil, awaitingStart: false)
    model.enrollmentBack()
    #expect(cancelled == [claudeRef.id.uuidString.lowercased()])
    // With no other account the flow goes back to the start, not to an empty list.
    #expect(model.enrollment == EnrollmentFlow(step: .choose))
    await settle { !discarded.isEmpty }
    #expect(discarded == [claudeRef])
}

@Test @MainActor func backFromTheResultIsDone() {
    let model = liveModel(profiles: [codexAccount(signIn: .connected)])
    var discarded = 0
    model.onDiscardUnfinishedAccount = { _ in discarded += 1 }
    model.enrollmentDidStartSignIn(codexRef, url: nil, awaitingStart: false)
    #expect(model.enrollmentPhase == .connected(codexRef))
    model.enrollmentBack()
    #expect(model.enrollmentPhase == nil)
    #expect(discarded == 0, "A connected account is kept")
}

@Test @MainActor func aRowReconnectAnnouncesOnlyAfterItsSignInWasSeenUnderWay() {
    let model = liveModel(profiles: [codexAccount(signIn: .signedOut)])
    var announcements: [(AccountRef, Bool)] = []
    model.onSignInSettled = { announcements.append(($0, $1)) }
    model.onReconnect = { _ in }
    model.reconnect(profileID: codexRef.id.uuidString.lowercased())
    model.profiles = [codexAccount(signIn: .signedOut)]
    #expect(announcements.isEmpty)
    model.profiles = [codexAccount(signIn: .waiting)]
    model.profiles = [codexAccount(signIn: .connected)]
    model.profiles = [codexAccount(signIn: .connected)]
    #expect(announcements.count == 1)
    #expect(announcements.first?.0 == codexRef)
    #expect(announcements.first?.1 == false)
}

@Test @MainActor func previewEnrollmentWalksTheFlowWithoutAProvider() {
    let model = PreviewFixtures.model(for: .onboarding)
    var liveCalls = 0
    model.onAddProfile = { liveCalls += 1 }
    model.onAddClaudeProfile = { liveCalls += 1 }
    model.onDiscardUnfinishedAccount = { _ in liveCalls += 1 }
    model.startEnrollment(.codex)
    guard case let .waiting(_, ref?, _)? = model.enrollmentPhase else {
        Issue.record("Expected the preview to wait for a synthetic sign-in")
        return
    }
    #expect(model.profiles.first?.displayName == AccountNaming.provisionalName)
    model.cancelEnrollment()
    #expect(model.signInState(for: ref) == nil)
    #expect(model.enrollmentPhase == .choose)
    #expect(liveCalls == 0)
}

@Test @MainActor func claudeConnectionStatesMapToSignInStates() {
    func state(_ status: ClaudeConnectionStatus) -> SignInState {
        let id = UUID()
        let snapshot = ClaudeProfileSnapshot(
            id: id, displayName: "Studio", expectedEmail: "studio@example.com", planName: nil, report: nil,
            status: status, signInURL: nil, quota: QuotaAccountRecord(provider: .claude, accountID: id)
        )
        return GuardAppModel.presentation(for: snapshot, at: Date()).signIn
    }
    #expect(state(.signingIn) == .waiting)
    #expect(state(.verified) == .connected)
    #expect(state(.notSignedIn) == .signedOut)
    #expect(state(.identityMismatch(found: "other@example.com")) == .wrongAccount(found: "other@example.com"))
    #expect(state(.notSubscription) == .noPlan)
    #expect(state(.duplicate(found: "other@example.com")) == .alreadyAdded(found: "other@example.com"))
}

@Test @MainActor func claudeCanBeAddedWhileCodexIsStillLoading() {
    let model = GuardAppModel()
    var claudeCalls = 0
    var codexCalls = 0
    model.onAddClaudeProfile = { claudeCalls += 1 }
    model.onAddProfile = { codexCalls += 1 }
    model.startEnrollment(.codex)
    #expect(codexCalls == 0)
    model.startEnrollment(.claude)
    #expect(claudeCalls == 1)
}

@Test func codexPlanNamesReadAsBadges() {
    #expect(GuardRuntimeController.planName("plus") == "Plus")
    #expect(GuardRuntimeController.planName(" PRO ") == "Pro")
    #expect(GuardRuntimeController.planName("self_serve_business") == "Self Serve Business")
    #expect(GuardRuntimeController.planName("unknown") == nil)
    #expect(GuardRuntimeController.planName(nil) == nil)
}

@Test @MainActor func anAlreadyAddedAccountRetriesInAPrivateWindowWithTheLinkCopied() {
    let model = liveModel(profiles: [codexAccount(signIn: .alreadyAdded(found: nil))])
    var copied: [URL] = []
    var reconnects: [String] = []
    model.copySignInLink = { copied.append($0) }
    model.onReconnect = { reconnects.append($0) }
    model.enrollmentDidStartSignIn(codexRef, url: nil, awaitingStart: false)
    #expect(model.enrollmentPhase == .problem(.codex, codexRef, .alreadyAdded(found: nil)))

    model.retryEnrollment(inPrivateWindow: true)
    #expect(reconnects.count == 1)
    #expect(model.enrollment?.usesPrivateWindow == true)
    // The Codex wiring reports the fresh link and copies it instead of opening it.
    let link = URL(string: "https://auth.example.com/fresh")!
    model.enrollmentDidStartSignIn(codexRef, url: link, awaitingStart: false)
    model.copyPrivateWindowLink(link)
    #expect(copied == [link])
    #expect(model.enrollment?.hasCopiedLink == true)

    // Trying again in the same browser goes back to opening the link.
    model.retryEnrollment()
    #expect(model.enrollment?.usesPrivateWindow == false)
}

@Test @MainActor func claudeCopiesItsOwnLinkForAPrivateWindowOnceKnown() {
    var account = claudeAccount(signIn: .alreadyAdded(found: "studio@example.com"))
    let model = liveModel(claudeProfiles: [account])
    var copied: [URL] = []
    model.copySignInLink = { copied.append($0) }
    model.onConnectClaude = { _ in }
    model.enrollmentDidStartSignIn(claudeRef, url: nil, awaitingStart: false)
    model.retryEnrollment(inPrivateWindow: true)
    account.signIn = .waiting
    model.claudeProfiles = [account]
    #expect(copied.isEmpty, "Nothing to copy until Claude Code reports its link")
    account.signInURL = URL(string: "https://claude.ai/oauth/authorize?x=1")
    model.claudeProfiles = [account]
    model.claudeProfiles = [account]
    #expect(copied.count == 1)
}

@Test @MainActor func aSignInThatEndsUnfinishedDoesNotTakeFocus() {
    let model = liveModel(profiles: [codexAccount(signIn: .waiting)])
    var announcements = 0
    model.onSignInSettled = { _, _ in announcements += 1 }
    model.enrollmentDidStartSignIn(codexRef, url: nil, awaitingStart: false)
    model.profiles = [codexAccount(signIn: .signedOut)]
    #expect(model.enrollmentPhase == .problem(.codex, codexRef, .signedOut), "The next click still shows it")
    #expect(announcements == 0)
    model.profiles = [codexAccount(signIn: .alreadyAdded(found: nil))]
    model.retryEnrollment()
    model.profiles = [codexAccount(signIn: .waiting)]
    model.profiles = [codexAccount(signIn: .alreadyAdded(found: nil))]
    #expect(announcements == 1, "A result the user must act on still comes forward")
}
