import Foundation
import Testing
@testable import SecondWindCore

private let now = Date(timeIntervalSince1970: 2_000_000_000)

private func codexSnapshot(
    session: Double? = 40,
    weekly: Double? = 25,
    sessionDuration: Double? = 300,
    limitID: String? = "codex",
    observedAt: Date = now
) -> RateLimitSnapshot {
    RateLimitSnapshot(
        limitID: limitID,
        primary: session.map {
            RateLimitWindow(
                usedPercent: $0,
                windowDurationMinutes: sessionDuration,
                resetsAt: observedAt.addingTimeInterval(3_600)
            )
        },
        secondary: weekly.map {
            RateLimitWindow(
                usedPercent: $0,
                windowDurationMinutes: 10_080,
                resetsAt: observedAt.addingTimeInterval(4 * 86_400)
            )
        },
        observedAt: observedAt
    )
}

private func codexRecord(
    _ observation: QuotaObservation?,
    id: UUID = UUID()
) -> QuotaAccountRecord {
    QuotaAccountRecord(provider: .codex, accountID: id, lastSuccess: observation)
}

private func observation(
    _ snapshot: RateLimitSnapshot = codexSnapshot(),
    inventory: RPCResetCreditsSummary? = RPCResetCreditsSummary(availableCount: 0, credits: []),
    access: IncludedUsageAccess = .unreported
) throws -> QuotaObservation {
    try #require(RateLimitClassifier().quotaObservation(
        snapshot,
        inventory: inventory.map { .reported($0.inventorySnapshot(fetchedAt: snapshot.observedAt)) } ?? .omitted,
        includedUsageAccess: access
    ))
}

private func credit(
    _ id: String,
    expiry: RPCResetCreditExpiry,
    status: String = "available",
    resetType: String = "codexRateLimits"
) -> RPCResetCredit {
    RPCResetCredit(
        id: id, resetType: resetType, status: status,
        grantedAt: Int64(now.timeIntervalSince1970) - 86_400,
        expiry: expiry, title: nil, detail: nil
    )
}

private func seconds(_ offset: TimeInterval) -> Int64 {
    Int64(now.addingTimeInterval(offset).timeIntervalSince1970)
}

@Test func codexWindowsAreLabelledByLengthNotLane() throws {
    let reading = codexRecord(try observation()).reading(at: now)
    #expect(reading.windows.map(\.window.kind) == [.session, .weekly])
    #expect(reading.windows.map(\.window.remainingPercent) == [60, 75])
    #expect(reading.unknownWindows.isEmpty)
    #expect(reading.isConfirmed)
}

@Test func missingFiveHourWindowIsUnknownNotZeroAndBlocksAllClear() throws {
    let reading = codexRecord(try observation(codexSnapshot(session: nil))).reading(at: now)
    #expect(reading.windows.map(\.window.kind) == [.weekly])
    #expect(reading.unknownWindows == [.session])
    #expect(reading.warning == nil)
    #expect(!reading.isConfirmed)
    #expect(!QuotaSummary(readings: [reading]).isAllClear)
}

@Test func fiveHourWindowWithoutLengthIsUnknown() throws {
    let reading = codexRecord(try observation(codexSnapshot(sessionDuration: nil))).reading(at: now)
    #expect(reading.unknownWindows == [.session])
}

@Test func twoWindowsOfOneLengthAreBothUnknown() throws {
    let snapshot = RateLimitSnapshot(
        limitID: "codex",
        primary: RateLimitWindow(usedPercent: 10, windowDurationMinutes: 10_080, resetsAt: now.addingTimeInterval(9)),
        secondary: RateLimitWindow(usedPercent: 90, windowDurationMinutes: 10_080, resetsAt: now.addingTimeInterval(9)),
        observedAt: now
    )
    let reading = codexRecord(try observation(snapshot)).reading(at: now)
    #expect(reading.windows.isEmpty)
    #expect(Set(reading.unknownWindows) == [.session, .weekly])
}

@Test func nonCanonicalBucketHasNoObservation() {
    let classifier = RateLimitClassifier()
    #expect(classifier.quotaObservation(codexSnapshot(limitID: "codex-other"), inventory: .omitted) == nil)
    let named = RateLimitSnapshot(limitID: nil, limitName: "gpt-other", observedAt: now)
    #expect(classifier.quotaObservation(named, inventory: .omitted) == nil)
}

