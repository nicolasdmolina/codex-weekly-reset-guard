import Foundation

// A provider-neutral account of what each quota reading says and how far to trust it. It is
// display, alert and preflight data only: nothing here can authorize a reset. Redemption reads
// the canonical weekly window through `RateLimitClassifier.classify` and nothing else.

public enum QuotaProvider: String, Codable, Sendable, Hashable, CaseIterable {
    case codex
    case claude
}

public enum QuotaWindowKind: Hashable, Codable, Sendable {
    /// The rolling five-hour limit.
    case session
    /// The weekly limit shared by every model.
    case weekly
    /// A weekly limit for one model family, such as Claude's "Sonnet only".
    case modelWeekly(String)

    public var key: String {
        switch self {
        case .session: "session"
        case .weekly: "weekly"
        case let .modelWeekly(name): "weekly:\(name)"
        }
    }
}

public struct QuotaWindow: Equatable, Sendable, Identifiable {
    public var kind: QuotaWindowKind
    public var usedPercent: Double
    public var resetsAt: Date?

    public var id: String { kind.key }
    public var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }

    public init(kind: QuotaWindowKind, usedPercent: Double, resetsAt: Date?) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public enum ResetCreditExpiry: Hashable, Sendable {
    case on(Date)
    /// The provider sent an explicit null: this reset does not expire.
    case never
    /// The provider omitted the expiry. Unknown, never assumed to be `.never`.
    case unspecified
}

public enum ResetCreditExpiries: Equatable, Sendable {
    /// One entry per listed still-available Codex reset: dated soonest first, then `.never`,
    /// then `.unspecified`. The provider may cap the list below `availableCount`.
    case listed([ResetCreditExpiry])
    /// The provider returned a count but no individual resets.
    case unlisted
}

/// What can honestly be said about the next saved reset to expire.
public enum ResetExpiryOutlook: Equatable, Sendable {
    case noneSaved
    case on(Date)
    /// Every saved reset is listed and none expires.
    case never
    /// Count only, a capped list, or a row without its expiry.
    case unknown
}

/// Whether the provider allows ordinary included usage, from `ordinaryUsageAllowed`.
/// Display and all-clear only; it never authorizes a reset.
public enum IncludedUsageAccess: String, Codable, Equatable, Sendable {
    /// The field was absent (older provider).
    case unreported
    /// The provider sent null: unavailable. Recovery must not be inferred from percentages.
    case unknown
    case blocked
    case allowed
}

/// Saved Codex resets exactly as one successful inventory query reported them.
public struct ResetInventorySnapshot: Equatable, Sendable {
    public var availableCount: Int
    public var expiries: ResetCreditExpiries
    public var fetchedAt: Date

    public init(availableCount: Int, expiries: ResetCreditExpiries, fetchedAt: Date) {
        self.availableCount = availableCount
        self.expiries = expiries
        self.fetchedAt = fetchedAt
    }

    /// True when the listed resets cover `availableCount`, so "soonest" means soonest overall.
    public var isComplete: Bool {
        guard case let .listed(entries) = expiries else { return availableCount == 0 }
        return entries.count >= availableCount
    }

    /// The soonest expiry after `now`, only when it is the soonest of every saved reset: the list
    /// is complete and no listed row omitted its expiry. Use `expiryOutlook(after:)` to say why not.
    public func nextExpiry(after now: Date) -> Date? {
        if case let .on(date) = expiryOutlook(after: now) { return date }
        return nil
    }

    public func expiryOutlook(after now: Date) -> ResetExpiryOutlook {
        guard availableCount > 0 else { return .noneSaved }
        guard isComplete, case let .listed(entries) = expiries,
              !entries.contains(.unspecified)
        else {
            return .unknown
        }
        let upcoming = entries.compactMap { entry -> Date? in
            if case let .on(date) = entry, date > now { return date }
            return nil
        }
        if let soonest = upcoming.min() { return .on(soonest) }
        return entries.allSatisfy { $0 == .never } ? .never : .unknown
    }
}

public enum ResetInventoryReport: Equatable, Sendable {
    case reported(ResetInventorySnapshot)
    /// The response had no authoritative inventory. Unknown, never zero.
    case omitted
    /// The provider has no saved resets this app reads.
    case notTracked
}

/// One successful quota read.
public struct QuotaObservation: Equatable, Sendable {
    public var observedAt: Date
    public var windows: [QuotaWindow]
    /// Windows the provider normally supplies but did not, or supplied ambiguously.
    public var unreportedWindows: [QuotaWindowKind]
    public var inventory: ResetInventoryReport
    public var includedUsageAccess: IncludedUsageAccess

