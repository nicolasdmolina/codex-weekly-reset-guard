import Foundation
import Testing
@testable import SecondWind
@testable import SecondWindCore

private let observed = Date(timeIntervalSince1970: 1_800_000_000)
private let report = #"""
{"status":"SUCCESS","num_turns":0,"usage":{"input_tokens":0,"total_tokens":0},
 "command":{"name":"usage","data":{"groups":[
   {"name":"Gemini Models","buckets":[{"window":"weekly","remaining_fraction":0.08,"reset_time":"2027-05-01T00:00:00Z"}]},
   {"name":"Other models","buckets":[{"window":"weekly","remaining_fraction":1,"reset_time":"1970-01-01T00:00:00Z"},
                                   {"window":"5h","remaining_fraction":0.7,"disabled":true}]}
 ]}}}
"""#

@Test func readsOnlyReportedAgyGroupsAndPreservesMissingDates() throws {
    let result = try AntigravityCLI.parse(Data(report.utf8), at: observed)
    #expect(result.inventory == .notTracked)
    #expect(result.windows.map(\.kind) == [.group(.weekly, "Gemini Models"), .group(.weekly, "Other models")])
    #expect(result.windows.map(\.remainingPercent) == [8, 100])
    #expect(result.windows[0].resetsAt != nil)
    #expect(result.windows[1].resetsAt == nil)
    let record = QuotaAccountRecord(provider: .antigravity, accountID: UUID(), lastSuccess: result)
    let source = PreflightSnapshot(publishedAt: observed, providers: [.antigravity], accounts: [record])
    let snapshot = PreflightSnapshotFile.decode(try PreflightSnapshotFile.encode(source))
    func check(_ session: Int?, _ weekly: Int?) -> PreflightOutcome {
        let request = PreflightRequest(minimumSessionPercent: session, minimumWeeklyPercent: weekly, provider: .antigravity)!
        return PreflightEvaluator.evaluate(request, snapshot: snapshot, now: observed)
    }
    #expect(check(nil, 10).result == .low)
    #expect(check(nil, 8).result == .enough)
    #expect(check(1, nil).reason == .windowMissing)
}

@Test func rejectsModelOutputAndKeepsInvalidFractionsUnknown() throws {
    for (old, new) in [("\"usage\",\"data\"", "\"other\",\"data\""), ("\"num_turns\":0", "\"num_turns\":1"),
                       ("\"input_tokens\":0", "\"input_tokens\":1"), ("\"total_tokens\":0", "\"other\":0")] {
        let changed = report.replacingOccurrences(of: old, with: new)
        #expect(throws: AntigravityUsageError.unverifiedCommand) {
            try AntigravityCLI.parse(Data(changed.utf8), at: observed)
        }
    }
    let invalid = report.replacingOccurrences(of: "0.08", with: "1.08")
    let result = try AntigravityCLI.parse(Data(invalid.utf8), at: observed)
    #expect(result.unreportedWindows == [.group(.weekly, "Gemini Models")])
    #expect(result.windows.count == 1)
}

@Test func agyAlertsOnceAndWaitsForObservedRefill() {
    var ledger = AlertLedger()
    ledger.limitRefilled = true
    var record = QuotaAccountRecord(provider: .antigravity, accountID: UUID())
    let reset = observed.addingTimeInterval(600)
    func ingest(used: Double, offset: TimeInterval) -> [AlertNotice] {
        let now = observed.addingTimeInterval(offset)
        let window = QuotaWindow(kind: .group(.weekly, "Gemini"), usedPercent: used, resetsAt: reset)
        record.recordSuccess(QuotaObservation(observedAt: now, windows: [window], inventory: .notTracked))
        return AlertPolicy.ingest(record, name: "Local CLI", ledger: &ledger, now: now).deliveries.map(\.notice)
    }
    #expect(ingest(used: 93, offset: 0).count == 1)
    #expect(ingest(used: 100, offset: 2).isEmpty)
    #expect(ingest(used: 100, offset: 5).isEmpty)
    #expect(ingest(used: 0, offset: 10) == [.limitRefilled(.group(.weekly, "Gemini"))])
    #expect(ingest(used: 0, offset: 12).isEmpty)
}

@Test @MainActor func agyEnrollmentPauseAndRemovalSurviveRelaunch() async throws {
    let suite = "SecondWindTests.agy.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = GuardAppModel()
    let monitor = AntigravityMonitor(model: model, defaults: defaults) { throw AntigravityUsageError.unverifiedCommand }
    monitor.start()
    #expect(model.antigravity == nil && !model.isCheckingAntigravity)
    model.startEnrollment(.antigravity)
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while model.isCheckingAntigravity && ContinuousClock.now < deadline { await Task.yield() }
    let profile = try #require(model.antigravity)
    #expect(profile.quota.lastFailure?.reason == .monitoringStopped)
    #expect(!model.canAdd(.antigravity))
    try monitor.rename(profile.ref.id, to: "My Mac")
    monitor.stop()

    let restored = GuardAppModel()
    let next = AntigravityMonitor(model: restored, defaults: defaults) {
        try AntigravityCLI.parse(Data(report.utf8), at: Date())
    }
    next.start()
    next.checkNow()
    #expect(restored.antigravity?.name == "My Mac" && !restored.isCheckingAntigravity)
    restored.onRetryAntigravity?()
    #expect(restored.isCheckingAntigravity)
    try next.remove(profile.ref.id)
    await Task.yield()
    #expect(restored.antigravity == nil && !restored.isCheckingAntigravity)
    next.start()
    #expect(restored.antigravity == nil)
}
