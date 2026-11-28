import Foundation
import SecondWindCore

// The one place where the quota read model becomes what the popover draws. Views never read
// `QuotaAccountReading` directly, so a change to the quota contract lands here only.

struct WindowDisplay: Identifiable, Equatable {
    enum State: Equatable {
        /// From a fresh reading whose reset time is still ahead.
        case current
        /// The account's last reading is old or its latest refresh failed.
        case stale
        /// The provider did not report this window. Never shown as zero.
        case unreported
        /// The reset time passed after the reading; the refill is not confirmed yet.
        case awaitingRefill
    }

    let id: String
    let label: String
    let remaining: Double?
    let resetsAt: Date?
    let state: State
    let level: QuotaLevel
    /// Remaining percent at which the meter's tick sits.
    let alertLine: Double

    var isWarning: Bool { state == .current && level >= .low }
}

enum InventoryDisplay: Equatable {
    enum Expiry: Equatable {
        case on(Date)
        /// Codex listed the reset with a null expiry, which its schema defines as never expiring.
        case doesNotExpire
    }

    /// The latest query had no authoritative answer. Never shown as zero.
    case unknown(lastCount: Int?, checkedAt: Date?)
    /// `listed` holds the still-future expiries Codex supplied, soonest first. Codex may list
    /// fewer resets than `count`, or report a count with no dates at all (`datesReported`).
    case known(count: Int, listed: [Expiry], datesReported: Bool, checkedAt: Date, isCurrent: Bool)

    /// Resets in the count that came without a listed expiry.
    var unlistedCount: Int {
        guard case let .known(count, listed, datesReported, _, _) = self, datesReported else { return 0 }
        return max(0, count - listed.count)
    }

    /// The compact line already says everything for a single reset; several get a list.
    var hasDetail: Bool {
        guard case let .known(count, listed, datesReported, _, _) = self, datesReported, count > 1 else { return false }
        return listed.count + (unlistedCount > 0 ? 1 : 0) >= 2
    }
}

enum ReadingAge: Equatable {
    case never
    case current(Date)
    case stale(Date)
    case failed(lastSuccess: Date?)

    var lastSuccess: Date? {
        switch self {
        case .never: nil
        case let .current(date), let .stale(date): date
        case let .failed(date): date
        }
    }
}

struct AccountQuotaDisplay: Equatable {
    var windows: [WindowDisplay]
    var inventory: InventoryDisplay?
    var age: ReadingAge
    /// Windows, saved resets and usage access are all current (the quota model's `isConfirmed`).
    var isConfirmed: Bool
    /// What the provider said about ordinary usage in the last good reading.
    var usageAccess: IncludedUsageAccess = .unreported
    /// The last good reading came from disk and nothing has refreshed it since launch.
    var isRestored = false

    /// The provider explicitly blocked ordinary usage, whatever the percentages say.
    var isBlocked: Bool { usageAccess == .blocked && age.lastSuccess != nil }

    /// The window the big figure shows: the one with the least room whose value still stands.
    var headline: WindowDisplay? {
        let standing = windows.filter { $0.remaining != nil && $0.state != .awaitingRefill }
        return standing.min { lhs, rhs in
            (lhs.remaining ?? 101) < (rhs.remaining ?? 101)
        } ?? windows.first { $0.remaining != nil }
    }

    var warningWindow: WindowDisplay? {
        windows.filter(\.isWarning).min { ($0.remaining ?? 101) < ($1.remaining ?? 101) }
    }

    var awaitingRefill: Bool { windows.contains { $0.state == .awaitingRefill } }

    /// The quota figures are current but the saved-reset count is not.
    var inventoryUnconfirmed: Bool {
        switch inventory {
        case .unknown?: true
        case let .known(_, _, _, _, isCurrent)?: !isCurrent
        case nil: false
        }
    }
}

// MARK: - Building displays

enum QuotaDisplayBuilder {
    static let codexAutoRedeemLine: Double = 3

