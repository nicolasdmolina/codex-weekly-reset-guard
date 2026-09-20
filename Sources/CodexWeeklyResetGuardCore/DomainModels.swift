import Foundation

public enum RateLimitLane: String, Codable, Sendable, Equatable {
    case primary
    case secondary
}

/// An app-server rate-limit window normalized into domain values.
public struct RateLimitWindow: Codable, Sendable, Equatable {
    public var usedPercent: Double
    public var windowDurationMinutes: Double?
    public var resetsAt: Date?

    public init(
        usedPercent: Double,
        windowDurationMinutes: Double?,
        resetsAt: Date?
    ) {
        self.usedPercent = usedPercent
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }
}

/// One app-server `RateLimitSnapshot`, stamped when the complete response was read.
public struct RateLimitSnapshot: Codable, Sendable, Equatable {
    public var limitID: String?
    public var limitName: String?
    public var primary: RateLimitWindow?
    public var secondary: RateLimitWindow?
    public var observedAt: Date

    public init(
        limitID: String? = nil,
        limitName: String? = nil,
        primary: RateLimitWindow? = nil,
        secondary: RateLimitWindow? = nil,
        observedAt: Date
    ) {
        self.limitID = limitID
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
        self.observedAt = observedAt
    }
}

/// The single weekly window that is safe for the reset policy to use.
public struct CanonicalWeeklyLimit: Codable, Sendable, Equatable {
    public var lane: RateLimitLane
    public var usedPercent: Double
    public var durationMinutes: Double
    public var resetsAt: Date
    public var observedAt: Date

    public var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }

    public init(
        lane: RateLimitLane,
        usedPercent: Double,
        durationMinutes: Double,
        resetsAt: Date,
        observedAt: Date
    ) {
        self.lane = lane
        self.usedPercent = usedPercent
        self.durationMinutes = durationMinutes
        self.resetsAt = resetsAt
        self.observedAt = observedAt
    }
}

public enum ResetCreditKind: Sendable, Equatable {
    case codexRateLimits
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .codexRateLimits:
            "codexRateLimits"
        case let .unknown(value):
            value
        }
    }
}

extension ResetCreditKind: Codable {
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = value == "codexRateLimits" ? .codexRateLimits : .unknown(value)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ResetCreditStatus: Sendable, Equatable {
    case available
    case redeeming
    case redeemed
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .available:
            "available"
        case .redeeming:
            "redeeming"
        case .redeemed:
            "redeemed"
        case let .unknown(value):
            value
        }
    }
}

extension ResetCreditStatus: Codable {
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "available": self = .available
        case "redeeming": self = .redeeming
        case "redeemed": self = .redeemed
        default: self = .unknown(value)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ResetCredit: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: ResetCreditKind
    public var status: ResetCreditStatus
    public var grantedAt: Date
    public var expiresAt: Date?
    public var title: String?
    public var detail: String?

    public init(
        id: String,
        kind: ResetCreditKind,
        status: ResetCreditStatus,
        grantedAt: Date,
        expiresAt: Date?,
        title: String? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.title = title
        self.detail = detail
    }
}

/// Reset inventory from app-server. `credits == nil` means the authoritative count is
/// known but detail rows were not supplied; an empty array means rows were supplied and empty.
public struct ResetCreditInventory: Codable, Sendable, Equatable {
    public var availableCount: Int
    public var credits: [ResetCredit]?

    public init(availableCount: Int, credits: [ResetCredit]?) {
        self.availableCount = availableCount
        self.credits = credits
    }

    public func earliestExpiringAvailableCodexCredit(at now: Date) -> ResetCredit? {
        credits?
            .filter { credit in
                credit.kind == .codexRateLimits
                    && credit.status == .available
                    && (credit.expiresAt.map { $0 > now } ?? true)
            }
            .sorted { lhs, rhs in
                switch (lhs.expiresAt, rhs.expiresAt) {
                case let (left?, right?) where left != right:
                    return left < right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    if lhs.grantedAt != rhs.grantedAt {
                        return lhs.grantedAt < rhs.grantedAt
                    }
                    return lhs.id < rhs.id
                }
            }
            .first
    }
}

