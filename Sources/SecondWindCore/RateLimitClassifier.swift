import Foundation

public enum RateLimitClassificationFailure: Sendable, Equatable, Error {
    case nonCanonicalLimitID(String)
    case nonCanonicalLimitName(String)
    case weeklyWindowMissing
    case ambiguousWeeklyWindows
    case invalidWeeklyUsage
    case missingWeeklyReset
    case expiredWeeklyReset
}

public enum WeeklyRateLimitClassification: Sendable, Equatable {
    case canonical(CanonicalWeeklyLimit)
    case rejected(RateLimitClassificationFailure)
}

public struct RateLimitClassifier: Sendable {
    public static let canonicalLimitID = "codex"
    public static let weeklyDurationMinutes = 10_080.0
    public static let sessionDurationMinutes = 300.0

    public var durationToleranceFraction: Double

    public init(durationToleranceFraction: Double = 0.05) {
        self.durationToleranceFraction = durationToleranceFraction
    }

    public func classify(
        _ snapshot: RateLimitSnapshot,
        now: Date
    ) -> WeeklyRateLimitClassification {
        if let failure = identityFailure(snapshot) {
            return .rejected(failure)
        }

        let candidates = [
            (RateLimitLane.primary, snapshot.primary),
            (RateLimitLane.secondary, snapshot.secondary),
        ].compactMap { lane, window -> (RateLimitLane, RateLimitWindow)? in
            guard let window,
                  let duration = window.windowDurationMinutes,
                  duration.isFinite,
                  isWeeklyDuration(duration)
            else {
                return nil
            }
            return (lane, window)
        }

        guard !candidates.isEmpty else {
            return .rejected(.weeklyWindowMissing)
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            return .rejected(.ambiguousWeeklyWindows)
        }

        let (lane, window) = candidate
        guard window.usedPercent.isFinite,
              (0...100).contains(window.usedPercent),
              let duration = window.windowDurationMinutes
        else {
            return .rejected(.invalidWeeklyUsage)
        }
        guard let resetsAt = window.resetsAt else {
            return .rejected(.missingWeeklyReset)
        }
        guard resetsAt > now else {
            return .rejected(.expiredWeeklyReset)
        }

        return .canonical(
            CanonicalWeeklyLimit(
                lane: lane,
                usedPercent: window.usedPercent,
                durationMinutes: duration,
                resetsAt: resetsAt,
                observedAt: snapshot.observedAt
            )
        )
    }

    /// Labels the canonical Codex bucket's five-hour and weekly windows for display, alerts and
    /// preflight. Never use it for the reset policy: only `classify` may authorize a reset.
    /// Nil when the snapshot is not the canonical Codex bucket.
    public func quotaObservation(
        _ snapshot: RateLimitSnapshot,
        inventory: ResetInventoryReport,
        includedUsageAccess: IncludedUsageAccess = .unreported
    ) -> QuotaObservation? {
        guard identityFailure(snapshot) == nil else { return nil }
        // Count every lane that claims a length first, as `classify` does, so a second weekly lane
        // makes the week ambiguous even when that lane is itself incomplete.
        var found: [QuotaWindowKind: [RateLimitWindow]] = [:]
        var hasUnlabelledLane = false
        for window in [snapshot.primary, snapshot.secondary].compactMap({ $0 }) {
            guard let duration = window.windowDurationMinutes, duration.isFinite else {
                hasUnlabelledLane = true
                continue
            }
            if isWeeklyDuration(duration) {
                found[.weekly, default: []].append(window)
            } else if isDuration(duration, near: Self.sessionDurationMinutes) {
                found[.session, default: []].append(window)
            } else {
                hasUnlabelledLane = true
            }
        }
        // The sole candidate must also be complete: Codex always sends a valid percentage and a
        // reset time. Ambiguous or incomplete windows are unknown, never shown. Some plans have
        // no five-hour limit: when every lane sent is labelled and none is five hours, the account
        // has none, rather than an unknown one.
        let hasNoSessionLimit = !hasUnlabelledLane && found[.session] == nil && (found[.weekly]?.count ?? 0) <= 1
        let expected: [QuotaWindowKind] = hasNoSessionLimit ? [.weekly] : [.session, .weekly]
        let windows = expected.compactMap { kind -> QuotaWindow? in
            guard let matches = found[kind], matches.count == 1, let window = matches.first,
                  window.usedPercent.isFinite,
                  (0...100).contains(window.usedPercent),
                  window.resetsAt != nil
            else {
                return nil
            }
            return QuotaWindow(kind: kind, usedPercent: window.usedPercent, resetsAt: window.resetsAt)
        }
        return QuotaObservation(
            observedAt: snapshot.observedAt,
            windows: windows,
            unreportedWindows: expected.filter { kind in !windows.contains { $0.kind == kind } },
            inventory: inventory,
            includedUsageAccess: includedUsageAccess
        )
    }

    private func identityFailure(_ snapshot: RateLimitSnapshot) -> RateLimitClassificationFailure? {
        if let limitID = snapshot.limitID {
            guard normalize(limitID) == Self.canonicalLimitID else {
                return .nonCanonicalLimitID(limitID)
            }
        } else if let limitName = snapshot.limitName {
            // A nil ID is valid for app-server's backward-compatible top-level snapshot,
            // but an explicit non-Codex name is not safe to assume is that snapshot.
            guard normalize(limitName) == Self.canonicalLimitID else {
                return .nonCanonicalLimitName(limitName)
            }
        }
        return nil
    }

    private func isWeeklyDuration(_ minutes: Double) -> Bool {
        isDuration(minutes, near: Self.weeklyDurationMinutes)
    }

    private func isDuration(_ minutes: Double, near target: Double) -> Bool {
        let tolerance = target * max(0, durationToleranceFraction)
        return abs(minutes - target) <= tolerance
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