@Test func newlyEnrolledOnePercentWeeklyWarnsOnTheWeeklyWindow() throws {
    let reading = codexRecord(try observation(codexSnapshot(session: 0, weekly: 99))).reading(at: now)
    let warning = try #require(reading.warning)
    #expect(warning.window.kind == .weekly)
    #expect(warning.window.remainingPercent == 1)
    #expect(warning.level == .low)
    #expect(warning.isCurrent)
}

@Test func exhaustedFiveHourWithHealthyWeekNamesTheFiveHourWindow() throws {
    let reading = codexRecord(try observation(codexSnapshot(session: 100, weekly: 25))).reading(at: now)
    let warning = try #require(reading.warning)
    #expect(warning.window.kind == .session)
    #expect(warning.level == .exhausted)
    let summary = QuotaSummary(readings: [reading])
    #expect(summary.lowestCurrentRemainingPercent == 0)
    #expect(summary.warnings.map(\.window.window.kind) == [.session])
    #expect(!summary.isAllClear)
}

@Test func inventoryDistinguishesUnknownUnlistedAndZero() throws {
    let legacy = codexRecord(try observation(inventory: nil)).reading(at: now)
    #expect(legacy.inventory == .unknown(lastKnown: nil))

    let countOnly = codexRecord(
        try observation(inventory: RPCResetCreditsSummary(availableCount: 2, credits: nil))
    ).reading(at: now)
    guard case let .known(unlisted, isCurrent) = countOnly.inventory else {
        Issue.record("Expected a known count")
        return
    }
    #expect(isCurrent)
    #expect(unlisted.availableCount == 2)
    #expect(unlisted.expiries == .unlisted)
    #expect(unlisted.fetchedAt == now)

    let zero = codexRecord(try observation()).reading(at: now)
    #expect(zero.inventory == .known(
        ResetInventorySnapshot(availableCount: 0, expiries: .listed([]), fetchedAt: now),
        isCurrent: true
    ))
}

@Test func inventoryListsAvailableExpiriesSoonestFirst() throws {
    let summary = RPCResetCreditsSummary(availableCount: 3, credits: [
        credit("never", expiry: .never),
        credit("monday", expiry: .at(seconds(5 * 86_400))),
        credit("thursday", expiry: .at(seconds(2 * 86_400))),
        credit("gone", expiry: .at(seconds(-60))),
        credit("used", expiry: .at(seconds(86_400)), status: "redeemed"),
        credit("other", expiry: .at(seconds(3_600)), resetType: "unknown"),
    ])
    let snapshot = summary.inventorySnapshot(fetchedAt: now)
    #expect(snapshot.expiries == .listed([
        .on(now.addingTimeInterval(2 * 86_400)),
        .on(now.addingTimeInterval(5 * 86_400)),
        .never,
    ]))
    #expect(snapshot.isComplete)
    #expect(snapshot.nextExpiry(after: now) == now.addingTimeInterval(2 * 86_400))
    #expect(snapshot.nextExpiry(after: now.addingTimeInterval(3 * 86_400)) == now.addingTimeInterval(5 * 86_400))
    #expect(snapshot.expiryOutlook(after: now.addingTimeInterval(6 * 86_400)) == .unknown)
}

@Test func omittedInventoryKeepsLastKnownSnapshotAndItsTime() throws {
    var record = codexRecord(try observation(inventory: RPCResetCreditsSummary(availableCount: 1, credits: nil)))
    let later = now.addingTimeInterval(60)
    record.recordSuccess(try observation(codexSnapshot(observedAt: later), inventory: nil))
    let reading = record.reading(at: later)
    #expect(reading.freshness == .fresh(lastSuccessAt: later))
    #expect(reading.inventory == .unknown(lastKnown: ResetInventorySnapshot(
        availableCount: 1, expiries: .unlisted, fetchedAt: now
    )))
}

