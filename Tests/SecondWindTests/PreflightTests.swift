import Darwin
import Foundation
import Testing
@testable import SecondWindCore
@testable import SecondWind

private let now = Date(timeIntervalSince1970: 2_000_000_000)
private let codexID = UUID(uuidString: "0F8E1C2A-58E4-4F43-9D5A-0D7F0B1B2C3D")!
private let secondCodexID = UUID(uuidString: "2B000000-0000-4000-8000-000000000002")!
private let claudeID = UUID(uuidString: "7A1B0000-0000-4000-8000-000000000001")!

private func codex(
    _ id: UUID = codexID,
    session: Double? = 36,
    weekly: Double? = 59,
    observedAt: Date = now.addingTimeInterval(-30),
    sessionResetsAt: Date = now.addingTimeInterval(3 * 3_600),
    access: IncludedUsageAccess = .unreported,
    failure: QuotaFailureReason? = nil
) -> QuotaAccountRecord {
    var windows: [QuotaWindow] = []
    var unreported: [QuotaWindowKind] = []
    if let session {
        windows.append(QuotaWindow(kind: .session, usedPercent: session, resetsAt: sessionResetsAt))
    } else {
        unreported.append(.session)
    }
    if let weekly {
        windows.append(QuotaWindow(kind: .weekly, usedPercent: weekly, resetsAt: now.addingTimeInterval(4 * 86_400)))
    } else {
        unreported.append(.weekly)
    }
    return QuotaAccountRecord(
        provider: .codex,
        accountID: id,
        lastSuccess: QuotaObservation(
            observedAt: observedAt,
            windows: windows,
            unreportedWindows: unreported,
            inventory: .reported(ResetInventorySnapshot(availableCount: 2, expiries: .unlisted, fetchedAt: observedAt)),
            includedUsageAccess: access
        ),
        lastFailure: failure.map { QuotaRefreshFailure(failedAt: now.addingTimeInterval(-5), reason: $0) }
    )
}

private func claude(
    session: Double = 20,
    weekly: Double? = 50,
    models: [String: Double] = [:],
    observedAt: Date = now.addingTimeInterval(-300)
) -> QuotaAccountRecord {
    var windows = [QuotaWindow(kind: .session, usedPercent: session, resetsAt: now.addingTimeInterval(7_200))]
    if let weekly {
        windows.append(QuotaWindow(kind: .weekly, usedPercent: weekly, resetsAt: nil))
    }
    for (model, used) in models.sorted(by: { $0.key < $1.key }) {
        windows.append(QuotaWindow(kind: .modelWeekly(model), usedPercent: used, resetsAt: nil))
    }
    return QuotaAccountRecord(
        provider: .claude,
        accountID: claudeID,
        lastSuccess: QuotaObservation(observedAt: observedAt, windows: windows, inventory: .notTracked)
    )
}

private func snapshot(
    _ accounts: [QuotaAccountRecord],
    providers: Set<QuotaProvider> = [.codex, .claude]
) -> Result<PreflightSnapshot, PreflightSnapshotReadFailure> {
    .success(PreflightSnapshot(publishedAt: now, providers: providers, accounts: accounts))
}

private func request(
    session: Int? = nil,
    weekly: Int? = nil,
    provider: QuotaProvider? = nil,
    account: UUID? = nil
) -> PreflightRequest {
    PreflightRequest(minimumSessionPercent: session, minimumWeeklyPercent: weekly, provider: provider, accountID: account)!
}

private func evaluate(
    _ request: PreflightRequest,
    _ snapshot: Result<PreflightSnapshot, PreflightSnapshotReadFailure>
) -> PreflightOutcome {
    PreflightEvaluator.evaluate(request, snapshot: snapshot, now: now)
}

private func reasons(_ outcome: PreflightOutcome) -> [PreflightReason?] {
    outcome.checks.map(\.reason)
}

