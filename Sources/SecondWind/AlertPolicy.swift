import Foundation
import SecondWindCore

/// Notices a controller decides on its own and hands to the router with their account.
enum AlertPost: Equatable, Sendable {
    /// A Claude window crossed the low threshold. `ClaudeAlertPolicy` already deduplicated it.
    case lowQuota(AccountRef, name: String, window: QuotaWindow)
    /// Second Wind's own Codex redemption was verified.
    case resetApplied(AccountRef, name: String)
    /// A Codex redemption could not be verified and automatic resets stopped.
    case resetNeedsAttention(AccountRef, name: String)
}

enum AttentionReason: String, Codable, Sendable {
    case resetNeedsAttention
    case signInRequired
    case wrongAccount
    case monitoringStopped

    init?(_ reason: QuotaFailureReason) {
        switch reason {
        case .signInRequired: self = .signInRequired
        case .wrongAccount: self = .wrongAccount
        case .monitoringStopped: self = .monitoringStopped
        case .noPlanLimits, .unreadable, .unavailable: return nil
        }
    }
}

enum ExpiryStage: String, Codable, Sendable, CaseIterable {
    case dayBefore
    case hourBefore

    var lead: TimeInterval {
        switch self {
        case .dayBefore: 24 * 60 * 60
        case .hourBefore: 60 * 60
        }
    }
}

enum AlertNotice: Equatable, Sendable {
    case lowQuota(QuotaWindow)
    case limitRefilled(QuotaWindowKind)
    case savedResetExpiring(ExpiryStage, expiresAt: Date)
    case resetApplied
    case needsAttention(AttentionReason)
    case test

    /// Notices whose only duplicate guard is the alert ledger. They are never shown when the
    /// ledger could not be saved, so a relaunch cannot repeat them.
    var needsDurableLedger: Bool {
        switch self {
        case .limitRefilled, .savedResetExpiring, .needsAttention: true
        case .lowQuota, .resetApplied, .test: false
        }
    }
}

/// One notification. `id` is also the system request identifier, so re-adding replaces.
struct AlertDelivery: Equatable, Sendable {
    let id: String
    let account: AccountRef?
    let name: String
    let notice: AlertNotice
    /// Set for reminders the system shows later; nil shows now.
    var fireAt: Date?
}

struct AlertPlan: Equatable, Sendable {
    var deliveries: [AlertDelivery] = []
    var cancellations: [String] = []

    static func += (lhs: inout AlertPlan, rhs: AlertPlan) {
        lhs.deliveries += rhs.deliveries
        lhs.cancellations += rhs.cancellations
    }
}

/// Everything alert routing remembers across relaunch. Keys are `AccountRef.token`.
struct AlertLedger: Codable, Equatable, Sendable {
    struct Sent: Codable, Equatable, Sendable {
        /// When the entry stops mattering and is pruned.
        var until: Date
        /// Set while a reminder waits in the system scheduler.
        var fireAt: Date?
    }

    /// A window seen used up, waiting for a confirmed refill.
    struct Blocked: Codable, Equatable, Sendable {
        var cycle: String
        var resetsAt: Date?
        var savedResets: Int?
    }

    struct Account: Codable, Equatable, Sendable {
        /// The newest reading already processed. Older or equal readings are ignored.
        var lastReadingAt: Date
        var blocked: [String: Blocked] = [:]
    }

    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var savedResetExpiry = false
    var limitRefilled = false
    var accounts: [String: Account] = [:]
    var sent: [String: Sent] = [:]

    var preferences: AlertPreferences {
        AlertPreferences(savedResetExpiry: savedResetExpiry, limitRefilled: limitRefilled)
    }
}

/// Decides every notice from confirmed readings and the ledger. Pure: no clock, no I/O.
enum AlertPolicy {
    static let refillMemory: TimeInterval = 35 * 24 * 60 * 60

    static func ingest(
        _ record: QuotaAccountRecord,
        name: String,
        ledger: inout AlertLedger,
        now: Date
    ) -> AlertPlan {
        prune(&ledger, now: now)
        let account = AccountRef(record)
        let token = account.token
        var plan = AlertPlan()

        // Fresh per the provider's read policy: newer than two refresh cycles, not in the future,
        // and with no failed refresh since.
        let verified = record.reading(at: now)
        if let reading = record.lastSuccess,
           verified.freshness.isFresh,
           reading.observedAt > (ledger.accounts[token]?.lastReadingAt ?? .distantPast) {
            var entry = ledger.accounts[token] ?? AlertLedger.Account(lastReadingAt: reading.observedAt)
            entry.lastReadingAt = reading.observedAt
            ledger.sent = ledger.sent.filter { !$0.key.hasPrefix("\(token)|attention|") }
            let savedResets = record.lastKnownInventory?.availableCount
            let refills = verified.windows.filter(\.isCurrent).compactMap { current in
                trackRefill(
                    current.window,
                    observedAt: reading.observedAt,
                    savedResets: savedResets,
                    usageAllowed: allowsUse(reading, provider: record.provider),
                    entry: &entry,
                    account: account,
                    name: name,
                    ledger: &ledger,
                    now: now
                )
            }
            plan.deliveries.append(contentsOf: refills)
            ledger.accounts[token] = entry
            if case let .reported(snapshot) = reading.inventory {
                let listed: [ResetCreditExpiry] = switch snapshot.expiries {
                case let .listed(entries): entries
                case .unlisted: []
                }
                let dates = listed.compactMap { expiry -> Date? in
                    if case let .on(date) = expiry { return date }
                    return nil
                }
                // Codex may cap the list or send only a count. Only a list as long as the count,
                // or a confirmed zero, proves a reset missing from it is gone.
                plan += reconcileExpiries(
                    dates,
                    isComplete: listed.count >= snapshot.availableCount,
                    account: account,
                    name: name,
                    ledger: &ledger,
                    now: now
                )
            }
        }

        if let failure = record.lastFailure,
           let reason = AttentionReason(failure.reason),
           ledger.accounts[token] != nil,
           isRecent(failure.failedAt, now: now, policy: .standard(for: record.provider)) {
            plan += attention(reason, account: account, name: name, ledger: &ledger)
        }
        return plan
    }