@Test func freshnessMovesThroughFreshStaleFailedAndRecovers() throws {
    var record = QuotaAccountRecord(provider: .codex, accountID: UUID())
    #expect(record.reading(at: now).freshness == .missing)

    record.recordSuccess(try observation())
    #expect(record.reading(at: now.addingTimeInterval(119)).freshness == .fresh(lastSuccessAt: now))
    let stale = record.reading(at: now.addingTimeInterval(121))
    #expect(stale.freshness == .stale(lastSuccessAt: now))
    #expect(stale.windows.allSatisfy { !$0.isCurrent })
    #expect(stale.windows.map(\.window.remainingPercent) == [60, 75])

    let failedAt = now.addingTimeInterval(30)
    record.recordFailure(.unavailable, at: failedAt)
    let failed = record.reading(at: failedAt)
    #expect(failed.freshness == .failed(.unavailable, failedAt: failedAt, lastSuccessAt: now))
    #expect(failed.freshness.lastSuccessAt == now)
    #expect(failed.windows.map(\.window.remainingPercent) == [60, 75])
    #expect(failed.windows.allSatisfy { !$0.isCurrent })
    #expect(failed.inventory == .known(
        ResetInventorySnapshot(availableCount: 0, expiries: .listed([]), fetchedAt: now),
        isCurrent: false
    ))
    #expect(!failed.isConfirmed)

    let recoveredAt = now.addingTimeInterval(90)
    record.recordSuccess(try observation(codexSnapshot(observedAt: recoveredAt)))
    let recovered = record.reading(at: recoveredAt)
    #expect(recovered.freshness == .fresh(lastSuccessAt: recoveredAt))
    #expect(recovered.isConfirmed)
}

@Test func passedResetWaitsForConfirmationInsteadOfWarning() throws {
    let record = codexRecord(try observation(codexSnapshot(session: 100, weekly: 25)))
    let afterSessionReset = now.addingTimeInterval(3_601)
    let reading = record.reading(at: afterSessionReset, policy: QuotaReadPolicy(staleAfter: 7_200))
    #expect(reading.freshness.isFresh)
    let session = try #require(reading.windows.first { $0.window.kind == .session })
    #expect(session.resetPassed)
    #expect(!session.isCurrent)
    #expect(session.window.remainingPercent == 0)
    #expect(reading.mostConstrained?.window.kind == .weekly)
    #expect(reading.warning == nil)
    #expect(!reading.isConfirmed)
    let summary = QuotaSummary(readings: [reading])
    #expect(summary.warnings.isEmpty)
    #expect(summary.lowestCurrentRemainingPercent == 75)
    #expect(!summary.isAllClear)
}

@Test func passedSavedResetExpiryMakesInventoryHistoricalAndBlocksAllClear() throws {
    let inventory = RPCResetCreditsSummary(availableCount: 1, credits: [credit("soon", expiry: .at(seconds(30)))])
    let reading = codexRecord(try observation(inventory: inventory)).reading(at: now.addingTimeInterval(31))
    guard case let .known(_, isCurrent) = reading.inventory else {
        Issue.record("Expected the last count")
        return
    }
    #expect(!isCurrent)
    #expect(reading.hasConfirmedWindows)
    #expect(!reading.isConfirmed)
    #expect(!QuotaSummary(readings: [reading]).isAllClear)
}

@Test func codexAllClearNeedsCurrentAuthoritativeInventory() throws {
    let unknown = codexRecord(try observation(inventory: nil)).reading(at: now)
    #expect(unknown.hasConfirmedWindows)
    #expect(unknown.inventory == .unknown(lastKnown: nil))
    #expect(!unknown.isConfirmed)
    #expect(!QuotaSummary(readings: [unknown]).isAllClear)

    var record = codexRecord(try observation(inventory: RPCResetCreditsSummary(availableCount: 2, credits: nil)))
    let later = now.addingTimeInterval(60)
    record.recordSuccess(try observation(codexSnapshot(observedAt: later), inventory: nil))
    let lastKnownOnly = record.reading(at: later)
    #expect(lastKnownOnly.inventory == .unknown(lastKnown: ResetInventorySnapshot(
        availableCount: 2, expiries: .unlisted, fetchedAt: now
    )))
    #expect(lastKnownOnly.windows.allSatisfy { $0.isCurrent })
    #expect(!QuotaSummary(readings: [lastKnownOnly]).isAllClear)

    let counted = codexRecord(try observation(inventory: RPCResetCreditsSummary(availableCount: 2, credits: nil)))
    #expect(QuotaSummary(readings: [counted.reading(at: now)]).isAllClear)
}

