import Foundation

public enum PreflightWindow: String, Codable, Sendable, Hashable, CaseIterable {
    case session
    case weekly

    /// The window that must be reported, plus any per-model windows that can only lower it.
    func includes(_ kind: QuotaWindowKind) -> Bool {
        switch (self, kind) {
        case let (_, .group(window, _)): window == self
        case (.session, .session), (.weekly, .weekly), (.weekly, .modelWeekly): true
        default: false
        }
    }

    var requiredKind: QuotaWindowKind {
        switch self {
        case .session: .session
        case .weekly: .weekly
        }
    }
}

public struct PreflightRequirement: Equatable, Sendable {
    public let window: PreflightWindow
    public let minimumPercent: Int
}

/// A validated request: one or two distinct windows, each with a whole-number minimum in 0...100.
public struct PreflightRequest: Equatable, Sendable {
    public let requirements: [PreflightRequirement]
    public let provider: QuotaProvider?
    public let accountID: UUID?

    public init?(
        minimumSessionPercent: Int?,
        minimumWeeklyPercent: Int?,
        provider: QuotaProvider? = nil,
        accountID: UUID? = nil
    ) {
        let requirements = [
            minimumSessionPercent.map { PreflightRequirement(window: .session, minimumPercent: $0) },
            minimumWeeklyPercent.map { PreflightRequirement(window: .weekly, minimumPercent: $0) },
        ].compactMap { $0 }
        guard !requirements.isEmpty,
              requirements.allSatisfy({ (0...100).contains($0.minimumPercent) }) else {
            return nil
        }
        self.requirements = requirements
        self.provider = provider
        self.accountID = accountID
    }
}

public enum PreflightResult: String, Sendable, Equatable, CaseIterable {
    case enough
    case low
    case unknown

    public var exitCode: Int32 {
        switch self {
        case .enough: 0
        case .low: 10
        case .unknown: 11
        }
    }
}

public enum PreflightReason: String, Sendable, Equatable, CaseIterable {
    case snapshotMissing = "snapshot_missing"
    case snapshotUnreadable = "snapshot_unreadable"
    case snapshotInvalid = "snapshot_invalid"
    case snapshotUnsupportedVersion = "snapshot_unsupported_version"
    case rosterIncomplete = "roster_incomplete"
    case accountNotFound = "account_not_found"
    case accountAmbiguous = "account_ambiguous"
    case noReading = "no_reading"
    case refreshFailed = "refresh_failed"
    case readingStale = "reading_stale"
    case readingFromFuture = "reading_from_future"
    case windowMissing = "window_missing"
    case windowResetPassed = "window_reset_passed"
    case usageBlocked = "ordinary_usage_blocked"
    case usageUnconfirmed = "ordinary_usage_unknown"

    init(_ failure: PreflightSnapshotReadFailure) {
        switch failure {
        case .missing: self = .snapshotMissing
        case .unreadable: self = .snapshotUnreadable
        case .invalid: self = .snapshotInvalid
        case .unsupportedVersion: self = .snapshotUnsupportedVersion
        }
    }
}

public struct PreflightAccountReference: Equatable, Sendable {
    public let provider: QuotaProvider
    public let accountID: UUID
}

public struct PreflightCheck: Equatable, Sendable {
    public let requirement: PreflightRequirement
    public let result: PreflightResult
    public let reason: PreflightReason?
    /// Set when `reason` is `refresh_failed`.
    public let failure: QuotaFailureReason?
    /// The window that decided the result, or the one that could not be trusted.
    public let window: QuotaWindow?
    public let observedAt: Date?
    /// When the app's own freshness policy stops trusting `observedAt`.
    public let staleAfter: Date?
}

public struct PreflightOutcome: Equatable, Sendable {
    public let result: PreflightResult
    public let reason: PreflightReason?
    public let account: PreflightAccountReference?
    public let checks: [PreflightCheck]
    public let candidates: [PreflightAccountReference]
}

