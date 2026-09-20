import Foundation
import Testing
@testable import CodexWeeklyResetGuardCore

@Suite struct ResetPolicyEngineTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private let resetAt = Date(timeIntervalSince1970: 2_500_000)
    private let engine = ResetPolicyEngine()

    @Test func testRequiresTwoFreshReadingsAtOrBelowThreePercent() throws {
        let first = engine.evaluate(
            weeklyLimit: weekly(used: 97, observedAt: now),
            inventory: inventory(),
            state: state(),
            now: now,
            newIdempotencyKey: "attempt-1"
        )
        XCTAssertEqual(first.reason, .firstConfirmation)
        XCTAssertEqual(first.state.phase, .confirming)
        XCTAssertEqual(first.state.confirmation?.count, 1)
        XCTAssertEqual(first.action, .none)

        let secondTime = now.addingTimeInterval(5)
        let second = engine.evaluate(
            weeklyLimit: weekly(used: 97.5, observedAt: secondTime),
            inventory: inventory(),
            state: first.state,
            now: secondTime,
            newIdempotencyKey: "attempt-1"
        )

        guard case let .persistThenConsume(attempt) = second.action else {
            return XCTFail("Expected a durable redemption attempt")
        }
        XCTAssertEqual(attempt.idempotencyKey, "attempt-1")
        XCTAssertEqual(attempt.creditID, "expires-first")
        XCTAssertEqual(attempt.phase, .prepared)
        XCTAssertEqual(second.state.attempt, attempt)
        XCTAssertEqual(second.state.phase, .redeeming)
    }

    @Test func testExactlyThreePercentRemainingQualifies() {
        let first = engine.evaluate(
            weeklyLimit: weekly(used: 97),
            inventory: inventory(),
            state: state(),
            now: now
        )
        XCTAssertEqual(first.state.phase, .confirming)
    }

    @Test func testFirstReadingExpiresAfterSleepAndRequiresANewPair() {
        let credits = ResetCreditInventory(availableCount: 1, credits: nil)
        let first = engine.evaluate(
            weeklyLimit: weekly(used: 98),
            inventory: credits,
            state: state(),
            now: now
        )
        let wakeTime = now.addingTimeInterval(3_600)
        let resumed = engine.evaluate(
            weeklyLimit: weekly(used: 99, observedAt: wakeTime),
            inventory: credits,
            state: first.state,
            now: wakeTime,
            newIdempotencyKey: "must-not-use"
        )

        XCTAssertEqual(resumed.action, .none)
        XCTAssertEqual(resumed.reason, .firstConfirmation)
        XCTAssertEqual(resumed.state.confirmation?.count, 1)
        XCTAssertEqual(resumed.state.confirmation?.firstObservedAt, wakeTime)

        let secondTime = wakeTime.addingTimeInterval(5)
        let confirmed = engine.evaluate(
            weeklyLimit: weekly(used: 99, observedAt: secondTime),
            inventory: credits,
            state: resumed.state,
            now: secondTime,
            newIdempotencyKey: "fresh-pair"
        )
        guard case let .persistThenConsume(attempt) = confirmed.action else {
            return XCTFail("Expected redemption only after a new, spaced pair")
        }
        XCTAssertEqual(attempt.idempotencyKey, "fresh-pair")
    }

    @Test func testDuplicateReadingDoesNotCountAsSecondConfirmation() {
        let reading = weekly(used: 99, observedAt: now)
        let first = engine.evaluate(
            weeklyLimit: reading,
            inventory: inventory(),
            state: state(),
            now: now
        )
        let duplicate = engine.evaluate(
            weeklyLimit: reading,
            inventory: inventory(),
            state: first.state,
            now: now.addingTimeInterval(1),
            newIdempotencyKey: "must-not-use"
        )

        XCTAssertEqual(duplicate.reason, .duplicateReading)
        XCTAssertEqual(duplicate.state.confirmation?.count, 1)
        XCTAssertEqual(duplicate.action, .none)
    }

    @Test func testConfirmationLessThanFiveSecondsLaterDoesNotCount() {
        let first = engine.evaluate(
            weeklyLimit: weekly(used: 99, observedAt: now),
            inventory: inventory(),
            state: state(),
            now: now
        )
        let tooSoonTime = now.addingTimeInterval(4.99)
        let tooSoon = engine.evaluate(
            weeklyLimit: weekly(used: 100, observedAt: tooSoonTime),
            inventory: inventory(),
            state: first.state,
            now: tooSoonTime,
            newIdempotencyKey: "must-not-use"
        )

        XCTAssertEqual(tooSoon.reason, .confirmationTooSoon)
        XCTAssertEqual(tooSoon.state.confirmation?.count, 1)
        XCTAssertEqual(tooSoon.action, .none)

        let freshTime = now.addingTimeInterval(5)
        let fresh = engine.evaluate(
            weeklyLimit: weekly(used: 100, observedAt: freshTime),
            inventory: inventory(),
            state: tooSoon.state,
            now: freshTime,
            newIdempotencyKey: "fresh-key"
        )
        guard case let .persistThenConsume(attempt) = fresh.action else {
            return XCTFail("Expected a redemption after a properly spaced confirmation")
        }
        XCTAssertEqual(attempt.idempotencyKey, "fresh-key")
    }

    @Test func testChangedResetEpochRestartsConfirmation() {
        let first = engine.evaluate(
            weeklyLimit: weekly(used: 99),
            inventory: inventory(),
            state: state(),
            now: now
        )
        let later = now.addingTimeInterval(5)
        let newEpochReading = CanonicalWeeklyLimit(
            lane: .secondary,
            usedPercent: 100,
            durationMinutes: 10_080,
            resetsAt: resetAt.addingTimeInterval(60),
            observedAt: later
        )
        let evaluation = engine.evaluate(
            weeklyLimit: newEpochReading,
            inventory: inventory(),
            state: first.state,
            now: later,
            newIdempotencyKey: "must-not-use"
        )

        XCTAssertEqual(evaluation.reason, .resetEpochChanged)
        XCTAssertEqual(evaluation.state.confirmation?.count, 1)
        XCTAssertEqual(evaluation.state.confirmation?.weeklyResetAt, newEpochReading.resetsAt)
        XCTAssertEqual(evaluation.action, .none)
    }

    @Test func testNearAndHealthyReadingsNeverRedeem() {
        let near = engine.evaluate(
            weeklyLimit: weekly(used: 95),
            inventory: inventory(),
            state: state(),
            now: now,
            newIdempotencyKey: "unused"
        )
        let healthy = engine.evaluate(
            weeklyLimit: weekly(used: 50),
            inventory: inventory(),
            state: near.state,
            now: now,
            newIdempotencyKey: "unused"
        )

        XCTAssertEqual(near.state.phase, .nearLimit)
        XCTAssertEqual(near.action, .none)
        XCTAssertEqual(healthy.state.phase, .healthy)
        XCTAssertNil(healthy.state.confirmation)
        XCTAssertEqual(healthy.action, .none)
    }

    @Test func testFiveHourExhaustionDoesNotAffectWeeklyPolicy() throws {
        let classifier = RateLimitClassifier()
        let snapshot = RateLimitSnapshot(
            limitID: "codex",
            primary: RateLimitWindow(
                usedPercent: 100,
                windowDurationMinutes: 300,
                resetsAt: now.addingTimeInterval(300)
            ),
            secondary: RateLimitWindow(
                usedPercent: 40,
                windowDurationMinutes: 10_080,
                resetsAt: resetAt
            ),
            observedAt: now
        )
        guard case let .canonical(weeklyLimit) = classifier.classify(snapshot, now: now) else {
            return XCTFail("Expected canonical weekly window")
        }

        let evaluation = engine.evaluate(
            weeklyLimit: weeklyLimit,
            inventory: inventory(),
            state: state(),
            now: now,
            newIdempotencyKey: "unused"
        )
        XCTAssertEqual(evaluation.state.phase, .healthy)
        XCTAssertEqual(evaluation.action, .none)
    }

    @Test func testNoCreditsBlocksRedemptionAfterConfirmation() {
        let first = engine.evaluate(
            weeklyLimit: weekly(used: 99),
            inventory: ResetCreditInventory(availableCount: 0, credits: []),
            state: state(),
            now: now
        )
        let later = now.addingTimeInterval(5)
        let second = engine.evaluate(
            weeklyLimit: weekly(used: 100, observedAt: later),
            inventory: ResetCreditInventory(availableCount: 0, credits: []),
            state: first.state,
            now: later,
            newIdempotencyKey: "unused"
        )

        XCTAssertEqual(second.state.phase, .noCredits)
        XCTAssertEqual(second.reason, .noCredits)
        XCTAssertNil(second.state.attempt)
        XCTAssertEqual(second.action, .none)
    }

    @Test func testAuthoritativeCountAllowsRedemptionWhenCreditDetailsAreAbsent() {
        let first = engine.evaluate(
            weeklyLimit: weekly(used: 99),
            inventory: ResetCreditInventory(availableCount: 2, credits: nil),
            state: state(),
            now: now
        )
        let later = now.addingTimeInterval(5)
        let second = engine.evaluate(
            weeklyLimit: weekly(used: 100, observedAt: later),
            inventory: ResetCreditInventory(availableCount: 2, credits: nil),
            state: first.state,
            now: later,
            newIdempotencyKey: "backend-selects"
        )

        guard case let .persistThenConsume(attempt) = second.action else {
            return XCTFail("Expected a redemption attempt")
        }
        XCTAssertNil(attempt.creditID)
        XCTAssertEqual(attempt.availableCreditCountBefore, 2)
    }

    @Test func testPresentDetailsWithoutEligibleCodexCreditFailClosed() {
        let unusableInventory = ResetCreditInventory(
            availableCount: 2,
            credits: [
                ResetCredit(
                    id: "wrong-kind",
                    kind: .unknown("sparkRateLimits"),
                    status: .available,
                    grantedAt: now,
                    expiresAt: now.addingTimeInterval(1_000)
                ),
                ResetCredit(
                    id: "expired",
                    kind: .codexRateLimits,
                    status: .available,
                    grantedAt: now.addingTimeInterval(-2_000),
                    expiresAt: now.addingTimeInterval(-1)
                ),
            ]
        )
        let first = engine.evaluate(
            weeklyLimit: weekly(used: 99),
            inventory: unusableInventory,
            state: state(),
            now: now
        )
        let later = now.addingTimeInterval(5)
        let second = engine.evaluate(
            weeklyLimit: weekly(used: 100, observedAt: later),
            inventory: unusableInventory,
            state: first.state,
            now: later,
            newIdempotencyKey: "must-not-use"
        )

        XCTAssertEqual(second.reason, .noCredits)
        XCTAssertEqual(second.state.phase, .noCredits)
        XCTAssertNil(second.state.attempt)
        XCTAssertEqual(second.action, .none)
    }

    @Test func testEarliestExpiringAvailableCodexCreditIsSelected() {
        let selected = inventory().earliestExpiringAvailableCodexCredit(at: now)
        XCTAssertEqual(selected?.id, "expires-first")
    }

    @Test func testStaleAndFutureReadingsFailClosed() {
        let stale = engine.evaluate(
            weeklyLimit: weekly(used: 100, observedAt: now.addingTimeInterval(-121)),
            inventory: inventory(),
            state: state(),
            now: now
        )
        let future = engine.evaluate(
            weeklyLimit: weekly(used: 100, observedAt: now.addingTimeInterval(6)),
            inventory: inventory(),
            state: state(),
            now: now
        )

        XCTAssertEqual(stale.reason, .staleReading)
        XCTAssertEqual(stale.state.phase, .attentionRequired)
        XCTAssertEqual(future.reason, .futureReading)
        XCTAssertEqual(future.state.phase, .attentionRequired)
    }

    @Test func testMissingIdempotencyKeyFailsClosedAfterConfirmation() {
        let first = engine.evaluate(
            weeklyLimit: weekly(used: 99),
            inventory: inventory(),
            state: state(),
            now: now
        )
        let later = now.addingTimeInterval(5)
        let second = engine.evaluate(
            weeklyLimit: weekly(used: 100, observedAt: later),
            inventory: inventory(),
            state: first.state,
            now: later,
            newIdempotencyKey: "  "
        )

        XCTAssertEqual(second.reason, .missingIdempotencyKey)
        XCTAssertEqual(second.state.phase, .attentionRequired)
        XCTAssertNil(second.state.attempt)
    }

    @Test func testAmbiguousFailureRetriesSameDurableIdempotencyKey() throws {
        let prepared = try preparedState(idempotencyKey: "stable-key")
        let started = try engine.markRequestStarted(in: prepared, at: now.addingTimeInterval(10))
        let failed = try engine.recordAmbiguousFailure(in: started, at: now.addingTimeInterval(11))

        XCTAssertEqual(failed.attempt?.phase, .retryable)
        XCTAssertEqual(failed.attempt?.idempotencyKey, "stable-key")

        let evaluation = engine.evaluate(
            weeklyLimit: weekly(used: 100, observedAt: now.addingTimeInterval(12)),
            inventory: inventory(),
            state: failed,
            now: now.addingTimeInterval(12),
            newIdempotencyKey: "different-key-must-not-be-used"
        )
        guard case let .retryConsume(attempt) = evaluation.action else {
            return XCTFail("Expected idempotent retry")
        }
        XCTAssertEqual(attempt.idempotencyKey, "stable-key")
    }

    @Test func testResetAndAlreadyRedeemedBothAwaitVerification() throws {
        for outcome in [ConsumeResetOutcome.reset, .alreadyRedeemed] {
            let started = try engine.markRequestStarted(
                in: preparedAttemptState(idempotencyKey: "key-\(outcome.rawValue)"),
                at: now
            )
            let result = try engine.recordConsumeOutcome(
                outcome,
                in: started,
                at: now.addingTimeInterval(1)
            )
            XCTAssertEqual(result.attempt?.phase, .awaitingVerification)
            XCTAssertEqual(result.phase, .verifying)
        }
    }

    @Test func testVerificationRequiresWeeklyRecoveryAndCreditDecrease() throws {
        let started = try engine.markRequestStarted(
            in: preparedAttemptState(idempotencyKey: "verify-key"),
            at: now
        )
        let awaiting = try engine.recordConsumeOutcome(
            .reset,
            in: started,
            at: now.addingTimeInterval(1)
        )
        let verified = try engine.reconcileVerification(
            weeklyLimit: CanonicalWeeklyLimit(
                lane: .secondary,
                usedPercent: 0,
                durationMinutes: 10_080,
                resetsAt: resetAt.addingTimeInterval(7 * 24 * 60 * 60),
                observedAt: now.addingTimeInterval(2)
            ),
            inventory: inventoryAfterSelectedCreditConsumed(),
            in: awaiting,
            now: now.addingTimeInterval(2)
        )

        XCTAssertEqual(verified.attempt?.phase, .succeeded)
        XCTAssertEqual(verified.phase, .verified)
    }

    @Test func testCreditDisappearanceWithoutWeeklyRecoveryRequiresAttention() throws {
        let started = try engine.markRequestStarted(
            in: preparedAttemptState(idempotencyKey: "bad-verification"),
            at: now
        )
        let awaiting = try engine.recordConsumeOutcome(
            .reset,
            in: started,
            at: now.addingTimeInterval(1)
        )
        let failed = try engine.reconcileVerification(
            weeklyLimit: weekly(used: 99, observedAt: now.addingTimeInterval(2)),
            inventory: inventoryAfterSelectedCreditConsumed(),
            in: awaiting,
            now: now.addingTimeInterval(2)
        )

        XCTAssertEqual(failed.attempt?.phase, .verificationFailed)
        XCTAssertEqual(failed.phase, .attentionRequired)
        XCTAssertNotNil(failed.attentionMessage)
    }

    @Test func testTinyUsageJitterCannotVerifyAReset() throws {
        let started = try engine.markRequestStarted(
            in: preparedAttemptState(idempotencyKey: "jitter", used: 98),
            at: now
        )
        let awaiting = try engine.recordConsumeOutcome(
            .reset,
            in: started,
            at: now.addingTimeInterval(1)
        )
        let result = try engine.reconcileVerification(
            weeklyLimit: weekly(used: 97, observedAt: now.addingTimeInterval(2)),
            inventory: inventoryAfterSelectedCreditConsumed(),
            in: awaiting,
            now: now.addingTimeInterval(2)
        )

        XCTAssertEqual(result.attempt?.phase, .verificationFailed)
        XCTAssertEqual(result.phase, .attentionRequired)
    }

    @Test func testChangedResetEpochWhileStillDepletedCannotVerifyAReset() throws {
        let started = try engine.markRequestStarted(
            in: preparedAttemptState(idempotencyKey: "epoch", used: 98),
            at: now
        )
        let awaiting = try engine.recordConsumeOutcome(
            .reset,
            in: started,
            at: now.addingTimeInterval(1)
        )
        var depleted = weekly(used: 98, observedAt: now.addingTimeInterval(2))
        depleted.resetsAt = resetAt.addingTimeInterval(7 * 24 * 60 * 60)
        let result = try engine.reconcileVerification(
            weeklyLimit: depleted,
            inventory: inventoryAfterSelectedCreditConsumed(),
            in: awaiting,
            now: now.addingTimeInterval(2)
        )

        XCTAssertEqual(result.attempt?.phase, .verificationFailed)
        XCTAssertEqual(result.phase, .attentionRequired)
    }

    @Test func testUnrelatedCreditCountDecreaseCannotVerifySelectedCredit() throws {
        let started = try engine.markRequestStarted(
            in: preparedAttemptState(idempotencyKey: "wrong-credit"),
            at: now
        )
        let awaiting = try engine.recordConsumeOutcome(
            .reset,
            in: started,
            at: now.addingTimeInterval(1)
        )
        let selectedStillAvailable = ResetCreditInventory(
            availableCount: 1,
            credits: [inventory().credits!.first { $0.id == "expires-first" }!]
        )
        let result = try engine.reconcileVerification(
            weeklyLimit: weekly(used: 0, observedAt: now.addingTimeInterval(2)),
            inventory: selectedStillAvailable,
            in: awaiting,
            now: now.addingTimeInterval(2)
        )

        XCTAssertEqual(result.attempt?.phase, .awaitingVerification)
        XCTAssertEqual(result.phase, .verifying)
    }

    @Test func testUnchangedVerificationRemainsPendingUntilTimeout() throws {
        let shortEngine = ResetPolicyEngine(verificationTimeout: 10)
        let started = try shortEngine.markRequestStarted(
            in: preparedAttemptState(idempotencyKey: "timeout"),
            at: now
        )
        let awaiting = try shortEngine.recordConsumeOutcome(
            .reset,
            in: started,
            at: now.addingTimeInterval(1)
        )
        let pending = try shortEngine.reconcileVerification(
            weeklyLimit: weekly(used: 99, observedAt: now.addingTimeInterval(5)),
            inventory: ResetCreditInventory(availableCount: 2, credits: nil),
            in: awaiting,
            now: now.addingTimeInterval(5)
        )
        XCTAssertEqual(pending.attempt?.phase, .awaitingVerification)
        XCTAssertEqual(pending.phase, .verifying)

        let timedOut = try shortEngine.reconcileVerification(
            weeklyLimit: weekly(used: 99, observedAt: now.addingTimeInterval(12)),
            inventory: ResetCreditInventory(availableCount: 2, credits: nil),
            in: pending,
            now: now.addingTimeInterval(12)
        )
        XCTAssertEqual(timedOut.attempt?.phase, .verificationFailed)
        XCTAssertEqual(timedOut.phase, .attentionRequired)
    }

    @Test func testNothingToResetWaitsForUsageDecreaseThenCreatesNewAttempt() throws {
        let prepared = preparedAttemptState(idempotencyKey: "first-key", used: 97)
        let started = try engine.markRequestStarted(in: prepared, at: now)
        let nothing = try engine.recordConsumeOutcome(
            .nothingToReset,
            in: started,
            at: now.addingTimeInterval(1)
        )

        let unchangedTime = now.addingTimeInterval(2)
        let unchanged = engine.evaluate(
            weeklyLimit: weekly(used: 97, observedAt: unchangedTime),
            inventory: inventory(),
            state: nothing,
            now: unchangedTime,
            newIdempotencyKey: "must-wait"
        )
        XCTAssertEqual(unchanged.reason, .waitingForUsageDecrease)
        XCTAssertEqual(unchanged.action, .none)

        let decreasedTime = now.addingTimeInterval(3)
        let decreased = engine.evaluate(
            weeklyLimit: weekly(used: 98, observedAt: decreasedTime),
            inventory: inventory(),
            state: unchanged.state,
            now: decreasedTime,
            newIdempotencyKey: "second-key"
        )
        guard case let .persistThenConsume(attempt) = decreased.action else {
            return XCTFail("Expected a new logical attempt after usage decreased")
        }
        XCTAssertEqual(attempt.idempotencyKey, "second-key")
    }

    @Test func testNothingToResetAtZeroBacksOffThenRetriesWithANewKey() throws {
        let prepared = preparedAttemptState(idempotencyKey: "zero-key", used: 100)
        let started = try engine.markRequestStarted(in: prepared, at: now)
        let nothing = try engine.recordConsumeOutcome(
            .nothingToReset,
            in: started,
            at: now.addingTimeInterval(1)
        )
        let later = now.addingTimeInterval(2)
        let evaluation = engine.evaluate(
            weeklyLimit: weekly(used: 100, observedAt: later),
            inventory: inventory(),
            state: nothing,
            now: later,
            newIdempotencyKey: "must-not-loop"
        )

        XCTAssertEqual(evaluation.reason, .waitingForNothingToResetBackoff)
        XCTAssertEqual(evaluation.action, .none)

        let retryTime = now.addingTimeInterval(61)
        let retry = engine.evaluate(
            weeklyLimit: weekly(used: 100, observedAt: retryTime),
            inventory: inventory(),
            state: evaluation.state,
            now: retryTime,
            newIdempotencyKey: "bounded-retry"
        )
        guard case let .persistThenConsume(attempt) = retry.action else {
            return XCTFail("Expected a bounded retry after the zero-limit backoff")
        }
        XCTAssertEqual(attempt.idempotencyKey, "bounded-retry")
        XCTAssertEqual(retry.state.confirmation, prepared.confirmation)
    }

    @Test func testNothingToResetCannotFabricateFreshEvidenceAfterSleep() throws {
        for usedBefore in [97.0, 100.0] {
            let prepared = preparedAttemptState(idempotencyKey: "old-no-op", used: usedBefore)
            let started = try engine.markRequestStarted(in: prepared, at: now)
            let nothing = try engine.recordConsumeOutcome(
                .nothingToReset,
                in: started,
                at: now.addingTimeInterval(1)
            )
            let wakeTime = now.addingTimeInterval(3_600)
            let resumed = engine.evaluate(
                weeklyLimit: weekly(used: min(100, usedBefore + 1), observedAt: wakeTime),
                inventory: ResetCreditInventory(availableCount: 1, credits: nil),
                state: nothing,
                now: wakeTime,
                newIdempotencyKey: "must-not-use"
            )

            XCTAssertEqual(resumed.action, .none)
            XCTAssertNil(resumed.state.attempt)
            XCTAssertEqual(resumed.state.confirmation?.count, 1)
            XCTAssertEqual(resumed.state.confirmation?.firstObservedAt, wakeTime)
            XCTAssertEqual(resumed.state.confirmation?.lastObservedAt, wakeTime)
        }
    }

    @Test func testPreparedAttemptSurvivesRestartAndAcceptsNewerFreshReading() throws {
        let prepared = try preparedState(idempotencyKey: "restart-key")
        let later = now.addingTimeInterval(15)
        let resumed = engine.evaluate(
            weeklyLimit: weekly(used: 99, observedAt: later),
            inventory: inventory(),
            state: prepared,
            now: later,
            newIdempotencyKey: "must-not-replace"
        )

        guard case let .persistThenConsume(attempt) = resumed.action else {
            return XCTFail("Expected the durable prepared attempt to resume")
        }
        XCTAssertEqual(attempt.idempotencyKey, "restart-key")
        XCTAssertEqual(resumed.state.confirmation?.firstObservedAt, now)
        XCTAssertEqual(resumed.state.confirmation?.lastObservedAt, later)
    }

    @Test func testPreparedAttemptExpiresWhenItsOldestReadingExpires() throws {
        let prepared = try preparedState(idempotencyKey: "never-sent-old-key")
        // The newest reading is only 116 seconds old; the first is beyond the freshness limit.
        let later = now.addingTimeInterval(121)
        let resumed = engine.evaluate(
            weeklyLimit: weekly(used: 99, observedAt: later),
            inventory: inventory(),
            state: prepared,
            now: later,
            newIdempotencyKey: "must-not-use"
        )

        XCTAssertEqual(resumed.action, .none)
        XCTAssertNil(resumed.state.attempt)
        XCTAssertEqual(resumed.state.confirmation?.count, 1)
        XCTAssertEqual(resumed.state.confirmation?.firstObservedAt, later)
        let confirmedTime = later.addingTimeInterval(5)
        let confirmed = engine.evaluate(
            weeklyLimit: weekly(used: 99, observedAt: confirmedTime),
            inventory: inventory(),
            state: resumed.state,
            now: confirmedTime,
            newIdempotencyKey: "new-never-sent-key"
        )
        guard case let .persistThenConsume(attempt) = confirmed.action else {
            return XCTFail("Expected a newly qualified never-sent attempt")
        }
        XCTAssertEqual(attempt.idempotencyKey, "new-never-sent-key")
    }

    @Test func testLegacyPreparedJSONWithoutOldestReadingRequalifies() throws {
        let prepared = try preparedState(idempotencyKey: "legacy-never-sent")
        let encoded = try JSONEncoder().encode(prepared)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var confirmation = try #require(object["confirmation"] as? [String: Any])
        confirmation.removeValue(forKey: "firstObservedAt")
        object["confirmation"] = confirmation
        let legacy = try JSONDecoder().decode(
            MonitorState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(legacy.confirmation?.firstObservedAt)

        let later = now.addingTimeInterval(15)
        let resumed = engine.evaluate(
            weeklyLimit: weekly(used: 99, observedAt: later),
            inventory: inventory(),
            state: legacy,
            now: later,
            newIdempotencyKey: "must-not-use"
        )
        XCTAssertEqual(resumed.action, .none)
        XCTAssertNil(resumed.state.attempt)
        XCTAssertEqual(resumed.state.confirmation?.count, 1)
        XCTAssertEqual(resumed.state.confirmation?.firstObservedAt, later)
    }

    @Test func testStaleEvidenceDoesNotReplaceAnAmbiguousOrInFlightKey() throws {
        let prepared = try preparedState(idempotencyKey: "crossed-network-boundary")
        let started = try engine.markRequestStarted(in: prepared, at: now.addingTimeInterval(6))
        let retryable = try engine.recordAmbiguousFailure(
            in: started,
            at: now.addingTimeInterval(7)
        )
        let later = now.addingTimeInterval(3_600)
        for saved in [started, retryable] {
            let resumed = engine.evaluate(
                weeklyLimit: weekly(used: 99, observedAt: later),
                inventory: ResetCreditInventory(availableCount: 1, credits: nil),
                state: saved,
                now: later,
                newIdempotencyKey: "must-not-replace"
            )
            guard case let .retryConsume(attempt) = resumed.action else {
                return XCTFail("Expected recovery to preserve the existing logical attempt")
            }
            XCTAssertEqual(attempt.idempotencyKey, "crossed-network-boundary")
            XCTAssertEqual(resumed.state.confirmation, saved.confirmation)
        }
    }

    @Test func testFreshConfirmationBoundaryChecksBothRealReadingsAndSpacing() {
        var confirmation = ThresholdConfirmation(
            weeklyResetAt: resetAt,
            count: 2,
            lastObservedAt: now,
            lastRemainingPercent: 2,
            firstObservedAt: now.addingTimeInterval(-5)
        )
        #expect(engine.hasFreshConfirmation(confirmation, for: resetAt, at: now))
        #expect(!engine.hasFreshConfirmation(confirmation, for: resetAt, at: now.addingTimeInterval(116)))
        #expect(!engine.hasFreshConfirmation(confirmation, for: resetAt.addingTimeInterval(1), at: now))
        confirmation.firstObservedAt = now.addingTimeInterval(-1)
        #expect(!engine.hasFreshConfirmation(confirmation, for: resetAt, at: now))
        confirmation.firstObservedAt = now.addingTimeInterval(1)
        confirmation.lastObservedAt = now.addingTimeInterval(6)
        #expect(!engine.hasFreshConfirmation(confirmation, for: resetAt, at: now))
        confirmation.firstObservedAt = nil
        #expect(!engine.hasFreshConfirmation(confirmation, for: resetAt, at: now))
    }

    @Test func testVerificationFailureContinuesReadOnlyLateReconciliation() throws {
        let started = try engine.markRequestStarted(
            in: preparedAttemptState(idempotencyKey: "late-proof"),
            at: now
        )
        let awaiting = try engine.recordConsumeOutcome(
            .reset,
            in: started,
            at: now.addingTimeInterval(1)
        )
        let failed = try engine.reconcileVerification(
            weeklyLimit: weekly(used: 99, observedAt: now.addingTimeInterval(70)),
            inventory: inventory(),
            in: awaiting,
            now: now.addingTimeInterval(70)
        )
        let evaluation = engine.evaluate(
            weeklyLimit: weekly(used: 99, observedAt: now.addingTimeInterval(71)),
            inventory: inventory(),
            state: failed,
            now: now.addingTimeInterval(71),
            newIdempotencyKey: "must-never-use"
        )
        guard case let .readForVerification(attempt) = evaluation.action else {
            return XCTFail("Expected read-only reconciliation of the ambiguous key")
        }
        XCTAssertEqual(attempt.idempotencyKey, "late-proof")

        let recovered = try engine.reconcileVerification(
            weeklyLimit: weekly(used: 0, observedAt: now.addingTimeInterval(72)),
            inventory: inventoryAfterSelectedCreditConsumed(),
            in: evaluation.state,
            now: now.addingTimeInterval(72)
        )
        XCTAssertEqual(recovered.attempt?.phase, .succeeded)
        XCTAssertEqual(recovered.phase, .verified)
    }

    @Test func testDefiniteRejectionNeverRetriesAutomatically() throws {
        let started = try engine.markRequestStarted(
            in: preparedAttemptState(idempotencyKey: "rejected-key"),
            at: now
        )
        let rejected = try engine.recordDefiniteRejection(
            in: started,
            at: now.addingTimeInterval(1)
        )
        let evaluation = engine.evaluate(
            weeklyLimit: weekly(used: 100, observedAt: now.addingTimeInterval(10)),
            inventory: inventory(),
            state: rejected,
            now: now.addingTimeInterval(10),
            newIdempotencyKey: "must-not-use"
        )
        XCTAssertEqual(evaluation.reason, .requestRejected)
        XCTAssertEqual(evaluation.action, .none)
        XCTAssertEqual(evaluation.state.attempt?.idempotencyKey, "rejected-key")
    }

    @Test func testSucceededAttemptRetiresSoAnotherBankedResetCanBeUsedSameWeek() throws {
        let started = try engine.markRequestStarted(
            in: preparedAttemptState(idempotencyKey: "first-bank", used: 97),
            at: now
        )
        let awaiting = try engine.recordConsumeOutcome(
            .reset,
            in: started,
            at: now.addingTimeInterval(1)
        )
        let verified = try engine.reconcileVerification(
            weeklyLimit: weekly(used: 0, observedAt: now.addingTimeInterval(2)),
            inventory: inventoryAfterSelectedCreditConsumed(),
            in: awaiting,
            now: now.addingTimeInterval(2)
        )

        let depletedAgain = engine.evaluate(
            weeklyLimit: weekly(used: 97, observedAt: now.addingTimeInterval(20)),
            inventory: inventoryAfterSelectedCreditConsumed(),
            state: verified,
            now: now.addingTimeInterval(20),
            newIdempotencyKey: "second-bank"
        )
        XCTAssertEqual(depletedAgain.reason, .firstConfirmation)
        XCTAssertNil(depletedAgain.state.attempt)

        let confirmedAgain = engine.evaluate(
            weeklyLimit: weekly(used: 97, observedAt: now.addingTimeInterval(25)),
            inventory: inventoryAfterSelectedCreditConsumed(),
            state: depletedAgain.state,
            now: now.addingTimeInterval(25),
            newIdempotencyKey: "second-bank"
        )
        guard case let .persistThenConsume(attempt) = confirmedAgain.action else {
            return XCTFail("Expected a second banked reset attempt in the same natural week")
        }
        XCTAssertEqual(attempt.idempotencyKey, "second-bank")
    }

    @Test func testCrossProfileAttemptIsRejectedByEveryTransition() {
        var swapped = preparedAttemptState(idempotencyKey: "wrong-profile")
        swapped.attempt?.profileID = "another-profile"
        #expect(throws: ResetPolicyTransitionError.invalidAttemptProfile) {
            _ = try engine.markRequestStarted(in: swapped, at: now)
        }
        let evaluation = engine.evaluate(
            weeklyLimit: weekly(used: 100),
            inventory: inventory(),
            state: swapped,
            now: now,
            newIdempotencyKey: "must-not-use"
        )
        XCTAssertEqual(evaluation.action, .none)
        XCTAssertEqual(evaluation.state.phase, .attentionRequired)
    }

    @Test func testProfilesHaveIndependentConfirmationState() {
        let profileOne = engine.evaluate(
            weeklyLimit: weekly(used: 99),
            inventory: inventory(),
            state: state(profileID: "one"),
            now: now
        )
        let profileTwo = engine.evaluate(
            weeklyLimit: weekly(used: 50),
            inventory: inventory(),
            state: state(profileID: "two"),
            now: now
        )

        XCTAssertEqual(profileOne.state.confirmation?.count, 1)
        XCTAssertNil(profileTwo.state.confirmation)
        XCTAssertEqual(profileOne.state.profileID, "one")
        XCTAssertEqual(profileTwo.state.profileID, "two")
    }

    @Test func testPersistedMonitorStateRoundTripsWithoutLosingAttemptKey() throws {
        let original = preparedAttemptState(idempotencyKey: "persisted-key")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MonitorState.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.attempt?.idempotencyKey, "persisted-key")
        XCTAssertEqual(decoded.schemaVersion, MonitorState.currentSchemaVersion)
        XCTAssertEqual(decoded.attempt?.schemaVersion, RedemptionAttempt.currentSchemaVersion)
    }

    @Test func testUnknownCreditEnumValuesRoundTripForForwardCompatibility() throws {
        let credit = ResetCredit(
            id: "opaque",
            kind: .unknown("futureResetKind"),
            status: .unknown("futureStatus"),
            grantedAt: now,
            expiresAt: nil
        )
        let data = try JSONEncoder().encode(credit)
        let decoded = try JSONDecoder().decode(ResetCredit.self, from: data)
        XCTAssertEqual(decoded, credit)
    }

    private func weekly(
        used: Double,
        observedAt: Date? = nil
    ) -> CanonicalWeeklyLimit {
        CanonicalWeeklyLimit(
            lane: .secondary,
            usedPercent: used,
            durationMinutes: 10_080,
            resetsAt: resetAt,
            observedAt: observedAt ?? now
        )
    }

    private func state(profileID: String = "profile-one") -> MonitorState {
        MonitorState(profileID: profileID)
    }

    private func inventory() -> ResetCreditInventory {
        ResetCreditInventory(
            availableCount: 2,
            credits: [
                ResetCredit(
                    id: "expires-later",
                    kind: .codexRateLimits,
                    status: .available,
                    grantedAt: now.addingTimeInterval(-200),
                    expiresAt: now.addingTimeInterval(2_000)
                ),
                ResetCredit(
                    id: "expires-first",
                    kind: .codexRateLimits,
                    status: .available,
                    grantedAt: now.addingTimeInterval(-100),
                    expiresAt: now.addingTimeInterval(1_000)
                ),
                ResetCredit(
                    id: "wrong-kind",
                    kind: .unknown("sparkRateLimits"),
                    status: .available,
                    grantedAt: now,
                    expiresAt: now.addingTimeInterval(10)
                ),
            ]
        )
    }

    private func inventoryAfterSelectedCreditConsumed() -> ResetCreditInventory {
        ResetCreditInventory(
            availableCount: 1,
            credits: inventory().credits?.filter { $0.id != "expires-first" }
        )
    }

    private func preparedState(idempotencyKey: String) throws -> MonitorState {
        let first = engine.evaluate(
            weeklyLimit: weekly(used: 99),
            inventory: inventory(),
            state: state(),
            now: now
        )
        let later = now.addingTimeInterval(5)
        let second = engine.evaluate(
            weeklyLimit: weekly(used: 100, observedAt: later),
            inventory: inventory(),
            state: first.state,
            now: later,
            newIdempotencyKey: idempotencyKey
        )
        guard second.state.attempt != nil else {
            throw PolicyTestError.expectedAttempt
        }
        return second.state
    }

    private func preparedAttemptState(
        idempotencyKey: String,
        used: Double = 99
    ) -> MonitorState {
        let attempt = RedemptionAttempt(
            profileID: "profile-one",
            idempotencyKey: idempotencyKey,
            creditID: "expires-first",
            weeklyResetAtBefore: resetAt,
            weeklyUsedPercentBefore: used,
            availableCreditCountBefore: 2,
            preparedAt: now
        )
        return MonitorState(
            profileID: "profile-one",
            phase: .redeeming,
            confirmation: ThresholdConfirmation(
                weeklyResetAt: resetAt,
                count: 2,
                lastObservedAt: now,
                lastRemainingPercent: 100 - used,
                firstObservedAt: now.addingTimeInterval(-5)
            ),
            attempt: attempt
        )
    }

    private enum PolicyTestError: Error {
        case expectedAttempt
    }
}

private func XCTAssertEqual<T: Equatable>(
    _ actual: @autoclosure () throws -> T,
    _ expected: @autoclosure () throws -> T
) {
    do {
        let actual = try actual()
        let expected = try expected()
        #expect(actual == expected)
    } catch {
        Issue.record(error)
    }
}

private func XCTAssertNil<T>(_ value: @autoclosure () throws -> T?) {
    do {
        #expect(try value() == nil)
    } catch {
        Issue.record(error)
    }
}

private func XCTAssertNotNil<T>(_ value: @autoclosure () throws -> T?) {
    do {
        #expect(try value() != nil)
    } catch {
        Issue.record(error)
    }
}

private func XCTFail(_ message: String) {
    Issue.record(Comment(rawValue: message))
}