@Test(arguments: [
    (IncludedUsageAccess.unreported, true),
    (.allowed, true),
    (.unknown, false),
    (.blocked, false),
])
func includedUsageAccessGatesAllClearButKeepsPercentages(access: IncludedUsageAccess, clear: Bool) throws {
    let reading = codexRecord(try observation(access: access)).reading(at: now)
    #expect(reading.includedUsageAccess == access)
    #expect(reading.windows.map(\.window.remainingPercent) == [60, 75])
    #expect(reading.windows.allSatisfy { $0.isCurrent })
    #expect(reading.hasConfirmedWindows)
    #expect(reading.isConfirmed == clear)
    #expect(QuotaSummary(readings: [reading]).isAllClear == clear)
}

@Test func secondWeeklyLaneMakesTheWeekUnknownEvenWithoutItsReset() throws {
    let snapshot = RateLimitSnapshot(
        limitID: "codex",
        primary: RateLimitWindow(usedPercent: 10, windowDurationMinutes: 10_080, resetsAt: now.addingTimeInterval(9_000)),
        secondary: RateLimitWindow(usedPercent: 90, windowDurationMinutes: 10_080, resetsAt: nil),
        observedAt: now
    )
    #expect(RateLimitClassifier().classify(snapshot, now: now) == .rejected(.ambiguousWeeklyWindows))
    let reading = codexRecord(try observation(snapshot)).reading(at: now)
    #expect(!reading.windows.contains { $0.window.kind == .weekly })
    #expect(reading.unknownWindows.contains(.weekly))
    #expect(!QuotaSummary(readings: [reading]).isAllClear)
}

@Test func explicitNullNeverExpiresButAMissingExpiryStaysUnknown() throws {
    let json = Data("""
    {
      "rateLimits": {"limitId": "codex",
        "primary": {"usedPercent": 10, "windowDurationMins": 300, "resetsAt": 2000003600},
        "secondary": {"usedPercent": 20, "windowDurationMins": 10080, "resetsAt": 2000345600}},
      "rateLimitResetCredits": {"availableCount": 3, "credits": [
        {"id": "a", "resetType": "codexRateLimits", "status": "available", "grantedAt": 1999990000, "expiresAt": null},
        {"id": "b", "resetType": "codexRateLimits", "status": "available", "grantedAt": 1999990000},
        {"id": "c", "resetType": "codexRateLimits", "status": "available", "grantedAt": 1999990000, "expiresAt": 2000172800}
      ]},
      "ordinaryUsageAllowed": true
    }
    """.utf8)
    let response = try JSONDecoder().decode(RPCRateLimitsReadResponse.self, from: json)
    let credits = try #require(response.rateLimitResetCredits?.credits)
    #expect(credits.map(\.expiry) == [.never, .unspecified, .at(2_000_172_800)])
    // The reset policy keeps its old view of both: no expiry date.
    #expect(credits.map(\.expiresAt) == [nil, nil, 2_000_172_800])
    #expect(response.rateLimitResetCredits?.domainValue().credits?.map(\.expiresAt) == [
        nil, nil, Date(timeIntervalSince1970: 2_000_172_800),
    ])

    let observation = try #require(response.quotaObservation(observedAt: now, classifier: RateLimitClassifier()))
    #expect(observation.includedUsageAccess == .allowed)
    guard case let .reported(snapshot) = observation.inventory else {
        Issue.record("Expected reported inventory")
        return
    }
    #expect(snapshot.expiries == .listed([.on(Date(timeIntervalSince1970: 2_000_172_800)), .never, .unspecified]))
    #expect(snapshot.isComplete)
    #expect(snapshot.nextExpiry(after: now) == nil)
    #expect(snapshot.expiryOutlook(after: now) == .unknown)

    let roundTrip = try JSONDecoder().decode(
        RPCRateLimitsReadResponse.self,
        from: JSONEncoder().encode(response)
    )
    #expect(roundTrip == response)
}

