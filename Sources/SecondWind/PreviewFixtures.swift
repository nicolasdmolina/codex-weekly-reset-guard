import AppKit
import Foundation
import SecondWindCore
import SwiftUI

enum PreviewKind: String, CaseIterable {
    case onboarding
    case onboardingError = "onboarding-error"
    case connect
    case paused
    case healthy
    case near
    case redeemed
    case authError = "auth-error"
    case overview
    case claudeLow = "claude-low"
    case claudeSignIn = "claude-signin"
    /// A used-up 5-hour window beside a healthy week, and a 1% week with
    /// Auto-redeem off and no 5-hour window reported.
    case monitorLow = "monitor-low"
    /// One current account, one whose reset time passed after its last
    /// reading, one stale Claude account. No "all clear".
    case freshness
    /// Saved resets with an expiry beside the renewal time, and an unknown count.
    case inventory
    /// The overview counted as used, with clock times.
    case usedExact = "used-exact"
    /// Settings with alerts on and a sent test.
    case settings
    /// Notifications off in System Settings while an alert is on.
    case settingsDenied = "settings-denied"
    /// Inline rename after a failed save.
    case rename
    /// Inline removal confirmation after a failed attempt.
    case remove
    /// A notification opened an account that needs a fix; another target is gone.
    case reveal
    /// Claude accounts failed to load at launch while Codex kept running.
    case providerFailed = "provider-failed"
    /// Codex blocked ordinary usage at healthy percentages; another account's access is unknown.
    case usageBlocked = "usage-blocked"
    /// Adding a second account: the service list under the Add account header.
    case addChoose = "add-choose"
    /// The Claude email step, filled in.
    case addEmail = "add-email"
    /// A new Codex account waiting on its browser sign-in.
    case addWaiting = "add-waiting"
    /// A Claude sign-in that came back as a different account.
    case addWrongAccount = "add-wrong-account"
    /// A new Codex account connected, with its first reading and Auto-redeem still off.
    case addConnected = "add-connected"
    /// A new Claude Max account connected, with its plan and three limits.
    case addConnectedClaude = "add-connected-claude"
}

@MainActor
enum PreviewFixtures {
    /// Interface state paired with each preview model, so `--preview <kind>` opens the same
    /// page, editor and preferences as its static render.
    private static var interfaces: [ObjectIdentifier: GuardInterfaceModel] = [:]

    static func interface(for model: GuardAppModel) -> GuardInterfaceModel {
        interfaces[ObjectIdentifier(model)] ?? GuardInterfaceModel(
            isPreview: true,
            isReadOnly: model.isReadOnly,
            preferenceDefaults: nil
        )
    }

    /// Every relative label in every fixture is measured from this instant.
    nonisolated static let reference = Date(timeIntervalSince1970: 1_785_300_000)

    enum ID {
        static let personal = UUID(uuidString: "C0DE0000-0000-4000-8000-000000000001")!
        static let work = UUID(uuidString: "C0DE0000-0000-4000-8000-000000000002")!
        static let studio = UUID(uuidString: "C1A0DE00-0000-4000-8000-000000000001")!
        static let removed = UUID(uuidString: "C0DE0000-0000-4000-8000-0000000000FF")!
    }

    static func model(for kind: PreviewKind) -> GuardAppModel {
        let (model, interface) = scene(for: kind)
        if model.hasAccounts { model.lastCheckedAt = reference }
        interfaces[ObjectIdentifier(model)] = interface
        return model
    }