    static func codex(_ profile: GuardProfilePresentation, now: Date) -> AccountQuotaDisplay {
        let lowLine = QuotaReadPolicy.codex.lowRemainingPercent
        if let record = profile.quota {
            return display(
                reading: record.reading(at: now),
                now: now,
                alertLine: { kind in
                    kind == .weekly && profile.autoResetEnabled ? codexAutoRedeemLine : lowLine
                }
            )
        }
        // Presentations from before the read model carry only the weekly window.
        var windows: [WindowDisplay] = []
        if let remaining = profile.weeklyRemainingPercent {
            windows.append(WindowDisplay(
                id: QuotaWindowKind.weekly.key,
                label: label(for: .weekly),
                remaining: remaining,
                resetsAt: profile.naturalResetAt,
                state: profile.isConnected ? .current : .stale,
                level: level(remaining: remaining, low: lowLine),
                alertLine: profile.autoResetEnabled ? codexAutoRedeemLine : lowLine
            ))
        }
        let inventory: InventoryDisplay? = profile.isConnected
            ? .known(
                count: profile.availableResetCount,
                listed: profile.nearestResetExpiry.map { [.on($0)] } ?? [],
                datesReported: profile.nearestResetExpiry != nil || profile.availableResetCount == 0,
                checkedAt: now,
                isCurrent: true
            )
            : nil
        return AccountQuotaDisplay(windows: windows, inventory: inventory, age: .never, isConfirmed: false)
    }

    static func claude(_ profile: ClaudeProfilePresentation, now: Date) -> AccountQuotaDisplay {
        let lowLine = QuotaReadPolicy.claude.lowRemainingPercent
        if let record = profile.quota {
            return display(reading: record.reading(at: now), now: now, alertLine: { _ in lowLine })
        }
        let windows = profile.windows.map { window in
            WindowDisplay(
                id: window.id,
                label: window.label,
                remaining: window.remainingPercent,
                resetsAt: window.resetsAt,
                state: window.resetsAt.map { $0 <= now } == true ? .awaitingRefill : .current,
                level: level(remaining: window.remainingPercent, low: lowLine),
                alertLine: lowLine
            )
        }
        return AccountQuotaDisplay(windows: windows, inventory: nil, age: .never, isConfirmed: false)
    }

    /// This Mac's card, showing another Mac's current reading while its own is not current.
    @MainActor
    static func codex(_ profile: GuardProfilePresentation, model: GuardAppModel, now: Date) -> AccountQuotaDisplay {
        model.borrowedReading(provider: .codex, email: profile.email, record: profile.quota, now: now)
            .map { remote($0, now: now) } ?? codex(profile, now: now)
    }

    @MainActor
    static func claude(_ profile: ClaudeProfilePresentation, model: GuardAppModel, now: Date) -> AccountQuotaDisplay {
        model.borrowedReading(provider: .claude, email: profile.email, record: profile.quota, now: now)
            .map { remote($0, now: now) } ?? claude(profile, now: now)
    }

    /// An account another Mac hosts, read with the remote stale line.
    static func remote(_ account: SharedAccount, now: Date) -> AccountQuotaDisplay {
        let lowLine = QuotaReadPolicy.remote.lowRemainingPercent
        return display(
            reading: account.quotaRecord().reading(at: now, policy: .remote),
            now: now,
            alertLine: { kind in
                kind == .weekly && account.autoRedeemEnabled == true ? codexAutoRedeemLine : lowLine
            }
        )
    }

