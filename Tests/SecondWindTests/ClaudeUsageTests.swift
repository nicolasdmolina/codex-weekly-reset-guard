import Foundation
import Testing
@testable import SecondWindCore

private func envelope(_ result: String, localCommand: String? = "usage", turns: Int = 0) -> Data {
    var object: [String: Any] = [
        "type": "result",
        "subtype": "success",
        "is_error": false,
        "num_turns": turns,
        "result": result,
    ]
    if let localCommand { object["local_command"] = localCommand }
    return try! JSONSerialization.data(withJSONObject: object)
}

private func date(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

private let observed = date("2026-10-29T18:00:00Z")

@Test func parsesSessionWeeklyAndModelWindows() throws {
    let text = """
    Current session: 60% used · resets Oct 29 at 9:40pm (America/New_York)
    Current week (all models): 28% used · resets Nov 4 at 3am (America/New_York)
    Current week (Sonnet only): 91% used · resets Nov 4 at 3am (America/New_York)
    Current week (Fable): 0% used
    """
    let report = try ClaudeUsageParser.parse(envelope(text), observedAt: observed)

    #expect(report.session?.usedPercent == 60)
    #expect(report.session?.resetsAt == date("2026-10-30T01:40:00Z"))
    #expect(report.weekly?.remainingPercent == 72)
    #expect(report.weekly?.resetsAt == date("2026-11-04T08:00:00Z"))
    #expect(report.modelWeekly.map(\.scope) == [.modelWeekly("Sonnet only"), .modelWeekly("Fable")])
    #expect(report.modelWeekly.last?.resetsAt == nil)
    #expect(report.tightestWindow?.scope == .modelWeekly("Sonnet only"))
}

@Test func refusesAnythingButTheLocalUsageCommand() {
    #expect(throws: ClaudeUsageParseError.notLocalCommand) {
        try ClaudeUsageParser.parse(envelope("Current session: 1% used", localCommand: nil, turns: 1), observedAt: observed)
    }
    #expect(throws: ClaudeUsageParseError.notLocalCommand) {
        try ClaudeUsageParser.parse(envelope("Current session: 1% used", turns: 1), observedAt: observed)
    }
    #expect(throws: ClaudeUsageParseError.malformedOutput) {
        try ClaudeUsageParser.parse(Data("not json".utf8), observedAt: observed)
    }
}

@Test func signedOutCostSummaryHasNoPlanLimits() {
    let text = "Total cost:            $0.0000\nTotal duration (API):  0s\nUsage:                 0 input, 0 output"
    #expect(throws: ClaudeUsageParseError.noPlanLimits) {
        try ClaudeUsageParser.parse(envelope(text), observedAt: observed)
    }
}

@Test func duplicateWindowsFailClosed() {
    let text = "Current session: 10% used\nCurrent session: 90% used"
    #expect(throws: ClaudeUsageParseError.malformedOutput) {
        try ClaudeUsageParser.parse(envelope(text), observedAt: observed)
    }
}

@Test func readsEveryResetTimeShape() {
    let calendar = Calendar(identifier: .gregorian)
    func parse(_ text: String, now: Date = observed) -> Date? {
        ClaudeUsageParser.parseResetTime(text, now: now, calendar: calendar)
    }
    #expect(parse("Nov 4 at 3am (UTC)") == date("2026-11-04T03:00:00Z"))
    #expect(parse("Jan 2, 2027 at 3:05pm (UTC)") == date("2027-01-02T15:05:00Z"))
    #expect(parse("Jan 2, 2027, 3:05pm (UTC)") == date("2027-01-02T15:05:00Z"))
    #expect(parse("12am (UTC)") == date("2026-10-30T00:00:00Z"))
    #expect(parse("7pm (UTC)") == date("2026-10-29T19:00:00Z"))
    // A year-less date just after New Year belongs to the next year.
    #expect(parse("Jan 1 at 9am (UTC)", now: date("2026-12-31T20:00:00Z")) == date("2027-01-01T09:00:00Z"))
    #expect(parse("Nov 4 at 3am (Not/AZone)") == nil)
    #expect(parse("Feb 30 at 3am (UTC)") == nil)
    #expect(parse("Nov 4 at 13pm (UTC)") == nil)
}

@Test func authStatusRequiresSubscriptionSignIn() throws {
    let json = Data(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"a@b.co","orgId":"x","subscriptionType":"max"}"#.utf8)
    let status = try JSONDecoder().decode(ClaudeAuthStatus.self, from: json)
    #expect(status.usesSubscription)
    #expect(status.planName == "Max")

    let console = ClaudeAuthStatus(loggedIn: true, authMethod: "console", email: nil, subscriptionType: nil)
    #expect(!console.usesSubscription)
    let signedOut = try JSONDecoder().decode(
        ClaudeAuthStatus.self,
        from: Data(#"{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}"#.utf8)
    )
    #expect(!signedOut.usesSubscription)
}

@Test func alertsOncePerWindowAndResetCycle() {
    let reset = date("2026-11-04T08:00:00Z")
    let report = ClaudeUsageReport(
        session: ClaudeUsageWindow(scope: .session, usedPercent: 40, resetsAt: nil),
        weekly: ClaudeUsageWindow(scope: .weekly, usedPercent: 92, resetsAt: reset),
        observedAt: observed
    )
    let first = ClaudeAlertPolicy.newAlerts(for: report, alreadySent: [])
    #expect(first.map(\.window.scope) == [.weekly])
    #expect(ClaudeAlertPolicy.newAlerts(for: report, alreadySent: Set(first.map(\.key))).isEmpty)

    var nextCycle = report
    nextCycle.weekly?.resetsAt = reset.addingTimeInterval(7 * 86_400)
    #expect(ClaudeAlertPolicy.newAlerts(for: nextCycle, alreadySent: Set(first.map(\.key))).count == 1)
}