    private static func scene(for kind: PreviewKind) -> (GuardAppModel, GuardInterfaceModel) {
        let reference = Self.reference
        var preferences = DisplayPreferences()
        var permission = NotificationPermissionStatus.allowed
        var alerts = AlertPreferences.off
        var stage: (GuardInterfaceModel) -> Void = { _ in }
        let model: GuardAppModel

        switch kind {
        case .onboarding:
            model = GuardAppModel(isPreview: true, referenceDate: reference)
        case .onboardingError:
            model = GuardAppModel(isPreview: true, referenceDate: reference)
            model.enrollment = EnrollmentFlow(step: .email(.codex))
            model.profileEmail = "nicky@example"
            model.enrollmentError = "Enter a full email address, like you@example.com."
        case .addChoose:
            model = GuardAppModel(profiles: [personalHealthy()], isPreview: true, referenceDate: reference)
            model.enrollment = EnrollmentFlow(step: .choose)
        case .addEmail:
            model = GuardAppModel(isPreview: true, referenceDate: reference)
            model.enrollment = EnrollmentFlow(step: .email(.claude))
            model.profileEmail = "studio@example.com"
        case .addWaiting:
            var enrolling = enrollingCodex(ID.personal, name: "Personal", hint: "p•••@example.com")
            enrolling.signIn = .waiting
            model = GuardAppModel(profiles: [enrolling], isPreview: true, referenceDate: reference)
            model.enrollment = EnrollmentFlow(
                step: .signIn(AccountRef(provider: .codex, id: ID.personal)),
                email: "personal@example.com",
                signInURL: signInURL(for: .codex)
            )
        case .addWrongAccount:
            var enrolling = enrollingClaude(ID.studio, name: "Studio", hint: "s•••@example.com")
            enrolling.status = .attention
            enrolling.detail = "Signed in as someone@example.org. Reconnect with the expected account."
            enrolling.signIn = .wrongAccount(found: "someone@example.org")
            model = GuardAppModel(profiles: [personalHealthy()], claudeProfiles: [enrolling], isPreview: true, referenceDate: reference)
            model.enrollment = EnrollmentFlow(
                step: .signIn(AccountRef(provider: .claude, id: ID.studio)),
                email: "studio@example.com",
                hasSettled: true
            )
        case .addConnected:
            model = GuardAppModel(
                profiles: [connectedCodex(enrollingCodex(ID.personal, name: "Personal", hint: "p•••@example.com"))],
                isPreview: true,
                referenceDate: reference
            )
            model.enrollment = EnrollmentFlow(
                step: .signIn(AccountRef(provider: .codex, id: ID.personal)),
                email: "personal@example.com",
                hasSettled: true
            )
        case .addConnectedClaude:
            model = GuardAppModel(
                profiles: [personalHealthy()],
                claudeProfiles: [connectedClaude(enrollingClaude(ID.studio, name: "Studio", hint: "s•••@example.com"))],
                isPreview: true,
                referenceDate: reference
            )
            model.enrollment = EnrollmentFlow(
                step: .signIn(AccountRef(provider: .claude, id: ID.studio)),
                email: "studio@example.com",
                hasSettled: true
            )
        case .connect:
            model = GuardAppModel(profiles: [
                codex(
                    ID.personal, "Personal", hint: "p•••@example.com",
                    status: .disconnected, detail: "Sign in to start monitoring.",
                    autoReset: false, identityVerified: false, record: nil
                ),
            ], isPreview: true, referenceDate: reference)
        case .paused:
            model = GuardAppModel(profiles: [
                codex(
                    ID.personal, "Personal", hint: "p•••@example.com",
                    status: .healthy, detail: "Automatic weekly reset is paused.", autoReset: false,
                    record: codexRecord(ID.personal, session: 71, weekly: 58, saved: 1, expiresInDays: 18)
                ),
            ], isPreview: true, referenceDate: reference)
        case .healthy:
            model = GuardAppModel(profiles: [personalHealthy(), workHealthy()], isPreview: true, referenceDate: reference)
        case .near:
            model = GuardAppModel(profiles: [
                codex(
                    ID.personal, "Personal", hint: "Account 1",
                    status: .confirming, detail: "Reading 1 of 2, next check in 5 seconds",
                    record: codexRecord(ID.personal, session: 44, weekly: 2.6, weeklyResetHours: 48, saved: 2, expiresInDays: 14)
                ),
                workHealthy(),
            ], isPreview: true, referenceDate: reference)
        case .redeemed:
            model = GuardAppModel(
                profiles: [
                    codex(
                        ID.personal, "Personal", hint: "Account 1",
                        status: .verified, detail: "Monitoring resumed",
                        record: codexRecord(ID.personal, session: 100, weekly: 100, weeklyResetHours: 168, saved: 1, expiresInDays: 15)
                    ),
                    workHealthy(),
                ],
                history: [
                    GuardHistoryEvent(
                        id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                        occurredAt: reference,
                        profileName: "Personal",
                        summary: "Weekly reset redeemed and verified"
                    ),
                ],
                isPreview: true,
                referenceDate: reference
            )
        case .authError:
            model = GuardAppModel(profiles: [personalHealthy(), workSignedOut()], isPreview: true, referenceDate: reference)
        case .overview:
            model = GuardAppModel(
                profiles: [personalHealthy()],
                claudeProfiles: [studio(session: 42, weekly: 71, status: .healthy, detail: "Checked every 5 minutes.")],
                isPreview: true,
                referenceDate: reference
            )
        case .claudeLow:
            model = GuardAppModel(
                profiles: [workHealthy()],
                claudeProfiles: [
                    studio(session: 64, weekly: 7, sonnet: 31, status: .low, detail: "Use a reset if you have one."),
                ],
                isPreview: true,
                referenceDate: reference
            )
        case .claudeSignIn:
            model = GuardAppModel(
                claudeProfiles: [
                    ClaudeProfilePresentation(
                        id: ID.studio.uuidString.lowercased(), displayName: "Studio", accountHint: "s•••@example.com",
                        planName: nil, windows: [], status: .signingIn, detail: "Finish signing in with your browser.",
                        signInURL: nil
                    ),
                ],
                isPreview: true,
                referenceDate: reference
            )
        case .monitorLow:
            model = GuardAppModel(profiles: [
                codex(
                    ID.personal, "Personal", hint: "p•••@example.com",
                    status: .nearLimit, detail: "5-hour limit is used up. It renews on its own.", autoReset: false,
                    record: codexRecord(ID.personal, session: 0, sessionResetMinutes: 95, weekly: 75, saved: 2, expiresInDays: 9)
                ),
                codex(
                    ID.work, "Work", hint: "w•••@example.com",
                    status: .nearLimit, detail: "Weekly limit is running low. Turn on Auto-redeem to use a saved reset.", autoReset: false,
                    record: codexRecord(ID.work, session: nil, weekly: 1, weeklyResetHours: 30, saved: 1, expiresInDays: 4)
                ),
            ], isPreview: true, referenceDate: reference)
        case .freshness:
            model = GuardAppModel(
                profiles: [
                    personalHealthy(),
                    codex(
                        ID.work, "Work", hint: "w•••@example.com", status: .healthy, detail: "Checked every 60 seconds.",
                        record: codexRecord(
                            ID.work, session: 52, sessionResetMinutes: 150, weekly: 4, weeklyResetHours: -0.1,
                            saved: 1, expiresInDays: 12, observedSecondsAgo: 14 * 60
                        )
                    ),
                ],
                claudeProfiles: [
                    studio(session: 38, weekly: 66, status: .healthy, detail: "Checked every 5 minutes.", observedMinutesAgo: 26),
                ],
                isPreview: true,
                referenceDate: reference
            )
        case .inventory:
            var unknown = codexRecord(ID.work, session: 80, weekly: 47, saved: 1, expiresInDays: 6, observedSecondsAgo: 3 * 3_600)
            unknown.recordSuccess(observation(
                session: 80, weekly: 47, inventory: .omitted, observedAt: reference.addingTimeInterval(-30)
            ))
            // Three saved resets, two with listed expiries (one dated, one that never expires)
            // and one Codex left out of its capped detail rows.
            let listed = QuotaAccountRecord(
                provider: .codex,
                accountID: ID.personal,
                lastSuccess: observation(
                    session: 63, weekly: 41, weeklyResetHours: 120,
                    inventory: .reported(ResetInventorySnapshot(
                        availableCount: 3,
                        expiries: .listed([.on(reference.addingTimeInterval(20 * 3_600)), .never]),
                        fetchedAt: reference.addingTimeInterval(-40)
                    )),
                    observedAt: reference.addingTimeInterval(-40)
                )
            )
            stage = { interface in
                interface.toggleInventoryDetail(AccountRef(provider: .codex, id: ID.personal))
            }
            model = GuardAppModel(profiles: [
                codex(
                    ID.personal, "Personal", hint: "p•••@example.com", status: .healthy, detail: "Checked every 60 seconds.",
                    record: listed
                ),
                codex(
                    ID.work, "Work", hint: "w•••@example.com", status: .healthy, detail: "Checked every 60 seconds.",
                    record: unknown
                ),
            ], isPreview: true, referenceDate: reference)
        case .usedExact:
            preferences = DisplayPreferences(quota: .used, resetTimes: .exact)
            model = GuardAppModel(
                profiles: [personalHealthy()],
                claudeProfiles: [studio(session: 42, weekly: 71, status: .healthy, detail: "Checked every 5 minutes.")],
                isPreview: true,
                referenceDate: reference
            )
        case .settings:
            alerts = AlertPreferences(savedResetExpiry: true, limitRefilled: true)
            model = GuardAppModel(profiles: [personalHealthy()], isPreview: true, referenceDate: reference)
            stage = { interface in
                interface.showSettings()
                interface.stagePreview(settingsFeedback: .success("Test sent. It should appear in the top-right corner of your screen."))
            }
        case .settingsDenied:
            permission = .denied
            alerts = AlertPreferences(savedResetExpiry: true, limitRefilled: false)
            model = GuardAppModel(profiles: [personalHealthy()], isPreview: true, referenceDate: reference)
            stage = { interface in
                interface.showSettings()
                interface.stagePreview(settingsFeedback: .failure(
                    "Alert saved. Turn on notifications for Second Wind in System Settings to get it."
                ))
            }
        case .rename:
            model = GuardAppModel(profiles: [personalHealthy(), workHealthy()], isPreview: true, referenceDate: reference)
            stage = { interface in
                let work = AccountRef(provider: .codex, id: ID.work)
                interface.beginRename(work, currentName: "Work")
                interface.draftName = "Client work"
                interface.reportFailure(
                    "Could not rename this account. It is busy checking or signing in. Try again in a moment.",
                    for: work
                )
            }
        case .remove:
            model = GuardAppModel(profiles: [personalHealthy(), workHealthy()], isPreview: true, referenceDate: reference)
            stage = { interface in
                let personal = AccountRef(provider: .codex, id: ID.personal)
                interface.removalKeepsResetRecord = { $0 == personal }
                interface.confirmRemoval(personal)
                interface.reportFailure(
                    "Could not remove Personal. It is busy checking or signing in. Try again in a moment.",
                    for: personal
                )
            }
        case .reveal:
            // The real path: a notification for Work resolves against loaded accounts, then the
            // popover scrolls to it and highlights it. The other target no longer exists.
            model = GuardAppModel(
                profiles: [personalHealthy(), workSignedOut()],
                claudeProfiles: [studio(session: 42, weekly: 71, status: .healthy, detail: "Checked every 5 minutes.")],
                isPreview: true,
                referenceDate: reference
            )
            stage = { interface in
                interface.reveal(AccountRef(provider: .codex, id: ID.removed))
                interface.reveal(AccountRef(provider: .codex, id: ID.work))
            }
        case .usageBlocked:
            model = GuardAppModel(profiles: [
                codex(
                    ID.personal, "Personal", hint: "p•••@example.com", status: .healthy, detail: "Checked every 60 seconds.",
                    record: codexRecord(ID.personal, session: 88, weekly: 64, saved: 1, expiresInDays: 9, access: .blocked)
                ),
                codex(
                    ID.work, "Work", hint: "w•••@example.com", status: .healthy, detail: "Checked every 60 seconds.",
                    record: codexRecord(ID.work, session: 90, weekly: 58, saved: 1, expiresInDays: 18, access: .unknown)
                ),
            ], isPreview: true, referenceDate: reference)
        case .providerFailed:
            model = GuardAppModel(profiles: [personalHealthy()], isPreview: true, referenceDate: reference)
            stage = { interface in
                interface.providerDidFail(.claude, reason: "Its saved account list could not be read. Quit and reopen Second Wind to try again.")
            }
        }

        let interface = GuardInterfaceModel(
            isPreview: true,
            isReadOnly: model.isReadOnly,
            preferenceDefaults: nil,
            preferences: preferences,
            permission: permission,
            alertPreferences: alerts
        )
        interface.attach(model)
        stage(interface)
        return (model, interface)
    }