@Suite struct PreflightEvaluatorTests {
    @Test func freshCodexAccessSurvivesTheFileAndTakesPrecedenceOverPercentages() throws {
        for access in [IncludedUsageAccess.allowed, .blocked, .unknown, .unreported] {
            let file = PreflightSnapshot(publishedAt: now, providers: [.codex], accounts: [codex(access: access)])
            let reading = PreflightSnapshotFile.decode(try PreflightSnapshotFile.encode(file))
            let outcome = evaluate(request(session: 20, weekly: 30, provider: .codex), reading)
            switch access {
            case .blocked:
                #expect(outcome.result == .low && outcome.reason == .usageBlocked)
                #expect(PreflightCommandLine.plain(outcome, now: now).contains("ordinary usage is blocked"))
            case .unknown:
                #expect(outcome.result == .unknown && outcome.reason == .usageUnconfirmed)
            case .allowed, .unreported:
                #expect(outcome.result == .enough)
            }
        }
        let old = codex(observedAt: now.addingTimeInterval(-125), access: .blocked)
        #expect(evaluate(request(weekly: 20, provider: .codex), snapshot([old])).reason == .readingStale)
        let exhausted = codex(session: 100, access: .unknown)
        #expect(evaluate(request(session: 1, provider: .codex), snapshot([exhausted])).result == .low)
    }

    @Test func codexWindowWithoutItsResetTimeCannotGivePermissionToStart() throws {
        let incomplete = QuotaAccountRecord(provider: .codex, accountID: codexID, lastSuccess: QuotaObservation(
            observedAt: now, windows: [QuotaWindow(kind: .weekly, usedPercent: 0, resetsAt: nil)], inventory: .omitted
        ))
        let file = PreflightSnapshot(publishedAt: now, providers: [.codex], accounts: [incomplete])
        let reading = PreflightSnapshotFile.decode(try PreflightSnapshotFile.encode(file))
        #expect(evaluate(request(weekly: 10, provider: .codex), reading).reason == .windowMissing)
    }

    @Test func enoughWhenEveryRequestedWindowIsCurrentAndAtOrAboveItsMinimum() {
        let outcome = evaluate(request(session: 20, weekly: 41, provider: .codex), snapshot([codex(), claude()]))
        #expect(outcome.result == .enough)
        #expect(outcome.result.exitCode == 0)
        #expect(outcome.reason == nil)
        #expect(outcome.account == PreflightAccountReference(provider: .codex, accountID: codexID))
        #expect(outcome.checks.map(\.window?.remainingPercent) == [64, 41])
        #expect(outcome.checks.first?.staleAfter == now.addingTimeInterval(-30 + 120))
    }

    @Test func lowWhenAnyCurrentWindowIsBelowItsMinimum() {
        let outcome = evaluate(request(session: 20, weekly: 42, provider: .codex), snapshot([codex()]))
        #expect(outcome.result == .low)
        #expect(outcome.result.exitCode == 10)
        #expect(outcome.checks.map(\.result) == [.enough, .low])
    }

    @Test func zeroRemainingIsLowEvenForAZeroMinimum() {
        let exhausted = evaluate(request(session: 0, provider: .codex), snapshot([codex(session: 100)]))
        #expect(exhausted.result == .low)
        let sliver = evaluate(request(session: 0, provider: .codex), snapshot([codex(session: 99.6)]))
        #expect(sliver.result == .enough)
    }

    @Test func lowWinsOverUnknownAcrossAndWithinWindows() {
        let acrossWindows = evaluate(request(session: 70, weekly: 10, provider: .codex), snapshot([codex(weekly: nil)]))
        #expect(acrossWindows.result == .low)
        #expect(acrossWindows.checks.map(\.result) == [.low, .unknown])
        #expect(acrossWindows.reason == nil)

        let modelLowWithoutAllModels = evaluate(
            request(weekly: 10, provider: .claude),
            snapshot([claude(weekly: nil, models: ["Opus": 95])])
        )
        #expect(modelLowWithoutAllModels.result == .low)
        #expect(modelLowWithoutAllModels.checks.first?.window?.kind == .modelWeekly("Opus"))
    }

