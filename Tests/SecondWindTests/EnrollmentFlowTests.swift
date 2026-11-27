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
    model.chooseEnrollmentProvider(.claude)
    #expect(model.enrollmentPhase == .email(.claude))
    model.enrollmentBack()
    #expect(model.enrollmentPhase == .choose)
    model.enrollmentBack()
    #expect(model.enrollmentPhase == .choose)
}

@Test @MainActor func addingWithAccountsOpensOnTheEmailStepAndBacksOutToTheList() {
    let model = liveModel(profiles: [codexAccount(signIn: .connected)])
    #expect(model.enrollmentPhase == nil)
    // The footer menu names the service, so the list of services is skipped.
    model.chooseEnrollmentProvider(.claude)
    #expect(model.enrollmentPhase == .email(.claude))
    model.enrollmentBack()
    #expect(model.enrollmentPhase == nil)
}

@Test @MainActor func continueSendsTheEmailAndASuggestedNameToTheChosenService() {
    let model = liveModel()
    var codexCalls = 0
    var claudeCall: (String, String)?
    model.onAddProfile = { _, _ in codexCalls += 1 }
    model.onAddClaudeProfile = { claudeCall = ($0, $1) }
    model.chooseEnrollmentProvider(.claude)
    model.profileEmail = "  Ana@Acme.com "
    model.addProfile()
    #expect(codexCalls == 0)
    #expect(claudeCall?.0 == "ana@acme.com")
    #expect(claudeCall?.1 == "Acme")
    #expect(model.isAddingProfile)
    #expect(model.enrollment?.email == "ana@acme.com")
}

@Test @MainActor func anInvalidEmailStaysOnTheEmailStep() {
    let model = liveModel()
    var calls = 0
    model.onAddProfile = { _, _ in calls += 1 }
    model.chooseEnrollmentProvider(.codex)
    model.profileEmail = "sample@"
    model.addProfile()
    #expect(calls == 0)
    #expect(model.enrollmentError != nil)
    #expect(model.enrollmentPhase == .email(.codex))
}

@Test @MainActor func claudeReadsAsWaitingUntilItsSignInStartsAndAnnouncesTheResultOnce() {
    let model = liveModel(claudeProfiles: [claudeAccount(signIn: .signedOut)])
    var announcements: [(AccountRef, Bool)] = []
    model.onSignInSettled = { announcements.append(($0, $1)) }
    model.chooseEnrollmentProvider(.claude)
    model.enrollmentDidStartSignIn(claudeRef, url: nil, awaitingStart: true)
    // Saved but not yet signing in: never a failure.
    #expect(model.enrollmentPhase == .waiting(claudeRef, checking: false))
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

@Test @MainActor func aWrongAccountOffersARetryThatStartsAFreshSignIn() {
    let model = liveModel(profiles: [codexAccount(signIn: .waiting)])
    var reconnects: [String] = []
    model.onReconnect = { reconnects.append($0) }
    model.enrollmentDidStartSignIn(codexRef, url: URL(string: "https://auth.example.com/start"), awaitingStart: false)
    #expect(model.signInURL(for: codexRef)?.host == "auth.example.com")
    model.profiles = [codexAccount(signIn: .wrongAccount(found: nil))]
    #expect(model.enrollmentPhase == .problem(codexRef, .wrongAccount(found: nil)))

    model.retryEnrollmentSignIn()
    #expect(reconnects == [codexRef.id.uuidString.lowercased()])
    // The stale result is not shown again while the new sign-in starts.
    #expect(model.enrollmentPhase == .waiting(codexRef, checking: false))
    #expect(model.signInURL(for: codexRef) == nil)
}

@Test @MainActor func aSignInPageThatNeverOpenedIsAProblemNotAWait() {
    let model = liveModel(profiles: [codexAccount(signIn: .signedOut)])
    model.enrollmentDidFailToStart(codexRef, message: "Could not open the Codex sign-in page.")
    #expect(model.enrollmentPhase == .problem(codexRef, .failed("Could not open the Codex sign-in page.")))
}

@Test @MainActor func cancellingStopsTheSignInAndDiscardsTheUnfinishedAccount() async {
    let model = liveModel(claudeProfiles: [claudeAccount(signIn: .waiting)])
    var cancelled: [String] = []
    var discarded: [AccountRef] = []
    model.onCancelClaudeSignIn = { cancelled.append($0) }
    model.onDiscardUnfinishedAccount = { discarded.append($0) }
    model.enrollmentDidStartSignIn(claudeRef, url: nil, awaitingStart: false)
    model.cancelEnrollment()
    #expect(cancelled == [claudeRef.id.uuidString.lowercased()])
    // With no other account the flow goes back to the start, not to an empty list.
    #expect(model.enrollment == EnrollmentFlow(step: .choose))
    await settle { !discarded.isEmpty }
    #expect(discarded == [claudeRef])
}

@Test @MainActor func usingADifferentEmailReturnsToTheEmailStepPrefilled() async {
    let model = liveModel(
        profiles: [codexAccount(codexRef, signIn: .connected)],
        claudeProfiles: [claudeAccount(signIn: .noPlan)]
    )
    var discarded: [AccountRef] = []
    model.onDiscardUnfinishedAccount = { discarded.append($0) }
    model.chooseEnrollmentProvider(.claude)
    model.profileEmail = "studio@example.com"
    model.enrollmentDidStartSignIn(claudeRef, url: nil, awaitingStart: false)
    model.enrollment?.email = "studio@example.com"
    #expect(model.enrollmentPhase == .problem(claudeRef, .noPlan))
    model.cancelEnrollment(returningTo: .claude)
    #expect(model.enrollmentPhase == .email(.claude))
    #expect(model.profileEmail == "studio@example.com")
    await settle { !discarded.isEmpty }
    #expect(discarded == [claudeRef])
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
    model.onAddProfile = { _, _ in liveCalls += 1 }
    model.onAddClaudeProfile = { _, _ in liveCalls += 1 }
    model.onDiscardUnfinishedAccount = { _ in liveCalls += 1 }
    model.chooseEnrollmentProvider(.codex)
    model.profileEmail = "sample@gmail.com"
    model.addProfile()
    guard case let .waiting(ref, _)? = model.enrollmentPhase else {
        Issue.record("Expected the preview to wait for a synthetic sign-in")
        return
    }
    #expect(model.profiles.first?.displayName == "Personal")
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
}

@Test @MainActor func claudeCanBeAddedWhileCodexIsStillLoading() {
    let model = GuardAppModel()
    var claudeCalls = 0
    var codexCalls = 0
    model.onAddClaudeProfile = { _, _ in claudeCalls += 1 }
    model.onAddProfile = { _, _ in codexCalls += 1 }
    model.chooseEnrollmentProvider(.codex)
    model.profileEmail = "sample@gmail.com"
    model.addProfile()
    #expect(codexCalls == 0)
    model.chooseEnrollmentProvider(.claude)
    model.addProfile()
    #expect(claudeCalls == 1)
}

@Test func codexPlanNamesReadAsBadges() {
    #expect(GuardRuntimeController.planName("plus") == "Plus")
    #expect(GuardRuntimeController.planName(" PRO ") == "Pro")
    #expect(GuardRuntimeController.planName("self_serve_business") == "Self Serve Business")
    #expect(GuardRuntimeController.planName("unknown") == nil)
    #expect(GuardRuntimeController.planName(nil) == nil)
}