    // MARK: Enrollment

    static func maskedHint(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, let first = parts[0].first else { return email }
        return "\(first)•••@\(parts[1])"
    }

    /// A stand-in sign-in page; previews never open it.
    static func signInURL(for provider: ProviderKind) -> URL {
        switch provider {
        case .codex: URL(string: "https://auth.openai.com/oauth/authorize?client=preview")!
        case .claude: URL(string: "https://claude.ai/oauth/authorize?client=preview")!
        }
    }

    static func enrollingCodex(_ id: UUID, name: String, hint: String) -> GuardProfilePresentation {
        var profile = codex(
            id, name, hint: hint, status: .disconnected, detail: "Waiting for browser sign-in…",
            autoReset: false, identityVerified: false, record: nil
        )
        profile.signIn = .waiting
        return profile
    }

    static func enrollingClaude(_ id: UUID, name: String, hint: String) -> ClaudeProfilePresentation {
        ClaudeProfilePresentation(
            id: id.uuidString.lowercased(), displayName: name, accountHint: hint, planName: nil, windows: [],
            status: .signingIn, detail: "Finish signing in with your browser.", signInURL: nil, signIn: .waiting
        )
    }

    /// The same account after a successful sign-in and first reading.
    static func connectedCodex(_ profile: GuardProfilePresentation) -> GuardProfilePresentation {
        guard let id = UUID(uuidString: profile.id) else { return profile }
        var connected = codex(
            id, profile.displayName, hint: profile.accountHint, status: .healthy, detail: "Checked every 60 seconds.",
            autoReset: false,
            record: codexRecord(id, session: 82, weekly: 61, weeklyResetHours: 144, saved: 2, expiresInDays: 14, observedSecondsAgo: 2)
        )
        connected.signIn = .connected
        return connected
    }