    public init(
        observedAt: Date,
        windows: [QuotaWindow],
        unreportedWindows: [QuotaWindowKind] = [],
        inventory: ResetInventoryReport,
        includedUsageAccess: IncludedUsageAccess = .unreported
    ) {
        self.observedAt = observedAt
        self.windows = windows
        self.unreportedWindows = unreportedWindows
        self.inventory = inventory
        self.includedUsageAccess = includedUsageAccess
    }
}

public enum QuotaFailureReason: Equatable, Sendable {
    case signInRequired
    case wrongAccount
    case noPlanLimits
    /// The provider answered in a shape that cannot be trusted.
    case unreadable
    /// The provider or its local tool could not be reached.
    case unavailable
    /// Polling stopped on purpose and waits for the user to reconnect.
    case monitoringStopped
}

public struct QuotaRefreshFailure: Equatable, Sendable {
    public var failedAt: Date
    public var reason: QuotaFailureReason

    public init(failedAt: Date, reason: QuotaFailureReason) {
        self.failedAt = failedAt
        self.reason = reason
    }
}

public struct QuotaReadPolicy: Equatable, Sendable {
    /// A reading older than this is stale: two refresh cycles.
    public var staleAfter: TimeInterval
    public var lowRemainingPercent: Double

    public init(staleAfter: TimeInterval, lowRemainingPercent: Double = 10) {
        self.staleAfter = staleAfter
        self.lowRemainingPercent = lowRemainingPercent
    }

    public static let codex = QuotaReadPolicy(staleAfter: 120)
    public static let claude = QuotaReadPolicy(staleAfter: 600)

    public static func standard(for provider: QuotaProvider) -> QuotaReadPolicy {
        switch provider {
        case .codex: codex
        case .claude: claude
        }
    }
}

/// Everything known about one account's quota.
public struct QuotaAccountRecord: Equatable, Sendable, Identifiable {
    public let provider: QuotaProvider
    public let accountID: UUID
    public private(set) var lastSuccess: QuotaObservation?
    public private(set) var lastFailure: QuotaRefreshFailure?
    public private(set) var lastKnownInventory: ResetInventorySnapshot?
    /// The last success was loaded from disk and no refresh has confirmed it this session.
    public private(set) var lastSuccessRestored: Bool = false

    public init(
        provider: QuotaProvider,
        accountID: UUID,
        lastSuccess: QuotaObservation? = nil,
        lastFailure: QuotaRefreshFailure? = nil,
        lastSuccessRestored: Bool = false
    ) {
        self.provider = provider
        self.accountID = accountID
        if let lastSuccess {
            recordSuccess(lastSuccess)
            self.lastSuccessRestored = lastSuccessRestored
        }
        self.lastFailure = lastFailure
    }

    /// `provider:lowercased-uuid`, the same text as the app's account token.
    public var id: String { "\(provider.rawValue):\(accountID.uuidString.lowercased())" }

    public mutating func recordSuccess(_ observation: QuotaObservation) {
        lastSuccess = observation
        lastFailure = nil
        lastSuccessRestored = false
        if case let .reported(snapshot) = observation.inventory {
            lastKnownInventory = snapshot
        }
    }

    /// `failedAt` marks when this run of failures began; repeating the same reason keeps it.
    public mutating func recordFailure(_ reason: QuotaFailureReason, at date: Date) {
        guard lastFailure?.reason != reason else { return }
        lastFailure = QuotaRefreshFailure(failedAt: date, reason: reason)
    }

    public func reading(at now: Date, policy: QuotaReadPolicy? = nil) -> QuotaAccountReading {
        QuotaAccountReading(record: self, now: now, policy: policy ?? .standard(for: provider))
    }
}

public enum QuotaFreshness: Equatable, Sendable {
    /// Never read successfully and never failed: still connecting.
    case missing
    case fresh(lastSuccessAt: Date)
    /// No refresh failed, but none succeeded recently either.
    case stale(lastSuccessAt: Date)
    case failed(QuotaFailureReason, failedAt: Date, lastSuccessAt: Date?)

    public var lastSuccessAt: Date? {
        switch self {
        case .missing: nil
        case let .fresh(date), let .stale(date): date
        case let .failed(_, _, date): date
        }
    }

    public var isFresh: Bool {
        if case .fresh = self { return true }
        return false
    }
}

public enum QuotaLevel: Int, Comparable, Sendable {
    case ok
    case low
    case exhausted