    static func post(_ post: AlertPost, ledger: inout AlertLedger, now: Date) -> AlertPlan {
        prune(&ledger, now: now)
        switch post {
        case let .lowQuota(account, name, window):
            let id = "\(account.token)|low|\(window.kind.key)|\(cycle(resetsAt: window.resetsAt, observedAt: nil))"
            return AlertPlan(deliveries: [
                AlertDelivery(id: id, account: account, name: name, notice: .lowQuota(window)),
            ])
        case let .resetApplied(account, name):
            ledger.accounts[account.token]?.blocked[QuotaWindowKind.weekly.key] = nil
            let id = "\(account.token)|applied|\(minute(now))"
            return AlertPlan(deliveries: [
                AlertDelivery(id: id, account: account, name: name, notice: .resetApplied),
            ])
        case let .resetNeedsAttention(account, name):
            return attention(.resetNeedsAttention, account: account, name: name, ledger: &ledger)
        }
    }

    static func setPreferences(
        _ preferences: AlertPreferences,
        ledger: inout AlertLedger,
        now: Date
    ) -> AlertPlan {
        prune(&ledger, now: now)
        ledger.savedResetExpiry = preferences.savedResetExpiry
        ledger.limitRefilled = preferences.limitRefilled
        guard !preferences.savedResetExpiry else { return AlertPlan() }
        return cancelPending(ledger: &ledger, now: now) { $0.contains("|expiry|") }
    }

    /// A provider's roster is authoritative for that provider: any of its accounts the ledger
    /// still knows but the roster no longer lists are forgotten. Other providers are untouched.
    static func keepOnly(
        _ present: Set<String>,
        of provider: QuotaProvider,
        ledger: inout AlertLedger,
        now: Date
    ) -> AlertPlan {
        let prefix = "\(provider.rawValue):"
        let known = Set(ledger.accounts.keys)
            .union(ledger.sent.keys.compactMap { $0.split(separator: "|").first.map(String.init) })
        var plan = AlertPlan()
        for token in known.filter({ $0.hasPrefix(prefix) && !present.contains($0) }).sorted() {
            plan += forget(token, ledger: &ledger, now: now)
        }
        return plan
    }

    /// Forgets an account and withdraws its scheduled reminders.
    static func forget(_ token: String, ledger: inout AlertLedger, now: Date) -> AlertPlan {
        ledger.accounts[token] = nil
        let prefix = "\(token)|"
        let plan = cancelPending(ledger: &ledger, now: now) { $0.hasPrefix(prefix) }
        ledger.sent = ledger.sent.filter { !$0.key.hasPrefix(prefix) }
        return plan
    }

    private static func trackRefill(
        _ window: QuotaWindow,
        observedAt: Date,
        savedResets: Int?,
        usageAllowed: Bool,
        entry: inout AlertLedger.Account,
        account: AccountRef,
        name: String,
        ledger: inout AlertLedger,
        now: Date
    ) -> AlertDelivery? {
        let key = window.kind.key
        if window.remainingPercent <= 0 {
            if var open = entry.blocked[key], !isLater(window.resetsAt, than: open.resetsAt) {
                open.savedResets = savedResets
                entry.blocked[key] = open
            } else {
                entry.blocked[key] = AlertLedger.Blocked(
                    cycle: cycle(resetsAt: window.resetsAt, observedAt: observedAt),
                    resetsAt: window.resetsAt,
                    savedResets: savedResets
                )
            }
            return nil
        }

        guard window.remainingPercent > 0, let open = entry.blocked[key] else {
            return nil
        }
        // A reading from before the blocked cycle is the provider going backwards, not a refill.
        if isLater(open.resetsAt, than: window.resetsAt) { return nil }
        guard usageAllowed else { return nil }
        entry.blocked[key] = nil
        // A spent saved reset explains the refill, and redemptions announce themselves.
        if let before = open.savedResets, let after = savedResets, after < before { return nil }

        let id = "\(account.token)|refill|\(key)|\(open.cycle)"
        guard ledger.limitRefilled, ledger.sent[id] == nil else { return nil }
        ledger.sent[id] = AlertLedger.Sent(until: now.addingTimeInterval(refillMemory))
        return AlertDelivery(id: id, account: account, name: name, notice: .limitRefilled(window.kind))
    }