    static func connectedClaude(_ profile: ClaudeProfilePresentation) -> ClaudeProfilePresentation {
        var connected = studio(session: 64, weekly: 71, sonnet: 88, status: .healthy, detail: "Checked every 5 minutes.", observedMinutesAgo: 0)
        connected = ClaudeProfilePresentation(
            id: profile.id, displayName: profile.displayName, accountHint: profile.accountHint,
            planName: connected.planName, windows: connected.windows, status: .healthy, detail: connected.detail,
            signInURL: nil, quota: connected.quota.map { record in
                QuotaAccountRecord(
                    provider: .claude,
                    accountID: UUID(uuidString: profile.id) ?? ID.studio,
                    lastSuccess: record.lastSuccess
                )
            }
        )
        return connected
    }

    // MARK: Accounts

    private static func personalHealthy() -> GuardProfilePresentation {
        codex(
            ID.personal, "Personal", hint: "p•••@example.com", status: .healthy, detail: "Checked every 60 seconds.",
            record: codexRecord(ID.personal, session: 82, weekly: 61, weeklyResetHours: 144, saved: 2, expiresInDays: 14)
        )
    }

    private static func workHealthy() -> GuardProfilePresentation {
        codex(
            ID.work, "Work", hint: "w•••@example.com", status: .healthy, detail: "Checked every 60 seconds.",
            record: codexRecord(ID.work, session: 90, weekly: 58, weeklyResetHours: 96, saved: 1, expiresInDays: 18)
        )
    }