    static func display(
        reading: QuotaAccountReading,
        now: Date,
        alertLine: (QuotaWindowKind) -> Double
    ) -> AccountQuotaDisplay {
        let accountState: WindowDisplay.State = reading.freshness.isFresh ? .current : .stale
        var windows = reading.windows.map { window in
            WindowDisplay(
                id: window.id,
                label: label(for: window.window.kind),
                remaining: window.window.remainingPercent,
                resetsAt: window.window.resetsAt,
                state: window.resetPassed ? .awaitingRefill : (window.isCurrent ? .current : accountState),
                level: window.level,
                alertLine: alertLine(window.window.kind)
            )
        }
        windows += reading.unknownWindows
            .filter { kind in !windows.contains { $0.id == kind.key } }
            .map { kind in
                WindowDisplay(
                    id: kind.key,
                    label: label(for: kind),
                    remaining: nil,
                    resetsAt: nil,
                    state: .unreported,
                    level: .ok,
                    alertLine: alertLine(kind)
                )
            }
        windows.sort { order($0.id) < order($1.id) }

        let age: ReadingAge = switch reading.freshness {
        case .missing: .never
        case let .fresh(date): .current(date)
        case let .stale(date): .stale(date)
        case let .failed(_, _, date): .failed(lastSuccess: date)
        }

        let inventory: InventoryDisplay? = switch reading.inventory {
        case .notTracked:
            nil
        case let .unknown(lastKnown):
            .unknown(lastCount: lastKnown?.availableCount, checkedAt: lastKnown?.fetchedAt)
        case let .known(snapshot, isCurrent):
            known(snapshot, isCurrent: isCurrent, now: now)
        }
        return AccountQuotaDisplay(
            windows: windows,
            inventory: inventory,
            age: age,
            isConfirmed: reading.isConfirmed,
            usageAccess: reading.includedUsageAccess,
            isRestored: reading.isRestoredUnverified
        )
    }

    static func label(for kind: QuotaWindowKind) -> String {
        switch kind {
        case .session: "5-hour"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case let .modelWeekly(name): name.replacingOccurrences(of: " only", with: "")
        }
    }

    private static func known(_ snapshot: ResetInventorySnapshot, isCurrent: Bool, now: Date) -> InventoryDisplay {
        switch snapshot.expiries {
        case .unlisted:
            return .known(count: snapshot.availableCount, listed: [], datesReported: false, checkedAt: snapshot.fetchedAt, isCurrent: isCurrent)
        case let .listed(entries):
            // A row without its expiry counts with the resets Codex did not list.
            let listed: [InventoryDisplay.Expiry] = entries.compactMap { entry in
                switch entry {
                case let .on(date): date > now ? .on(date) : nil
                case .never: .doesNotExpire
                case .unspecified: nil
                }
            }
            return .known(count: snapshot.availableCount, listed: listed, datesReported: true, checkedAt: snapshot.fetchedAt, isCurrent: isCurrent)
        }
    }

    private static func order(_ id: String) -> Int {
        if id == QuotaWindowKind.session.key { return 0 }
        if id == QuotaWindowKind.weekly.key { return 1 }
        if id == QuotaWindowKind.monthly.key { return 2 }
        return 3
    }

    private static func level(remaining: Double, low: Double) -> QuotaLevel {
        remaining <= 0 ? .exhausted : remaining <= low ? .low : .ok
    }
}

// MARK: - Popover-wide summary

/// The header line and menu bar figure. "All clear" is claimed only when every provider loaded,
/// every account has a confirmed reading and no current window is low.
struct PopoverSummary: Equatable {
    var text: String
    var tone: SWTone
    var symbol: String?
    /// The menu bar figure in the user's convention, from current windows only.
    var menuBarPercent: Int?
    /// "24% left" or "76% used": the menu bar always names the convention it counts.
    var menuBarTitle: String?
    /// What VoiceOver reads for the menu bar item.
    var accessibilityValue: String
    /// False when any reading is missing, old or unconfirmed: the menu bar dims its figure.
    var isConfident: Bool
    var showsAttentionIcon: Bool
    var tooltip: String