    @Test func staleness_followsTheSharedPerProviderPolicy() {
        let codexStale = evaluate(request(weekly: 10, provider: .codex), snapshot([codex(observedAt: now.addingTimeInterval(-120))]))
        #expect(codexStale.result == .unknown)
        #expect(codexStale.reason == .readingStale)
        #expect(codexStale.result.exitCode == 11)

        let codexFresh = evaluate(request(weekly: 10, provider: .codex), snapshot([codex(observedAt: now.addingTimeInterval(-119))]))
        #expect(codexFresh.result == .enough)

        let claudeFresh = evaluate(request(weekly: 10, provider: .claude), snapshot([claude(observedAt: now.addingTimeInterval(-599))]))
        #expect(claudeFresh.result == .enough)
        let claudeStale = evaluate(request(weekly: 10, provider: .claude), snapshot([claude(observedAt: now.addingTimeInterval(-600))]))
        #expect(claudeStale.reason == .readingStale)
    }

    @Test func staleLowReadingIsUnknownNotLow() {
        let outcome = evaluate(request(session: 90, provider: .codex), snapshot([codex(observedAt: now.addingTimeInterval(-500))]))
        #expect(outcome.result == .unknown)
        #expect(outcome.reason == .readingStale)
    }

    @Test func futureDatedReadingIsNeverFresh() {
        let outcome = evaluate(request(weekly: 10, provider: .codex), snapshot([codex(observedAt: now.addingTimeInterval(1))]))
        #expect(outcome.result == .unknown)
        #expect(outcome.reason == .readingFromFuture)
    }

    @Test func passedResetIsUnknownUntilANewReading() {
        let outcome = evaluate(
            request(session: 10, provider: .codex),
            snapshot([codex(sessionResetsAt: now)])
        )
        #expect(outcome.reason == .windowResetPassed)
        #expect(outcome.checks.first?.window?.kind == .session)
    }

    @Test func missingWindowIsUnknownAndNeverZero() {
        let unreported = evaluate(request(session: 0, provider: .codex), snapshot([codex(session: nil)]))
        #expect(unreported.result == .unknown)
        #expect(unreported.reason == .windowMissing)

        let empty = QuotaAccountRecord(
            provider: .codex,
            accountID: codexID,
            lastSuccess: QuotaObservation(observedAt: now.addingTimeInterval(-10), windows: [], inventory: .omitted)
        )
        let noWindows = evaluate(request(session: 10, weekly: 10, provider: .codex), snapshot([empty]))
        #expect(noWindows.result == .unknown)
        #expect(reasons(noWindows) == [.windowMissing, .windowMissing])
    }

    @Test func claudeWeeklyRequiresAllModelsWindowAndPerModelWindowsOnlyLowerIt() {
        let lowered = evaluate(request(weekly: 10, provider: .claude), snapshot([claude(weekly: 50, models: ["Opus": 95])]))
        #expect(lowered.result == .low)
        #expect(lowered.checks.first?.window?.kind == .modelWeekly("Opus"))

        let allModelsMissing = evaluate(request(weekly: 10, provider: .claude), snapshot([claude(weekly: nil, models: ["Opus": 10])]))
        #expect(allModelsMissing.result == .unknown)
        #expect(allModelsMissing.reason == .windowMissing)

        let tieGoesToAllModels = evaluate(request(weekly: 10, provider: .claude), snapshot([claude(weekly: 50, models: ["Opus": 50])]))
        #expect(tieGoesToAllModels.checks.first?.window?.kind == .weekly)
    }