    private static func workSignedOut() -> GuardProfilePresentation {
        var record = codexRecord(ID.work, session: 70, weekly: 52, saved: 1, expiresInDays: 18, observedSecondsAgo: 3 * 3_600)
        record.recordFailure(.signInRequired, at: reference.addingTimeInterval(-2 * 3_600))
        return codex(
            ID.work, "Work", hint: "w•••@example.com", status: .disconnected,
            detail: "Sign-in expired. Sign in again.",
            identityVerified: false, record: record
        )
    }

    private static func codex(
        _ id: UUID,
        _ name: String,
        hint: String,
        status: GuardProfileStatus,
        detail: String,
        autoReset: Bool = true,
        identityVerified: Bool = true,
        record: QuotaAccountRecord?
    ) -> GuardProfilePresentation {
        let reading = record?.reading(at: reference)
        let weekly = reading?.windows.first { $0.window.kind == .weekly }?.window
        var saved = 0
        var expiry: Date?
        if case let .known(snapshot, _)? = reading?.inventory {
            saved = snapshot.availableCount
            expiry = snapshot.nextExpiry(after: reference)
        }
        return GuardProfilePresentation(
            id: id.uuidString.lowercased(),
            displayName: name,
            accountHint: hint,
            weeklyRemainingPercent: weekly?.remainingPercent,
            naturalResetAt: weekly?.resetsAt,
            availableResetCount: saved,
            nearestResetExpiry: expiry,
            status: status,
            detail: detail,
            autoResetEnabled: autoReset,
            identityVerified: identityVerified,
            quota: record
        )
    }