    @MainActor
    static func make(
        model: GuardAppModel,
        interface: GuardInterfaceModel,
        now: Date
    ) -> PopoverSummary {
        let convention = interface.preferences.quota
        let codex = model.profiles.map { (name: $0.displayName, display: QuotaDisplayBuilder.codex($0, model: model, now: now)) }
        let claude = model.claudeProfiles.map { (name: $0.displayName, display: QuotaDisplayBuilder.claude($0, model: model, now: now)) }
        // Each account counts once, through the same card the popover shows.
        let remote = model.remoteOnlyAccounts(now: now).map {
            (name: $0.host.account.displayName, display: QuotaDisplayBuilder.remote($0.reading.account, now: now))
        }
        let accounts = codex + claude + remote
        let currentWindows = accounts.flatMap { account in
            account.display.windows.filter { $0.state == .current }.compactMap(\.remaining)
        }
        let lowest = currentWindows.min()
        let figure = lowest.map { convention.percent(remaining: $0) }
        let unconfirmed = accounts.filter { !$0.display.isConfirmed }.count
        let signingIn = model.claudeProfiles.filter { $0.status == .signingIn }.count
        let failed = interface.failedProviders
        let loading = ProviderKind.allCases.filter { interface.providerStates[$0] == .loading }
        let attention = model.attentionCount
        let warning = accounts
            .compactMap { account in account.display.warningWindow.map { (account.name, $0) } }
            .min { ($0.1.remaining ?? 101) < ($1.1.remaining ?? 101) }
        let blocked = codex.first { $0.display.isBlocked }?.name

        let figureText = figure.map { "\($0)% \(convention.word)" }
        let extreme = convention == .remaining ? "lowest" : "highest"

        var summary = PopoverSummary(
            text: "",
            tone: .neutral,
            symbol: nil,
            menuBarPercent: figure,
            menuBarTitle: figureText,
            accessibilityValue: "",
            isConfident: false,
            showsAttentionIcon: attention > 0 || !failed.isEmpty,
            tooltip: ""
        )

        if accounts.isEmpty {
            summary.text = loading.isEmpty ? "No accounts yet" : "Loading accounts…"
            if let provider = failed.first?.0 {
                summary.text = "\(provider.title) did not load"
                summary.tone = .critical
            }
            summary.tooltip = "Second Wind: \(summary.text.lowercased())"
            summary.accessibilityValue = summary.text
            return summary
        }

        if let provider = failed.first?.0 {
            summary.text = "\(provider.title) did not load"
            summary.tone = .critical
        } else if attention > 0 {
            summary.text = attention == 1 ? "1 account needs attention" : "\(attention) accounts need attention"
            summary.tone = .critical
        } else if let blocked {
            summary.text = "\(blocked) usage blocked"
            summary.tone = .caution
        } else if let warning, let remaining = warning.1.remaining {
            let (name, window) = warning
            summary.text = window.level == .exhausted
                ? "\(name) \(window.label.lowercased()) limit used up"
                : "\(name) \(window.label.lowercased()) limit: \(convention.text(remaining: remaining))"
            summary.tone = .caution
        } else if let provider = loading.first {
            summary.text = "Loading \(provider.title) accounts…"
        } else if unconfirmed > 0, unconfirmed == signingIn {
            summary.text = "Finishing sign-in"
        } else if unconfirmed > 0 {
            summary.text = unconfirmed == 1 ? "1 account not confirmed" : "\(unconfirmed) accounts not confirmed"
        } else {
            summary.text = figureText.map { "All clear · \(extreme) \($0)" } ?? "All clear"
            summary.symbol = "checkmark.circle.fill"
        }
        summary.isConfident = failed.isEmpty && loading.isEmpty && unconfirmed == 0

        var tooltip = "Second Wind: "
        if let figureText {
            tooltip += "\(extreme) \(figureText)"
        } else {
            tooltip += "no current reading"
        }
        if summary.tone != .neutral || !summary.isConfident {
            tooltip += ". \(summary.text)"
        }
        summary.tooltip = tooltip
        summary.accessibilityValue = [figureText.map { "\(extreme) \($0)" }, summary.text]
            .compactMap { $0 }
            .joined(separator: ". ")
        return summary
    }
}
