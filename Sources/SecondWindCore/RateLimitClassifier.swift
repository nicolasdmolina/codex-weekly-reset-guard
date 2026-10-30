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

    public var durationToleranceFraction: Double

    public init(durationToleranceFraction: Double = 0.05) {
        self.durationToleranceFraction = durationToleranceFraction
    }

    public func classify(
        _ snapshot: RateLimitSnapshot,
        now: Date
    ) -> WeeklyRateLimitClassification {
        if let limitID = snapshot.limitID {
            let normalized = normalize(limitID)
            guard normalized == Self.canonicalLimitID else {
                return .rejected(.nonCanonicalLimitID(limitID))
            }
        } else if let limitName = snapshot.limitName {
            // A nil ID is valid for app-server's backward-compatible top-level snapshot,
            // but an explicit non-Codex name is not safe to assume is that snapshot.
            guard normalize(limitName) == Self.canonicalLimitID else {
                return .rejected(.nonCanonicalLimitName(limitName))
            }
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

    private func isWeeklyDuration(_ minutes: Double) -> Bool {
        let tolerance = Self.weeklyDurationMinutes * max(0, durationToleranceFraction)
        return abs(minutes - Self.weeklyDurationMinutes) <= tolerance
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