    private static func studio(
        session: Double,
        weekly: Double,
        sonnet: Double? = nil,
        status: ClaudeProfileStatus,
        detail: String,
        observedMinutesAgo: Double = 3
    ) -> ClaudeProfilePresentation {
        let sessionReset = reference.addingTimeInterval(3 * 3_600 + 40 * 60)
        let weeklyReset = reference.addingTimeInterval(5 * 86_400 + 9 * 3_600)
        var windows = [
            QuotaWindow(kind: .session, usedPercent: 100 - session, resetsAt: sessionReset),
            QuotaWindow(kind: .weekly, usedPercent: 100 - weekly, resetsAt: weeklyReset),
        ]
        if let sonnet {
            windows.append(QuotaWindow(kind: .modelWeekly("Sonnet only"), usedPercent: 100 - sonnet, resetsAt: weeklyReset))
        }
        let record = QuotaAccountRecord(
            provider: .claude,
            accountID: ID.studio,
            lastSuccess: QuotaObservation(
                observedAt: reference.addingTimeInterval(-observedMinutesAgo * 60),
                windows: windows,
                inventory: .notTracked
            )
        )
        let current = record.reading(at: reference)
        return ClaudeProfilePresentation(
            id: ID.studio.uuidString.lowercased(),
            displayName: "Studio",
            accountHint: "s•••@example.com",
            planName: "Max",
            windows: current.windows.map { window in
                ClaudeWindowPresentation(
                    id: window.id,
                    label: QuotaDisplayBuilder.label(for: window.window.kind),
                    remainingPercent: window.window.remainingPercent,
                    resetsAt: window.window.resetsAt,
                    isCurrent: window.isCurrent
                )
            },
            status: status,
            detail: detail,
            signInURL: nil,
            quota: record
        )
    }

    // MARK: Quota evidence

    private static func codexRecord(
        _ id: UUID,
        session: Double?,
        sessionResetMinutes: Double = 200,
        weekly: Double,
        weeklyResetHours: Double = 100,
        saved: Int,
        expiresInDays: Double? = nil,
        expiresInHours: Double? = nil,
        observedSecondsAgo: TimeInterval = 40,
        access: IncludedUsageAccess = .allowed
    ) -> QuotaAccountRecord {
        let observedAt = reference.addingTimeInterval(-observedSecondsAgo)
        let expiry = expiresInHours.map { reference.addingTimeInterval($0 * 3_600) }
            ?? expiresInDays.map { reference.addingTimeInterval($0 * 86_400) }
        let snapshot = ResetInventorySnapshot(
            availableCount: saved,
            expiries: .listed(saved == 0 ? [] : (0..<saved).map { index in
                expiry.map { .on($0.addingTimeInterval(Double(index) * 7 * 86_400)) } ?? .never
            }),
            fetchedAt: observedAt
        )
        return QuotaAccountRecord(
            provider: .codex,
            accountID: id,
            lastSuccess: observation(
                session: session,
                sessionResetMinutes: sessionResetMinutes,
                weekly: weekly,
                weeklyResetHours: weeklyResetHours,
                inventory: .reported(snapshot),
                observedAt: observedAt,
                access: access
            )
        )
    }