    @Test func failedOrNeverReadAccountsAreNeverGreen() {
        for failure in [QuotaFailureReason.signInRequired, .wrongAccount, .unavailable, .monitoringStopped] {
            let outcome = evaluate(request(weekly: 10, provider: .codex), snapshot([codex(failure: failure)]))
            #expect(outcome.result == .unknown)
            #expect(outcome.reason == .refreshFailed)
            #expect(outcome.checks.first?.failure == failure)
        }
        let neverRead = evaluate(
            request(weekly: 10, provider: .codex),
            snapshot([QuotaAccountRecord(provider: .codex, accountID: codexID)])
        )
        #expect(neverRead.reason == .noReading)
    }

    @Test func accountSelectionIsDeterministicAndFailsClosed() {
        let two = snapshot([codex(secondCodexID), codex(codexID), claude()])
        let ambiguous = evaluate(request(weekly: 10, provider: .codex), two)
        #expect(ambiguous.reason == .accountAmbiguous)
        #expect(ambiguous.candidates.map(\.accountID) == [codexID, secondCodexID])
        #expect(ambiguous.account == nil)

        let byID = evaluate(request(weekly: 10, account: secondCodexID), two)
        #expect(byID.account?.accountID == secondCodexID)
        #expect(byID.result == .enough)

        let unknownID = evaluate(request(weekly: 10, account: UUID()), two)
        #expect(unknownID.reason == .accountNotFound)

        let wrongProvider = evaluate(request(weekly: 10, provider: .claude, account: codexID), two)
        #expect(wrongProvider.reason == .accountNotFound)

        let everyProvider = evaluate(request(weekly: 10), snapshot([codex(), claude()]))
        #expect(everyProvider.reason == .accountAmbiguous)
        #expect(everyProvider.candidates.map(\.provider) == [.claude, .codex])
    }

    @Test func singleApparentAccountIsNotSelectedBeforeEveryRosterLoads() {
        let codexOnly = snapshot([codex()], providers: [.codex])
        #expect(evaluate(request(weekly: 10), codexOnly).reason == .rosterIncomplete)
        #expect(evaluate(request(weekly: 10, provider: .claude), codexOnly).reason == .rosterIncomplete)
        #expect(evaluate(request(weekly: 10, provider: .codex), codexOnly).result == .enough)
        #expect(evaluate(request(weekly: 10, account: codexID), codexOnly).result == .enough)
        #expect(evaluate(request(weekly: 10, account: claudeID), codexOnly).reason == .rosterIncomplete)
        #expect(evaluate(request(weekly: 10), snapshot([], providers: [])).reason == .rosterIncomplete)
        #expect(evaluate(request(weekly: 10), snapshot([])).reason == .accountNotFound)
    }

    @Test func snapshotFailuresAreUnknownForEveryCheck() {
        for failure in [PreflightSnapshotReadFailure.missing, .unreadable, .invalid, .unsupportedVersion] {
            let outcome = evaluate(request(session: 10, weekly: 10), .failure(failure))
            #expect(outcome.result == .unknown)
            #expect(outcome.reason?.rawValue == failure.rawValue)
            #expect(reasons(outcome) == [outcome.reason, outcome.reason])
        }
    }

    @Test func requestRejectsEmptyAndOutOfRangeMinimums() {
        #expect(PreflightRequest(minimumSessionPercent: nil, minimumWeeklyPercent: nil) == nil)
        #expect(PreflightRequest(minimumSessionPercent: 101, minimumWeeklyPercent: nil) == nil)
        #expect(PreflightRequest(minimumSessionPercent: nil, minimumWeeklyPercent: -1) == nil)
        #expect(PreflightRequest(minimumSessionPercent: 0, minimumWeeklyPercent: 100) != nil)
    }
}