    private static func reconcileExpiries(
        _ expiries: [Date],
        isComplete: Bool,
        account: AccountRef,
        name: String,
        ledger: inout AlertLedger,
        now: Date
    ) -> AlertPlan {
        let prefix = "\(account.token)|expiry|"
        var plan = AlertPlan()
        var wanted = Set<String>()

        if ledger.savedResetExpiry {
            // Resets expiring in the same minute share one reminder per stage.
            let groups = Dictionary(grouping: expiries.filter { $0 > now }, by: minute)
            for (expiryMinute, dates) in groups.sorted(by: { $0.key < $1.key }) {
                guard let expiresAt = dates.min() else { continue }
                let stageID = { (stage: ExpiryStage) in "\(prefix)\(expiryMinute)|\(stage.rawValue)" }
                var due: [ExpiryStage] = []
                for stage in ExpiryStage.allCases {
                    let fireAt = expiresAt.addingTimeInterval(-stage.lead)
                    guard fireAt > now else {
                        due.append(stage)
                        continue
                    }
                    let id = stageID(stage)
                    wanted.insert(id)
                    guard ledger.sent[id] == nil else { continue }
                    ledger.sent[id] = AlertLedger.Sent(until: expiresAt, fireAt: fireAt)
                    plan.deliveries.append(AlertDelivery(
                        id: id,
                        account: account,
                        name: name,
                        notice: .savedResetExpiring(stage, expiresAt: expiresAt),
                        fireAt: fireAt
                    ))
                }
                // A reminder that came due before Second Wind saw the reset fires once, and only
                // the most urgent one.
                if let urgent = due.last, ledger.sent[stageID(urgent)] == nil {
                    plan.deliveries.append(AlertDelivery(
                        id: stageID(urgent),
                        account: account,
                        name: name,
                        notice: .savedResetExpiring(urgent, expiresAt: expiresAt)
                    ))
                }
                for stage in due where ledger.sent[stageID(stage)] == nil {
                    ledger.sent[stageID(stage)] = AlertLedger.Sent(until: expiresAt)
                }
            }
        }

        if isComplete || !ledger.savedResetExpiry {
            plan += cancelPending(ledger: &ledger, now: now) { id in
                id.hasPrefix(prefix) && !wanted.contains(id)
            }
        }
        return plan
    }

    /// Codex states whether ordinary use is allowed. Restored percentages or a passed reset time
    /// never prove it, so a Codex refill waits for an explicit allowed. Claude reports no such
    /// permission; its fresh windows are the provider's word.
    private static func allowsUse(_ reading: QuotaObservation, provider: QuotaProvider) -> Bool {
        switch provider {
        case .claude:
            return true
        case .codex:
            if case .allowed = reading.includedUsageAccess { return true }
            return false
        }
    }

    private static func attention(
        _ reason: AttentionReason,
        account: AccountRef,
        name: String,
        ledger: inout AlertLedger
    ) -> AlertPlan {
        let id = "\(account.token)|attention|\(reason.rawValue)"
        guard ledger.sent[id] == nil else { return AlertPlan() }
        ledger.sent[id] = AlertLedger.Sent(until: .distantFuture)
        return AlertPlan(deliveries: [
            AlertDelivery(id: id, account: account, name: name, notice: .needsAttention(reason)),
        ])
    }

    /// Withdraws reminders still waiting in the system scheduler. One that already fired stays
    /// recorded so it is not repeated.
    private static func cancelPending(
        ledger: inout AlertLedger,
        now: Date,
        matching: (String) -> Bool
    ) -> AlertPlan {
        let ids = ledger.sent
            .filter { id, sent in matching(id) && (sent.fireAt.map { $0 > now } ?? false) }
            .keys
            .sorted()
        for id in ids { ledger.sent[id] = nil }
        return AlertPlan(cancellations: ids)
    }

    private static func prune(_ ledger: inout AlertLedger, now: Date) {
        ledger.sent = ledger.sent.filter { $0.value.until > now }
    }

    private static func isRecent(_ date: Date, now: Date, policy: QuotaReadPolicy) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= 0 && age < policy.staleAfter
    }

    /// True only when both times are known and `date` falls in a later cycle than `other`.
    private static func isLater(_ date: Date?, than other: Date?) -> Bool {
        guard let date, let other else { return false }
        return date.timeIntervalSince(other) > 60
    }

    private static func cycle(resetsAt: Date?, observedAt: Date?) -> String {
        if let resetsAt { return "r\(minute(resetsAt))" }
        return observedAt.map { "seen\(minute($0))" } ?? "unknown"
    }

    private static func minute(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 60).rounded(.down))
    }
}

extension AccountRef {
    init(_ record: QuotaAccountRecord) {
        let provider: ProviderKind = switch record.provider {
        case .codex: .codex
        case .claude: .claude
        }
        self.init(provider: provider, id: record.accountID)
    }
}