    public static func < (lhs: QuotaLevel, rhs: QuotaLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct QuotaWindowReading: Equatable, Sendable, Identifiable {
    public var window: QuotaWindow
    /// The reset time has passed since this value was read; the refill is not yet confirmed.
    public var resetPassed: Bool
    /// The account's reading is fresh and this window has not reset since.
    public var isCurrent: Bool
    public var level: QuotaLevel

    public var id: String { window.id }
}

public enum ResetInventoryReading: Equatable, Sendable {
    case notTracked
    /// The latest read had no authoritative inventory, or there has been no read yet.
    case unknown(lastKnown: ResetInventorySnapshot?)
    case known(ResetInventorySnapshot, isCurrent: Bool)
}

public struct QuotaAccountReading: Equatable, Sendable, Identifiable {
    public let provider: QuotaProvider
    public let accountID: UUID
    public let freshness: QuotaFreshness
    public let windows: [QuotaWindowReading]
    public let unknownWindows: [QuotaWindowKind]
    public let inventory: ResetInventoryReading
    /// From the last good reading; `.unreported` when there is none.
    public let includedUsageAccess: IncludedUsageAccess
    /// The last good reading came from disk and nothing has confirmed or failed it this session.
    /// It reads as stale, with its own timestamp, until the first refresh.
    public let isRestoredUnverified: Bool

    public var id: String { "\(provider.rawValue):\(accountID.uuidString.lowercased())" }

    init(record: QuotaAccountRecord, now: Date, policy: QuotaReadPolicy) {
        provider = record.provider
        accountID = record.accountID

        let success = record.lastSuccess
        if let failure = record.lastFailure {
            freshness = .failed(
                failure.reason,
                failedAt: failure.failedAt,
                lastSuccessAt: success?.observedAt
            )
        } else if let success {
            let age = now.timeIntervalSince(success.observedAt)
            freshness = !record.lastSuccessRestored && age >= 0 && age < policy.staleAfter
                ? .fresh(lastSuccessAt: success.observedAt)
                : .stale(lastSuccessAt: success.observedAt)
        } else {
            freshness = .missing
        }
        isRestoredUnverified = record.lastSuccessRestored && record.lastFailure == nil
        includedUsageAccess = success?.includedUsageAccess ?? .unreported

        let accountFresh = freshness.isFresh
        windows = (success?.windows ?? []).map { window in
            let resetPassed = window.resetsAt.map { $0 <= now } ?? false
            let remaining = window.remainingPercent
            let level: QuotaLevel = remaining <= 0
                ? .exhausted
                : remaining <= policy.lowRemainingPercent ? .low : .ok
            return QuotaWindowReading(
                window: window,
                resetPassed: resetPassed,
                isCurrent: accountFresh && !resetPassed,
                level: level
            )
        }
        unknownWindows = success?.unreportedWindows ?? []

        switch success?.inventory {
        case .notTracked:
            inventory = .notTracked
        case let .reported(snapshot):
            let expiryPassed = snapshot.nextExpiryPassed(by: now)
            inventory = .known(snapshot, isCurrent: accountFresh && !expiryPassed)
        case .omitted, nil:
            inventory = record.provider == .claude
                ? .notTracked
                : .unknown(lastKnown: record.lastKnownInventory)
        }
    }

    /// The window with the least room left whose value still stands. A window past its reset
    /// is excluded: it has probably refilled and only a new reading can say by how much.
    public var mostConstrained: QuotaWindowReading? {
        windows
            .filter { !$0.resetPassed }
            .min { lhs, rhs in
                if lhs.window.remainingPercent != rhs.window.remainingPercent {
                    return lhs.window.remainingPercent < rhs.window.remainingPercent
                }
                return lhs.window.kind.blocksMoreThan(rhs.window.kind)
            }
    }

    /// The most constrained window when it is low or worse. Check `isCurrent` before alerting.
    public var warning: QuotaWindowReading? {
        mostConstrained.flatMap { $0.level >= .low ? $0 : nil }
    }

    /// Every current window at `.low` or worse.
    public var currentLowWindows: [QuotaWindowReading] {
        windows.filter { $0.isCurrent && $0.level >= .low }
    }

    /// The windows alone are fresh and complete: every expected window was reported and none has
    /// reset since. A Claude window may omit its reset time and still count, matching preflight.
    public var hasConfirmedWindows: Bool {
        freshness.isFresh
            && !windows.isEmpty
            && unknownWindows.isEmpty
            && windows.allSatisfy(\.isCurrent)
    }

    /// Everything the account promises is current: its windows, its saved-reset count (Codex),
    /// and the provider has not withheld included usage. Anything less keeps it out of all-clear.
    public var isConfirmed: Bool {
        let inventoryCurrent: Bool = switch inventory {
        case .notTracked: true
        case .unknown: false
        case let .known(_, isCurrent): isCurrent
        }
        let accessAllowed: Bool = switch includedUsageAccess {
        case .unreported, .allowed: true
        case .unknown, .blocked: false
        }
        return hasConfirmedWindows && inventoryCurrent && accessAllowed
    }

    static func moreSevere(_ lhs: QuotaWindowReading, _ rhs: QuotaWindowReading) -> Bool {
        if lhs.level != rhs.level { return lhs.level > rhs.level }
        if lhs.window.remainingPercent != rhs.window.remainingPercent {
            return lhs.window.remainingPercent < rhs.window.remainingPercent
        }
        return lhs.window.kind.blocksMoreThan(rhs.window.kind)
    }
}

public struct QuotaWarning: Equatable, Sendable {
    public let provider: QuotaProvider
    public let accountID: UUID
    public let window: QuotaWindowReading

    public var accountKey: String { "\(provider.rawValue):\(accountID.uuidString.lowercased())" }

    /// One alert per account, window and renewal time.
    public var alertKey: String {
        let reset = window.window.resetsAt.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "unknown"
        return "\(accountKey)|\(window.window.kind.key)@\(reset)"
    }
}

public struct QuotaSummary: Equatable, Sendable {
    public let accounts: [QuotaAccountReading]
    /// Every current low or exhausted window, most severe first.
    public let warnings: [QuotaWarning]
    /// Accounts without a fully current reading, in input order.
    public let unconfirmedAccountIDs: [String]
    public let lowestCurrentRemainingPercent: Double?

    public init(readings: [QuotaAccountReading]) {
        accounts = readings
        warnings = readings
            .flatMap { reading in
                reading.currentLowWindows.map {
                    QuotaWarning(provider: reading.provider, accountID: reading.accountID, window: $0)
                }
            }
            .sorted { QuotaAccountReading.moreSevere($0.window, $1.window) }
        unconfirmedAccountIDs = readings.filter { !$0.isConfirmed }.map(\.id)
        lowestCurrentRemainingPercent = readings
            .flatMap(\.windows)
            .filter(\.isCurrent)
            .map(\.window.remainingPercent)
            .min()
    }

    /// Only when every account has a current reading and none is low.
    public var isAllClear: Bool {
        !accounts.isEmpty && warnings.isEmpty && unconfirmedAccountIDs.isEmpty
    }
}

extension QuotaWindowKind {
    /// Session and all-model weekly limits stop every model, so they win ties.
    func blocksMoreThan(_ other: QuotaWindowKind) -> Bool {
        rank < other.rank
    }

    private var rank: Int {
        switch self {
        case .session: 0
        case .weekly: 1
        case .modelWeekly: 2
        }
    }
}

extension ResetInventorySnapshot {
    func nextExpiryPassed(by now: Date) -> Bool {
        guard case let .listed(entries) = expiries else { return false }
        return entries.contains { entry in
            if case let .on(date) = entry { return date <= now }
            return false
        }
    }
}

extension ClaudeUsageReport {
    private var unreportedWindowKinds: [QuotaWindowKind] {
        var kinds: [QuotaWindowKind] = []
        if weekly == nil { kinds.append(.weekly) }
        for scope in unreadableScopes {
            switch scope {
            case .session: kinds.append(.session)
            case .weekly: break // Unreadable means missing, which is already unknown.
            case let .modelWeekly(name): kinds.append(.modelWeekly(name))
            }
        }
        return kinds
    }

    public var quotaObservation: QuotaObservation {
        QuotaObservation(
            observedAt: observedAt,
            windows: allWindows.map { window in
                let kind: QuotaWindowKind = switch window.scope {
                case .session: .session
                case .weekly: .weekly
                case let .modelWeekly(name): .modelWeekly(name)
                }
                return QuotaWindow(kind: kind, usedPercent: window.usedPercent, resetsAt: window.resetsAt)
            },
            // The all-model weekly limit applies to every plan; missing, it is unknown. Some plans
            // have no five-hour session limit, so a session line Claude Code leaves out is not
            // shown. A named limit Claude Code could not read is unknown.
            unreportedWindows: unreportedWindowKinds,
            inventory: .notTracked
        )
    }
}