@Suite struct PreflightSnapshotFileTests {
    @Test func publisherWritesAPrivateAtomicSnapshotThatRoundTripsWithoutInventory() async throws {
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = PreflightSnapshotFile.url(applicationSupportDirectory: directory)
        let publisher = PreflightSnapshotPublisher(fileURL: url, runStartedAt: now.addingTimeInterval(-3_600))

        try await publisher.clear(now: now)
        guard case let .success(empty) = PreflightSnapshotFile.read(from: url) else {
            Issue.record("cleared snapshot unreadable"); return
        }
        #expect(empty.providers.isEmpty)
        #expect(empty.accounts.isEmpty)

        try await publisher.publish(provider: .codex, records: [codex(), codex(secondCodexID)], now: now)
        try await publisher.publish(provider: .claude, records: [claude()], now: now)
        try await publisher.publish(provider: .codex, records: [codex()], now: now)

        guard case let .success(read) = PreflightSnapshotFile.read(from: url) else {
            Issue.record("published snapshot unreadable"); return
        }
        #expect(read.providers == [.codex, .claude])
        #expect(read.accounts.map(\.accountID) == [codexID, claudeID])
        #expect(read.accounts.first?.lastSuccess?.windows == codex().lastSuccess?.windows)
        #expect(read.accounts.first?.lastSuccess?.inventory == .omitted)
        #expect(read.accounts.first?.lastKnownInventory == nil)

        let text = try String(contentsOf: url, encoding: .utf8)
        for forbidden in ["@", "inventory", "availableCount", "displayName", "email", "credit"] {
            #expect(!text.contains(forbidden), "snapshot leaked \(forbidden)")
        }
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [PreflightSnapshotFile.fileName])
    }

    @Test func publisherKeepsFailuresAndRejectsMixedOrDuplicateRosters() async throws {
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = PreflightSnapshotFile.url(applicationSupportDirectory: directory)
        let publisher = PreflightSnapshotPublisher(fileURL: url, runStartedAt: now.addingTimeInterval(-3_600))

        try await publisher.publish(provider: .codex, records: [codex(failure: .wrongAccount)], now: now)
        guard case let .success(read) = PreflightSnapshotFile.read(from: url) else {
            Issue.record("unreadable"); return
        }
        #expect(read.accounts.first?.lastFailure?.reason == .wrongAccount)
        #expect(read.providers == [.codex])

        await #expect(throws: PreflightSnapshotPublishError.providerMismatch) {
            try await publisher.publish(provider: .codex, records: [claude()], now: now)
        }
        await #expect(throws: PreflightSnapshotPublishError.duplicateAccount) {
            try await publisher.publish(provider: .codex, records: [codex(), codex()], now: now)
        }
    }

    @Test func outOfRangeWindowIsPublishedAsUnreported() async throws {
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = PreflightSnapshotFile.url(applicationSupportDirectory: directory)
        try await PreflightSnapshotPublisher(fileURL: url, runStartedAt: now.addingTimeInterval(-3_600))
            .publish(provider: .codex, records: [codex(session: -5)], now: now)
        guard case let .success(read) = PreflightSnapshotFile.read(from: url) else {
            Issue.record("unreadable"); return
        }
        #expect(read.accounts.first?.lastSuccess?.windows.map(\.kind) == [.weekly])
        #expect(read.accounts.first?.lastSuccess?.unreportedWindows == [.session])
    }

    @Test func previousRunEvidenceIsNeverGreenAfterRelaunch() async throws {
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = PreflightSnapshotFile.url(applicationSupportDirectory: directory)

        let previousRun = PreflightSnapshotPublisher(fileURL: url, runStartedAt: now.addingTimeInterval(-600))
        try await previousRun.publish(provider: .codex, records: [codex()], now: now.addingTimeInterval(-20))
        try await previousRun.publish(provider: .claude, records: [claude()], now: now.addingTimeInterval(-20))
        let green = PreflightEvaluator.evaluate(request(weekly: 10, provider: .claude), snapshot: PreflightSnapshotFile.read(from: url), now: now)
        #expect(green.result == .enough)

        let relaunch = PreflightSnapshotPublisher(fileURL: url, runStartedAt: now.addingTimeInterval(-10))
        try await relaunch.clear(now: now.addingTimeInterval(-10))
        let cleared = PreflightEvaluator.evaluate(request(weekly: 10, provider: .claude), snapshot: PreflightSnapshotFile.read(from: url), now: now)
        #expect(cleared.reason == .rosterIncomplete)

        // Claude's persisted report reloads with its old timestamp; it must not count yet.
        try await relaunch.publish(provider: .claude, records: [claude(observedAt: now.addingTimeInterval(-60))], now: now)
        try await relaunch.publish(provider: .codex, records: [], now: now)
        let reloaded = PreflightEvaluator.evaluate(request(weekly: 10, provider: .claude), snapshot: PreflightSnapshotFile.read(from: url), now: now)
        #expect(reloaded.reason == .noReading)
        let removed = PreflightEvaluator.evaluate(request(weekly: 10, account: codexID), snapshot: PreflightSnapshotFile.read(from: url), now: now)
        #expect(removed.reason == .accountNotFound)

        try await relaunch.publish(provider: .claude, records: [claude(observedAt: now.addingTimeInterval(-5))], now: now)
        let verified = PreflightEvaluator.evaluate(request(weekly: 10, provider: .claude), snapshot: PreflightSnapshotFile.read(from: url), now: now)
        #expect(verified.result == .enough)
    }

    @Test func readerFailsClosedOnUnsafeOrMalformedFiles() throws {
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("quota-snapshot.json")

        #expect(PreflightSnapshotFile.read(from: url) == .failure(.missing))

        try write("not json", to: url)
        #expect(PreflightSnapshotFile.read(from: url) == .failure(.invalid))

        try write(#"{"schemaVersion":2}"#, to: url)
        #expect(PreflightSnapshotFile.read(from: url) == .failure(.unsupportedVersion))

        let valid = Self.validFixture
        try write(valid, to: url)
        #expect(chmod(url.path, 0o644) == 0)
        #expect(PreflightSnapshotFile.read(from: url) == .failure(.unreadable))

        try FileManager.default.removeItem(at: url)
        let target = directory.appendingPathComponent("target.json")
        try write(valid, to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        #expect(PreflightSnapshotFile.read(from: url) == .failure(.unreadable))
        try FileManager.default.removeItem(at: url)

        let malformed = [
            Self.validFixture.replacingOccurrences(of: #""usedPercent":36"#, with: #""usedPercent":120"#),
            Self.validFixture.replacingOccurrences(of: #""providers":["codex"]"#, with: #""providers":[]"#),
            Self.validFixture.replacingOccurrences(of: #""kind":"session""#, with: #""kind":"hourly""#),
            Self.validFixture.replacingOccurrences(of: #""sign_in_required""#, with: #""mystery""#),
            Self.validFixture.replacingOccurrences(of: codexID.uuidString.lowercased(), with: "not-a-uuid"),
            Self.validFixture.replacingOccurrences(of: #""kind":"weekly""#, with: #""kind":"session""#),
        ]
        for text in malformed {
            try write(text, to: url)
            #expect(PreflightSnapshotFile.read(from: url) == .failure(.invalid), "accepted \(text)")
        }

        try write(valid, to: url)
        guard case let .success(read) = PreflightSnapshotFile.read(from: url) else {
            Issue.record("valid fixture rejected"); return
        }
        #expect(read.accounts.first?.lastFailure?.reason == .signInRequired)
    }

    static let validFixture = """
    {"schemaVersion":1,"publishedAt":"2033-05-18T03:33:20Z","providers":["codex"],"accounts":[\
    {"provider":"codex","id":"0f8e1c2a-58e4-4f43-9d5a-0d7f0b1b2c3d",\
    "lastSuccess":{"observedAt":"2033-05-18T03:32:50Z","windows":[\
    {"kind":"session","usedPercent":36,"resetsAt":"2033-05-18T06:33:20Z"},\
    {"kind":"weekly","usedPercent":59,"resetsAt":"2033-05-22T03:33:20Z"}],"unreportedWindows":[]},\
    "lastFailure":{"failedAt":"2033-05-18T03:33:15Z","reason":"sign_in_required"}}]}
    """
}

@Suite struct PreflightCommandLineTests {
    private let snapshotURL = URL(fileURLWithPath: "/tmp/preflight-default.json")

    private func parse(_ arguments: [String]) throws -> PreflightInvocation {
        try PreflightCommandLine.parse(arguments, defaultSnapshotURL: snapshotURL)
    }

    @Test func parsesEveryOptionInAnyOrder() throws {
        let invocation = try parse([
            "--json", "--weekly", "10", "--account", codexID.uuidString, "--session", "0",
            "--provider", "codex", "--snapshot", "/private/tmp/q.json",
        ])
        #expect(invocation.format == .json)
        #expect(invocation.snapshotURL.path == "/private/tmp/q.json")
        #expect(invocation.request == request(session: 0, weekly: 10, provider: .codex, account: codexID))

        let minimal = try parse(["--weekly", "100"])
        #expect(minimal.format == .plain)
        #expect(minimal.snapshotURL == snapshotURL)
        #expect(minimal.request == request(weekly: 100))
    }

    @Test func rejectsMalformedArgumentsBeforeReadingAnything() {
        let cases: [([String], GuardCommandLineError)] = [
            ([], .invalidPreflight("Give --session, --weekly or both.")),
            (["--json"], .invalidPreflight("Give --session, --weekly or both.")),
            (["--weekly"], .missingValue(option: "--weekly")),
            (["--weekly", "10", "--weekly", "20"], .invalidPreflight("--weekly was given more than once.")),
            (["--weekly", "10", "--json", "--json"], .invalidPreflight("--json was given more than once.")),
            (["--weekly", "101"], .invalidPreflight("--weekly must be a whole number from 0 to 100.")),
            (["--weekly", "-1"], .invalidPreflight("--weekly must be a whole number from 0 to 100.")),
            (["--session", "12.5"], .invalidPreflight("--session must be a whole number from 0 to 100.")),
            (["--session", "nan"], .invalidPreflight("--session must be a whole number from 0 to 100.")),
            (["--session", "inf"], .invalidPreflight("--session must be a whole number from 0 to 100.")),
            (["--session", ""], .invalidPreflight("--session must be a whole number from 0 to 100.")),
            (["--session", "\u{0665}"], .invalidPreflight("--session must be a whole number from 0 to 100.")),
            (["--weekly", "10", "--provider", "openai"], .invalidPreflight("--provider must be codex or claude.")),
            (["--weekly", "10", "--account", "work"], .invalidPreflight("--account must be an account ID (a UUID).")),
            (["--weekly", "10", "--snapshot", "relative.json"], .invalidPreflight("--snapshot must be an absolute path.")),
            (["--weekly", "10", "--doctor"], .unknownOption("--doctor")),
            (["--weekly=10"], .unknownOption("--weekly=10")),
            (["--weekly", "10", "extra"], .unexpectedArgument("extra")),
        ]
        for (arguments, error) in cases {
            #expect(throws: error, "\(arguments)") { try parse(arguments) }
        }
    }

    @Test func plainOutputFloorsSoNumbersNeverContradictTheVerdict() {
        let enough = evaluate(request(session: 20, weekly: 41, provider: .codex), snapshot([codex(session: 79.6)]))
        #expect(PreflightCommandLine.plain(enough, now: now) == """
        Enough quota on codex account 0f8e1c2a-58e4-4f43-9d5a-0d7f0b1b2c3d.
        Session: 20% left, at least the 20% required. Resets in 3 h 0 min.
        Weekly: 41% left, at least the 41% required. Resets in 4 d 0 h.
        """)

        let low = evaluate(request(session: 20, weekly: 10, provider: .codex), snapshot([codex(session: 80.4, weekly: nil)]))
        #expect(PreflightCommandLine.plain(low, now: now) == """
        Low quota on codex account 0f8e1c2a-58e4-4f43-9d5a-0d7f0b1b2c3d.
        Session: 19% left, below the 20% required. Resets in 3 h 0 min.
        Weekly: unknown (window_missing). The provider did not report this window.
        """)

        let exhausted = evaluate(request(session: 0, provider: .codex), snapshot([codex(session: 100)]))
        #expect(PreflightCommandLine.plain(exhausted, now: now).hasSuffix("Session: nothing left. Resets in 3 h 0 min."))

        let ambiguous = evaluate(request(weekly: 10), snapshot([codex(), claude()]))
        #expect(PreflightCommandLine.plain(ambiguous, now: now) == """
        Quota unknown (account_ambiguous). More than one account matches. Pass --account with one of these IDs:
        claude 7a1b0000-0000-4000-8000-000000000001
        codex 0f8e1c2a-58e4-4f43-9d5a-0d7f0b1b2c3d
        """)

        let failed = evaluate(request(weekly: 10, provider: .codex), snapshot([codex(failure: .signInRequired)]))
        #expect(PreflightCommandLine.plain(failed, now: now).hasSuffix(
            "Weekly: unknown (refresh_failed: sign_in_required). The last check failed."
        ))
    }

    @Test func jsonHasStableKeysWithExplicitNulls() {
        let low = evaluate(request(session: 20, weekly: 10, provider: .codex), snapshot([codex(session: 85, weekly: nil)]))
        #expect(PreflightCommandLine.json(low) == """
        {"account":{"id":"0f8e1c2a-58e4-4f43-9d5a-0d7f0b1b2c3d","provider":"codex"},"candidates":[],"checks":[\
        {"failure":null,"minimumPercent":20,"observedAt":"2033-05-18T03:32:50Z","reason":null,"remainingPercent":15,\
        "resetsAt":"2033-05-18T06:33:20Z","result":"low","scope":null,"staleAfter":"2033-05-18T03:34:50Z","window":"session"},\
        {"failure":null,"minimumPercent":10,"observedAt":"2033-05-18T03:32:50Z","reason":"window_missing","remainingPercent":null,\
        "resetsAt":null,"result":"unknown","scope":null,"staleAfter":"2033-05-18T03:34:50Z","window":"weekly"}],\
        "exitCode":10,"reason":null,"result":"low","schemaVersion":1}
        """)

        let missing = evaluate(request(weekly: 10), .failure(.missing))
        #expect(PreflightCommandLine.json(missing) == """
        {"account":null,"candidates":[],"checks":[{"failure":null,"minimumPercent":10,"observedAt":null,\
        "reason":"snapshot_missing","remainingPercent":null,"resetsAt":null,"result":"unknown","scope":null,\
        "staleAfter":null,"window":"weekly"}],"exitCode":11,"reason":"snapshot_missing","result":"unknown","schemaVersion":1}
        """)
    }

    @Test func runReadsOnlyTheNamedSnapshotAndReturnsTheVerdictExitCode() throws {
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("quota-snapshot.json")
        try write(PreflightSnapshotFileTests.validFixture, to: url)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)

        let invocation = try parse(["--weekly", "10", "--provider", "codex", "--snapshot", url.path])
        let (output, code) = PreflightCommandLine.run(invocation, now: now)
        #expect(code == 11)
        #expect(output.contains("(refresh_failed: sign_in_required)"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            == attributes[.modificationDate] as? Date)
    }

    @Test func suggestedCommandQuotesThePathAndNamesTheAccount() {
        #expect(PreflightCommandLine.suggestedCommand(
            executablePath: "/Applications/Second Wind's.app/Contents/MacOS/SecondWind",
            provider: .claude,
            accountID: claudeID
        ) == #"'/Applications/Second Wind'\''s.app/Contents/MacOS/SecondWind' --preflight --provider claude --account 7a1b0000-0000-4000-8000-000000000001 --session 10 --weekly 10"#)
    }
}

private func privateDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("preflight-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return url
}

private func write(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
    #expect(chmod(url.path, 0o600) == 0)
}