@Test func cappedCreditListNeverClaimsTheNextOverallExpiryOrNever() throws {
    let json = Data("""
    {"availableCount": 4, "credits": [
      {"id": "a", "resetType": "codexRateLimits", "status": "available", "grantedAt": 1999990000, "expiresAt": 2000172800},
      {"id": "b", "resetType": "codexRateLimits", "status": "available", "grantedAt": 1999990000, "expiresAt": null}
    ]}
    """.utf8)
    let capped = try JSONDecoder().decode(RPCResetCreditsSummary.self, from: json).inventorySnapshot(fetchedAt: now)
    #expect(capped.availableCount == 4)
    #expect(capped.expiries == .listed([.on(Date(timeIntervalSince1970: 2_000_172_800)), .never]))
    #expect(!capped.isComplete)
    #expect(capped.nextExpiry(after: now) == nil)
    #expect(capped.expiryOutlook(after: now) == .unknown)

    let neverOnly = RPCResetCreditsSummary(availableCount: 1, credits: [credit("n", expiry: .never)])
        .inventorySnapshot(fetchedAt: now)
    #expect(neverOnly.expiryOutlook(after: now) == .never)
    let none = RPCResetCreditsSummary(availableCount: 0, credits: []).inventorySnapshot(fetchedAt: now)
    #expect(none.expiryOutlook(after: now) == .noneSaved)
    #expect(RPCResetCreditsSummary(availableCount: 2, credits: nil).inventorySnapshot(fetchedAt: now)
        .expiryOutlook(after: now) == .unknown)
}