public enum MonitorPhase: String, Codable, Sendable, Equatable {
    case disabled
    case healthy
    case nearLimit
    case confirming
    case redeeming
    case verifying
    case verified
    case noCredits
    case attentionRequired
}

public struct ThresholdConfirmation: Codable, Sendable, Equatable {
    public var weeklyResetAt: Date
    public var count: Int
    /// The oldest reading in this confirmation sequence. Absent in older saved state, which
    /// must be requalified before a never-sent reset attempt can cross the network boundary.
    public var firstObservedAt: Date?
    public var lastObservedAt: Date
    public var lastRemainingPercent: Double

    public init(
        weeklyResetAt: Date,
        count: Int,
        lastObservedAt: Date,
        lastRemainingPercent: Double,
        firstObservedAt: Date? = nil
    ) {
        self.weeklyResetAt = weeklyResetAt
        self.count = count
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.lastRemainingPercent = lastRemainingPercent
    }
}

public enum ConsumeResetOutcome: String, Codable, Sendable, Equatable {
    case reset
    case nothingToReset
    case noCredit
    case alreadyRedeemed
}

public enum RedemptionAttemptPhase: String, Codable, Sendable, Equatable {
    /// The attempt and key must be durably persisted before a network call is made.
    case prepared
    case requestInFlight
    /// The response was ambiguous. Retrying must reuse this attempt's key.
    case retryable
    case awaitingVerification
    case succeeded
    case nothingToReset
    case noCredit
    /// The server returned a definite rejection, so this request must not be retried automatically.
    case requestRejected
    case verificationFailed
}

public struct RedemptionAttempt: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var profileID: String
    public var idempotencyKey: String
    public var creditID: String?
    public var weeklyResetAtBefore: Date
    public var weeklyUsedPercentBefore: Double
    public var availableCreditCountBefore: Int
    public var preparedAt: Date
    public var updatedAt: Date
    public var phase: RedemptionAttemptPhase
    public var consumeOutcome: ConsumeResetOutcome?

    public init(
        schemaVersion: Int = RedemptionAttempt.currentSchemaVersion,
        profileID: String,
        idempotencyKey: String,
        creditID: String?,
        weeklyResetAtBefore: Date,
        weeklyUsedPercentBefore: Double,
        availableCreditCountBefore: Int,
        preparedAt: Date,
        updatedAt: Date? = nil,
        phase: RedemptionAttemptPhase = .prepared,
        consumeOutcome: ConsumeResetOutcome? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.profileID = profileID
        self.idempotencyKey = idempotencyKey
        self.creditID = creditID
        self.weeklyResetAtBefore = weeklyResetAtBefore
        self.weeklyUsedPercentBefore = weeklyUsedPercentBefore
        self.availableCreditCountBefore = availableCreditCountBefore
        self.preparedAt = preparedAt
        self.updatedAt = updatedAt ?? preparedAt
        self.phase = phase
        self.consumeOutcome = consumeOutcome
    }
}

public struct MonitorState: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var profileID: String
    public var isEnabled: Bool
    public var phase: MonitorPhase
    public var confirmation: ThresholdConfirmation?
    public var lastWeeklyLimit: CanonicalWeeklyLimit?
    public var attempt: RedemptionAttempt?
    public var attentionMessage: String?

    public init(
        schemaVersion: Int = MonitorState.currentSchemaVersion,
        profileID: String,
        isEnabled: Bool = true,
        phase: MonitorPhase = .healthy,
        confirmation: ThresholdConfirmation? = nil,
        lastWeeklyLimit: CanonicalWeeklyLimit? = nil,
        attempt: RedemptionAttempt? = nil,
        attentionMessage: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.profileID = profileID
        self.isEnabled = isEnabled
        self.phase = isEnabled ? phase : .disabled
        self.confirmation = confirmation
        self.lastWeeklyLimit = lastWeeklyLimit
        self.attempt = attempt
        self.attentionMessage = attentionMessage
    }
}
