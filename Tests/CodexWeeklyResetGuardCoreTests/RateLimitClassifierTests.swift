import Foundation
import Testing
@testable import CodexWeeklyResetGuardCore

@Suite struct RateLimitClassifierTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let classifier = RateLimitClassifier()

    @Test func testClassifiesWeeklyWindowInPrimaryLane() throws {
        let result = classifier.classify(
            snapshot(
                primary: window(used: 98, duration: 10_080),
                secondary: window(used: 100, duration: 300)
            ),
            now: now
        )

        let weekly = try canonical(from: result)
        XCTAssertEqual(weekly.lane, .primary)
        XCTAssertEqual(weekly.remainingPercent, 2)
        XCTAssertEqual(weekly.durationMinutes, 10_080)
    }

    @Test func testClassifiesWeeklyWindowInSecondaryLane() throws {
        let result = classifier.classify(
            snapshot(
                primary: window(used: 100, duration: 300),
                secondary: window(used: 97, duration: 10_080)
            ),
            now: now
        )

        let weekly = try canonical(from: result)
        XCTAssertEqual(weekly.lane, .secondary)
        XCTAssertEqual(weekly.remainingPercent, 3)
    }

    @Test func testFiveHourExhaustionAloneIsRejected() {
        let result = classifier.classify(
            snapshot(primary: window(used: 100, duration: 300)),
            now: now
        )

        XCTAssertEqual(result, .rejected(.weeklyWindowMissing))
    }

    @Test func testExplicitSparkWeeklyLimitIsRejected() {
        let result = classifier.classify(
            snapshot(
                limitID: "spark",
                limitName: "Spark",
                primary: window(used: 100, duration: 10_080)
            ),
            now: now
        )

        XCTAssertEqual(result, .rejected(.nonCanonicalLimitID("spark")))
    }

    @Test func testExplicitModelSpecificWeeklyLimitIsRejected() {
        let result = classifier.classify(
            snapshot(
                limitID: "gpt-5.6-codex",
                limitName: "GPT-5.6 Codex",
                secondary: window(used: 100, duration: 10_080)
            ),
            now: now
        )

        XCTAssertEqual(result, .rejected(.nonCanonicalLimitID("gpt-5.6-codex")))
    }

    @Test func testExplicitExtraUsageLimitIsRejected() {
        let result = classifier.classify(
            snapshot(
                limitID: "codex-extra-usage",
                primary: window(used: 100, duration: 10_080)
            ),
            now: now
        )

        XCTAssertEqual(result, .rejected(.nonCanonicalLimitID("codex-extra-usage")))
    }

    @Test func testNilLimitIDAndNameAcceptsBackwardCompatibleTopLevelSnapshot() throws {
        let result = classifier.classify(
            snapshot(limitID: nil, limitName: nil, secondary: window(used: 99, duration: 10_080)),
            now: now
        )

        XCTAssertEqual(try canonical(from: result).remainingPercent, 1)
    }

    @Test func testNilLimitIDWithCanonicalNameIsAcceptedCaseInsensitively() throws {
        let result = classifier.classify(
            snapshot(limitID: nil, limitName: " Codex ", primary: window(used: 99, duration: 10_080)),
            now: now
        )

        XCTAssertEqual(try canonical(from: result).lane, .primary)
    }

    @Test func testNilLimitIDWithNonCanonicalNameFailsClosed() {
        let result = classifier.classify(
            snapshot(limitID: nil, limitName: "Codex Spark", primary: window(used: 99, duration: 10_080)),
            now: now
        )

        XCTAssertEqual(result, .rejected(.nonCanonicalLimitName("Codex Spark")))
    }

    @Test func testAmbiguousWeeklyWindowsAreRejected() {
        let result = classifier.classify(
            snapshot(
                primary: window(used: 98, duration: 10_080),
                secondary: window(used: 99, duration: 10_100)
            ),
            now: now
        )

        XCTAssertEqual(result, .rejected(.ambiguousWeeklyWindows))
    }

    @Test func testMissingDurationIsRejected() {
        let result = classifier.classify(
            snapshot(primary: window(used: 100, duration: nil)),
            now: now
        )

        XCTAssertEqual(result, .rejected(.weeklyWindowMissing))
    }

    @Test func testWeeklyToleranceIsPlusOrMinusFivePercent() throws {
        let lower = RateLimitClassifier.weeklyDurationMinutes * 0.95
        let upper = RateLimitClassifier.weeklyDurationMinutes * 1.05

        XCTAssertEqual(
            try canonical(from: classifier.classify(snapshot(primary: window(used: 50, duration: lower)), now: now)).durationMinutes,
            lower,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try canonical(from: classifier.classify(snapshot(primary: window(used: 50, duration: upper)), now: now)).durationMinutes,
            upper,
            accuracy: 0.001
        )
        XCTAssertEqual(
            classifier.classify(snapshot(primary: window(used: 50, duration: lower - 0.01)), now: now),
            .rejected(.weeklyWindowMissing)
        )
        XCTAssertEqual(
            classifier.classify(snapshot(primary: window(used: 50, duration: upper + 0.01)), now: now),
            .rejected(.weeklyWindowMissing)
        )
    }

    @Test func testMissingAndExpiredWeeklyResetFailClosed() {
        let missing = RateLimitWindow(
            usedPercent: 99,
            windowDurationMinutes: 10_080,
            resetsAt: nil
        )
        let expired = RateLimitWindow(
            usedPercent: 99,
            windowDurationMinutes: 10_080,
            resetsAt: now
        )

        XCTAssertEqual(
            classifier.classify(snapshot(primary: missing), now: now),
            .rejected(.missingWeeklyReset)
        )
        XCTAssertEqual(
            classifier.classify(snapshot(primary: expired), now: now),
            .rejected(.expiredWeeklyReset)
        )
    }

    @Test func testInvalidWeeklyUsageFailsClosed() {
        XCTAssertEqual(
            classifier.classify(snapshot(primary: window(used: 101, duration: 10_080)), now: now),
            .rejected(.invalidWeeklyUsage)
        )
        XCTAssertEqual(
            classifier.classify(snapshot(primary: window(used: .nan, duration: 10_080)), now: now),
            .rejected(.invalidWeeklyUsage)
        )
    }

    private func snapshot(
        limitID: String? = "codex",
        limitName: String? = "Codex",
        primary: RateLimitWindow? = nil,
        secondary: RateLimitWindow? = nil
    ) -> RateLimitSnapshot {
        RateLimitSnapshot(
            limitID: limitID,
            limitName: limitName,
            primary: primary,
            secondary: secondary,
            observedAt: now
        )
    }

    private func window(used: Double, duration: Double?) -> RateLimitWindow {
        RateLimitWindow(
            usedPercent: used,
            windowDurationMinutes: duration,
            resetsAt: now.addingTimeInterval(7 * 24 * 60 * 60)
        )
    }

    private func canonical(
        from classification: WeeklyRateLimitClassification
    ) throws -> CanonicalWeeklyLimit {
        guard case let .canonical(limit) = classification else {
            throw ClassificationTestError.expectedCanonical
        }
        return limit
    }

    private enum ClassificationTestError: Error {
        case expectedCanonical
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

private func XCTAssertEqual(
    _ actual: @autoclosure () throws -> Double,
    _ expected: @autoclosure () throws -> Double,
    accuracy: Double
) {
    do {
        let actual = try actual()
        let expected = try expected()
        #expect(abs(actual - expected) <= accuracy)
    } catch {
        Issue.record(error)
    }
}