@Test(arguments: [
    (#""#, IncludedUsageAccess.unreported),
    (#", "ordinaryUsageAllowed": null"#, .unknown),
    (#", "ordinaryUsageAllowed": false"#, .blocked),
    (#", "ordinaryUsageAllowed": true"#, .allowed),
    (#", "ordinaryUsageAllowed": "yes""#, .unknown),
])
func ordinaryUsageAllowedDecodesFourWays(field: String, expected: IncludedUsageAccess) throws {
    let json = Data(#"{"rateLimits": {"limitId": "codex"}\#(field)}"#.utf8)
    let response = try JSONDecoder().decode(RPCRateLimitsReadResponse.self, from: json)
    #expect(response.includedUsageAccess == expected)
    if expected != .unknown || field.contains("null") {
        let roundTrip = try JSONDecoder().decode(RPCRateLimitsReadResponse.self, from: JSONEncoder().encode(response))
        #expect(roundTrip.includedUsageAccess == expected)
    }
}

@Test func allClearNeedsEveryAccountCurrentAndNoneLow() throws {
    let healthy = codexRecord(try observation()).reading(at: now)
    let claude = QuotaAccountRecord(
        provider: .claude,
        accountID: UUID(),
        lastSuccess: ClaudeUsageReport(
            session: ClaudeUsageWindow(scope: .session, usedPercent: 20, resetsAt: now.addingTimeInterval(600)),
            weekly: ClaudeUsageWindow(scope: .weekly, usedPercent: 30, resetsAt: now.addingTimeInterval(86_400)),
            observedAt: now
        ).quotaObservation
    ).reading(at: now)
    #expect(claude.inventory == .notTracked)
    #expect(QuotaSummary(readings: [healthy, claude]).isAllClear)
    #expect(!QuotaSummary(readings: []).isAllClear)

    let neverRead = QuotaAccountRecord(provider: .claude, accountID: UUID()).reading(at: now)
    let pending = QuotaSummary(readings: [healthy, neverRead])
    #expect(!pending.isAllClear)
    #expect(pending.unconfirmedAccountIDs == [neverRead.id])

    var failing = codexRecord(try observation())
    failing.recordFailure(.signInRequired, at: now)
    #expect(!QuotaSummary(readings: [healthy, failing.reading(at: now)]).isAllClear)

    let stale = codexRecord(try observation()).reading(at: now.addingTimeInterval(500))
    #expect(!QuotaSummary(readings: [claude, stale]).isAllClear)
}

@Test func claudeWindowWithoutResetTimeStaysCurrentLikePreflight() {
    let reading = QuotaAccountRecord(
        provider: .claude,
        accountID: UUID(),
        lastSuccess: ClaudeUsageReport(
            session: ClaudeUsageWindow(scope: .session, usedPercent: 20, resetsAt: nil),
            weekly: ClaudeUsageWindow(scope: .weekly, usedPercent: 30, resetsAt: now.addingTimeInterval(86_400)),
            observedAt: now
        ).quotaObservation
    ).reading(at: now)
    #expect(reading.windows.allSatisfy { $0.isCurrent && !$0.resetPassed })
    #expect(reading.isConfirmed)
}

@Test func claudeSessionOnlyReportKeepsDataButIsNeverAllClear() {
    let reading = QuotaAccountRecord(
        provider: .claude,
        accountID: UUID(),
        lastSuccess: ClaudeUsageReport(
            session: ClaudeUsageWindow(scope: .session, usedPercent: 20, resetsAt: now.addingTimeInterval(600)),
            weekly: nil,
            observedAt: now
        ).quotaObservation
    ).reading(at: now)
    #expect(reading.windows.map(\.window.kind) == [.session])
    #expect(reading.windows.allSatisfy { $0.isCurrent })
    #expect(reading.unknownWindows == [.weekly])
    #expect(!reading.isConfirmed)
    #expect(!QuotaSummary(readings: [reading]).isAllClear)
}

@Test func unreadableClaudeModelLimitIsUnknownNotDropped() throws {
    let text = """
    Current session: 20% used · resets 9:40pm (UTC)
    Current week (all models): 30% used · resets Jan 2, 2034 at 3am (UTC)
    Current week (Sonnet only): unavailable
    """
    let report = try ClaudeUsageParser.parseText(text, observedAt: now)
    #expect(report.modelWeekly.isEmpty)
    #expect(report.unreadableScopes == [.modelWeekly("Sonnet only")])
    let reading = QuotaAccountRecord(provider: .claude, accountID: UUID(), lastSuccess: report.quotaObservation)
        .reading(at: now)
    #expect(reading.windows.map(\.window.kind) == [.session, .weekly])
    #expect(reading.unknownWindows == [.modelWeekly("Sonnet only")])
    #expect(!QuotaSummary(readings: [reading]).isAllClear)

    for empty in ["Current week (Sonnet only): ", "Current week (Sonnet only):"] {
        let blank = try ClaudeUsageParser.parseText(
            "Current session: 20% used · resets 9:40pm (UTC)\n" + empty,
            observedAt: now
        )
        #expect(blank.unreadableScopes == [.modelWeekly("Sonnet only")])
    }
    #expect(throws: ClaudeUsageParseError.malformedOutput) {
        try ClaudeUsageParser.parseText("Current session: unavailable", observedAt: now)
    }
    #expect(throws: ClaudeUsageParseError.malformedOutput) {
        try ClaudeUsageParser.parseText(text + "\nCurrent week (Sonnet only): 10% used", observedAt: now)
    }
}

@Test func claudeReportSavedBeforeUnreadableScopesStillDecodes() throws {
    let legacy = Data(#"{"modelWeekly":[],"observedAt":0,"session":{"scope":{"session":{}},"usedPercent":20}}"#.utf8)
    let report = try JSONDecoder().decode(ClaudeUsageReport.self, from: legacy)
    #expect(report.unreadableScopes.isEmpty)
    #expect(report.session?.usedPercent == 20)
}

@Test func restoredReadingIsUnverifiedUntilAFreshRefresh() {
    let report = ClaudeUsageReport(
        session: ClaudeUsageWindow(scope: .session, usedPercent: 92, resetsAt: now.addingTimeInterval(3_600)),
        weekly: ClaudeUsageWindow(scope: .weekly, usedPercent: 30, resetsAt: now.addingTimeInterval(86_400)),
        observedAt: now
    )
    var record = QuotaAccountRecord(
        provider: .claude, accountID: UUID(),
        lastSuccess: report.quotaObservation, lastSuccessRestored: true
    )
    let restored = record.reading(at: now.addingTimeInterval(10))
    #expect(restored.isRestoredUnverified)
    #expect(restored.freshness == .stale(lastSuccessAt: now))
    #expect(restored.windows.allSatisfy { !$0.isCurrent })
    #expect(restored.currentLowWindows.isEmpty)
    #expect(!QuotaSummary(readings: [restored]).isAllClear)

    var failed = record
    failed.recordFailure(.unavailable, at: now.addingTimeInterval(10))
    let afterFailure = failed.reading(at: now.addingTimeInterval(10))
    #expect(!afterFailure.isRestoredUnverified)
    #expect(afterFailure.freshness == .failed(.unavailable, failedAt: now.addingTimeInterval(10), lastSuccessAt: now))

    record.recordSuccess(report.quotaObservation)
    #expect(record.reading(at: now.addingTimeInterval(10)).freshness == .fresh(lastSuccessAt: now))
}

@Test func codexWindowWithoutResetTimeIsIncompleteAndBlocksAllClear() throws {
    let snapshot = RateLimitSnapshot(
        limitID: "codex",
        primary: RateLimitWindow(usedPercent: 40, windowDurationMinutes: 300, resetsAt: nil),
        secondary: RateLimitWindow(usedPercent: 25, windowDurationMinutes: 10_080, resetsAt: now.addingTimeInterval(9_000)),
        observedAt: now
    )
    let reading = codexRecord(try observation(snapshot)).reading(at: now)
    #expect(reading.windows.map(\.window.kind) == [.weekly])
    #expect(reading.unknownWindows == [.session])
    #expect(!QuotaSummary(readings: [reading]).isAllClear)
}

@Test func futureReadingAndExactDeadlineAreNotCurrent() throws {
    let record = codexRecord(try observation())
    #expect(record.reading(at: now.addingTimeInterval(119.9)).freshness == .fresh(lastSuccessAt: now))
    #expect(record.reading(at: now.addingTimeInterval(120)).freshness == .stale(lastSuccessAt: now))
    let early = record.reading(at: now.addingTimeInterval(-1))
    #expect(early.freshness == .stale(lastSuccessAt: now))
    #expect(early.windows.allSatisfy { !$0.isCurrent })
    #expect(!QuotaSummary(readings: [early]).isAllClear)
}

@Test func warningsSortMostSevereFirstAndKeyByAccountWindowAndReset() throws {
    let exhausted = codexRecord(try observation(codexSnapshot(session: 100, weekly: 50))).reading(at: now)
    let low = codexRecord(try observation(codexSnapshot(session: 10, weekly: 95))).reading(at: now)
    let summary = QuotaSummary(readings: [low, exhausted])
    #expect(summary.warnings.map(\.window.level) == [.exhausted, .low])
    #expect(summary.warnings.map(\.accountID) == [exhausted.accountID, low.accountID])
    let key = try #require(summary.warnings.first?.alertKey)
    #expect(key.hasPrefix("codex:\(exhausted.accountID.uuidString.lowercased())|session@"))
}

@Test func claudeReportKeepsEveryWindowKind() {
    let report = ClaudeUsageReport(
        session: ClaudeUsageWindow(scope: .session, usedPercent: 91, resetsAt: now.addingTimeInterval(600)),
        weekly: ClaudeUsageWindow(scope: .weekly, usedPercent: 10, resetsAt: now.addingTimeInterval(86_400)),
        modelWeekly: [ClaudeUsageWindow(scope: .modelWeekly("Sonnet only"), usedPercent: 50, resetsAt: nil)],
        observedAt: now
    )
    let reading = QuotaAccountRecord(provider: .claude, accountID: UUID(), lastSuccess: report.quotaObservation)
        .reading(at: now)
    #expect(reading.windows.map(\.window.kind) == [.session, .weekly, .modelWeekly("Sonnet only")])
    #expect(reading.warning?.window.kind == .session)
    #expect(reading.freshness == .fresh(lastSuccessAt: now))
}

@Test func claudeStalenessUsesItsSlowerPollingCycle() {
    let record = QuotaAccountRecord(
        provider: .claude,
        accountID: UUID(),
        lastSuccess: ClaudeUsageReport(
            session: ClaudeUsageWindow(scope: .session, usedPercent: 10, resetsAt: now.addingTimeInterval(9_000)),
            weekly: nil,
            observedAt: now
        ).quotaObservation
    )
    #expect(record.reading(at: now.addingTimeInterval(599)).freshness.isFresh)
    #expect(record.reading(at: now.addingTimeInterval(600)).freshness == .stale(lastSuccessAt: now))
}