    private static func observation(
        session: Double?,
        sessionResetMinutes: Double = 200,
        weekly: Double,
        weeklyResetHours: Double = 100,
        inventory: ResetInventoryReport,
        observedAt: Date,
        access: IncludedUsageAccess = .allowed
    ) -> QuotaObservation {
        var windows = [
            QuotaWindow(kind: .weekly, usedPercent: 100 - weekly, resetsAt: reference.addingTimeInterval(weeklyResetHours * 3_600)),
        ]
        if let session {
            windows.insert(
                QuotaWindow(kind: .session, usedPercent: 100 - session, resetsAt: reference.addingTimeInterval(sessionResetMinutes * 60)),
                at: 0
            )
        }
        return QuotaObservation(
            observedAt: observedAt,
            windows: windows,
            unreportedWindows: session == nil ? [.session] : [],
            inventory: inventory,
            includedUsageAccess: access
        )
    }

    // MARK: Validation

    static func validate() throws {
        for kind in PreviewKind.allCases {
            let model = model(for: kind)
            let expectedCount: Int = switch kind {
            case .onboarding, .onboardingError, .addEmail: 0
            case .connect, .paused, .claudeSignIn, .settings, .settingsDenied, .providerFailed,
                 .addChoose, .addWaiting, .addConnected: 1
            case .freshness, .reveal: 3
            default: 2
            }
            let ids = model.profiles.map(\.id) + model.claudeProfiles.map(\.id)
            guard ids.count == expectedCount else { throw PreviewError.invalidProfileCount(kind) }
            guard Set(ids).count == ids.count else {
                throw PreviewError.duplicateProfileID(kind)
            }
            guard ids.allSatisfy({ UUID(uuidString: $0) != nil }) else {
                throw PreviewError.nonUUIDProfileID(kind)
            }
            let remaining = model.profiles.compactMap(\.weeklyRemainingPercent)
                + model.claudeProfiles.flatMap { $0.windows.map(\.remainingPercent) }
            guard remaining.allSatisfy({ (0...100).contains($0) }) else {
                throw PreviewError.invalidRemaining(kind)
            }
            guard model.referenceDate == reference else { throw PreviewError.unpinnedClock(kind) }
        }
    }
}

enum PreviewError: LocalizedError {
    case invalidProfileCount(PreviewKind)
    case duplicateProfileID(PreviewKind)
    case nonUUIDProfileID(PreviewKind)
    case invalidRemaining(PreviewKind)
    case unpinnedClock(PreviewKind)

    var errorDescription: String? {
        switch self {
        case let .invalidProfileCount(kind): "Preview \(kind.rawValue) has an unexpected profile count."
        case let .duplicateProfileID(kind): "Preview \(kind.rawValue) contains duplicate profile IDs."
        case let .nonUUIDProfileID(kind): "Preview \(kind.rawValue) has a profile ID that is not a UUID."
        case let .invalidRemaining(kind): "Preview \(kind.rawValue) contains invalid remaining usage."
        case let .unpinnedClock(kind): "Preview \(kind.rawValue) does not use the shared reference clock."
        }
    }
}

@MainActor
enum PreviewRenderer {
    static func render(kind: PreviewKind, to destination: URL) throws {
        // ImageRenderer cannot materialize an AppKit-backed ScrollView offscreen. The
        // deterministic canvas uses the exact production popover dimensions.
        let model = PreviewFixtures.model(for: kind)
        // Dark is the published default; SECOND_WIND_PREVIEW_APPEARANCE=light checks the other half.
        let isLight = ProcessInfo.processInfo.environment["SECOND_WIND_PREVIEW_APPEARANCE"] == "light"
        let view = GuardPopoverView(
            model: model,
            interface: PreviewFixtures.interface(for: model),
            canvasHeight: 560,
            isStaticRender: true
        )
            .environment(\.colorScheme, isLight ? .light : .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        var png: Data?
        // Dynamic palette colours resolve against the current drawing appearance.
        NSAppearance(named: isLight ? .aqua : .darkAqua)!.performAsCurrentDrawingAppearance {
            if let image = renderer.nsImage,
               let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff) {
                png = bitmap.representation(using: .png, properties: [:])
            }
        }
        guard let png else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: destination, options: .atomic)
    }
}