/// Decides enough, low or unknown from a published snapshot through the shared quota read
/// model, so preflight trusts exactly the readings the app trusts. Pure: no clock or files.
public enum PreflightEvaluator {
    public static func evaluate(
        _ request: PreflightRequest,
        snapshot: Result<PreflightSnapshot, PreflightSnapshotReadFailure>,
        now: Date
    ) -> PreflightOutcome {
        func unknown(
            _ reason: PreflightReason,
            candidates: [PreflightAccountReference] = []
        ) -> PreflightOutcome {
            PreflightOutcome(
                result: .unknown,
                reason: reason,
                account: nil,
                checks: request.requirements.map {
                    PreflightCheck(
                        requirement: $0, result: .unknown, reason: reason, failure: nil,
                        window: nil, observedAt: nil, staleAfter: nil
                    )
                },
                candidates: candidates
            )
        }

        let published: PreflightSnapshot
        switch snapshot {
        case let .success(value): published = value
        case let .failure(failure): return unknown(PreflightReason(failure))
        }

        let requiredRosters = request.provider.map { [$0] } ?? QuotaProvider.allCases
        let rostersLoaded = requiredRosters.allSatisfy(published.providers.contains)
        let matches = published.accounts
            .filter { request.provider == nil || $0.provider == request.provider }
            .filter { request.accountID == nil || $0.accountID == request.accountID }
            .sorted { lhs, rhs in
                lhs.provider != rhs.provider
                    ? lhs.provider.rawValue < rhs.provider.rawValue
                    : lhs.accountID.uuidString.lowercased() < rhs.accountID.uuidString.lowercased()
            }

        // Without an exact ID, a lone account is only unambiguous once every roster it could
        // compete with has loaded. An exact UUID match stands on its own.
        guard rostersLoaded || (request.accountID != nil && matches.count == 1) else {
            return unknown(.rosterIncomplete)
        }
        guard let record = matches.first else { return unknown(.accountNotFound) }
        guard matches.count == 1 else {
            return unknown(
                .accountAmbiguous,
                candidates: matches.map { PreflightAccountReference(provider: $0.provider, accountID: $0.accountID) }
            )
        }

        let policy = QuotaReadPolicy.standard(for: record.provider)
        let reading = record.reading(at: now, policy: policy)
        let checks = request.requirements.map {
            check($0, reading: reading, policy: policy, now: now)
        }
        let result: PreflightResult
        if checks.contains(where: { $0.result == .low }) {
            result = .low
        } else if checks.contains(where: { $0.result == .unknown }) {
            result = .unknown
        } else {
            result = .enough
        }
        return PreflightOutcome(
            result: result,
            reason: checks.first(where: { $0.result == result && $0.reason != nil })?.reason,
            account: PreflightAccountReference(provider: record.provider, accountID: record.accountID),
            checks: checks,
            candidates: []
        )
    }

    private static func check(
        _ requirement: PreflightRequirement,
        reading: QuotaAccountReading,
        policy: QuotaReadPolicy,
        now: Date
    ) -> PreflightCheck {
        let observedAt = reading.freshness.lastSuccessAt
        func make(
            _ result: PreflightResult,
            _ reason: PreflightReason? = nil,
            failure: QuotaFailureReason? = nil,
            window: QuotaWindow? = nil
        ) -> PreflightCheck {
            PreflightCheck(
                requirement: requirement, result: result, reason: reason, failure: failure,
                window: window, observedAt: observedAt,
                staleAfter: observedAt?.addingTimeInterval(policy.staleAfter)
            )
        }
        func tighter(_ lhs: QuotaWindowReading, _ rhs: QuotaWindowReading) -> Bool {
            lhs.window.remainingPercent != rhs.window.remainingPercent
                ? lhs.window.remainingPercent < rhs.window.remainingPercent
                : lhs.window.kind.blocksMoreThan(rhs.window.kind)
        }

        let family = reading.windows.filter { requirement.window.includes($0.window.kind) }
        if reading.provider == .codex, reading.freshness.isFresh, reading.includedUsageAccess == .blocked {
            return make(.low, .usageBlocked)
        }
        // Zero remaining is exhausted, so it is low even for a minimum of 0.
        let below = family
            .filter { $0.isCurrent }
            .filter { $0.window.remainingPercent <= 0
                || $0.window.remainingPercent < Double(requirement.minimumPercent) }
        if let low = below.min(by: tighter) {
            return make(.low, window: low.window)
        }

        switch reading.freshness {
        case .missing:
            return make(.unknown, .noReading)
        case let .failed(reason, _, _):
            return make(.unknown, .refreshFailed, failure: reason)
        case .stale:
            let future = observedAt.map { $0 > now } ?? false
            return make(.unknown, future ? .readingFromFuture : .readingStale)
        case .fresh:
            break
        }
        if reading.provider == .codex && reading.includedUsageAccess == .unknown {
            return make(.unknown, .usageUnconfirmed)
        }
        let reportsLimit = reading.provider == .antigravity ? !family.isEmpty
            : family.contains { $0.window.kind == requirement.window.requiredKind }
        guard reportsLimit,
              !reading.unknownWindows.contains(where: requirement.window.includes) else {
            return make(.unknown, .windowMissing)
        }
        if let passed = family.first(where: \.resetPassed) {
            return make(.unknown, .windowResetPassed, window: passed.window)
        }
        return make(.enough, window: family.min(by: tighter)?.window)
    }
}
