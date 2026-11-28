import AppKit
import Combine
import Foundation
import SecondWindCore

enum GuardProfileStatus: String, Codable, CaseIterable, Sendable {
    case healthy
    case nearLimit
    case confirming
    case redeeming
    case verified
    case disconnected
    case attention

    var title: String {
        switch self {
        case .healthy: "Healthy"
        case .nearLimit: "Running low"
        case .confirming: "Confirming weekly limit"
        case .redeeming: "Redeeming reset"
        case .verified: "Reset verified"
        case .disconnected: "Disconnected"
        case .attention: "Attention required"
        }
    }

    var symbolName: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .nearLimit: "exclamationmark.triangle.fill"
        case .confirming: "clock.fill"
        case .redeeming: "arrow.triangle.2.circlepath"
        case .verified: "checkmark.shield.fill"
        case .disconnected: "person.crop.circle.badge.questionmark"
        case .attention: "xmark.octagon.fill"
        }
    }
}

struct GuardProfilePresentation: Identifiable, Equatable, Sendable {
    let id: String
    var displayName: String
    var accountHint: String
    var weeklyRemainingPercent: Double?
    var naturalResetAt: Date?
    var availableResetCount: Int
    var nearestResetExpiry: Date?
    var status: GuardProfileStatus
    var detail: String
    var autoResetEnabled: Bool
    var identityVerified: Bool = true
    /// Quota evidence with per-account timestamps. Nil only in previews that predate it.
    var quota: QuotaAccountRecord? = nil
    var removalKeepsResetRecord = false
    var signIn: SignInState = .connected
    /// The ChatGPT plan, such as "Plus", once a sign-in has reported it.
    var planName: String? = nil
    /// The enrolled email, for sync and the double Auto-redeem guard. Shown in full only on the
    /// add-account result, right after the user signed in with it; rows show the masked hint.
    var email: String? = nil

    var isConnected: Bool { identityVerified && status != .disconnected }
}

enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}

enum ClaudeProfileStatus: String, Equatable, Sendable {
    case checking
    case healthy
    case low
    case signedOut
    case signingIn
    case attention

    var title: String {
        switch self {
        case .checking: "Checking"
        case .healthy: "Monitoring"
        case .low: "Running low"
        case .signedOut: "Not signed in"
        case .signingIn: "Signing in"
        case .attention: "Attention required"
        }
    }

    var symbolName: String {
        switch self {
        case .checking: "clock"
        case .healthy: "checkmark.circle.fill"
        case .low: "exclamationmark.triangle.fill"
        case .signedOut: "person.crop.circle.badge.questionmark"
        case .signingIn: "arrow.up.forward.app"
        case .attention: "xmark.octagon.fill"
        }
    }
}

struct ClaudeWindowPresentation: Identifiable, Equatable, Sendable {
    let id: String
    var label: String
    var remainingPercent: Double
    var resetsAt: Date?
    /// False when the figure is historical: stale, kept after a failed refresh, or past its reset.
    var isCurrent: Bool = true
}

struct ClaudeProfilePresentation: Identifiable, Equatable, Sendable {
    /// Claude windows at or below this much room left count as low.
    static let lowThresholdPercent: Double = 10

    let id: String
    var displayName: String
    var accountHint: String
    var planName: String?
    var windows: [ClaudeWindowPresentation]
    var status: ClaudeProfileStatus
    var detail: String
    var signInURL: URL?
    /// Quota evidence with per-account timestamps. Nil only in previews that predate it.
    var quota: QuotaAccountRecord? = nil
    var signIn: SignInState = .connected
    /// The enrolled email, for sync. Shown in full only on the add-account result, right after
    /// the user signed in with it; rows show the masked hint.
    var email: String? = nil

    var tightestWindow: ClaudeWindowPresentation? {
        windows.min { $0.remainingPercent < $1.remainingPercent }
    }

    var needsConnection: Bool { status == .signedOut || status == .signingIn }
}

struct GuardHistoryEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let occurredAt: Date
    let profileName: String
    let summary: String
    var isProblem = false
}

@MainActor
final class GuardAppModel: ObservableObject {
    @Published var profiles: [GuardProfilePresentation] {
        didSet { refreshSignIns() }
    }
    @Published var claudeProfiles: [ClaudeProfilePresentation] {
        didSet { refreshSignIns() }
    }
    @Published var isCheckingClaude = false
    /// The add-account flow, kept here so it survives the popover closing for the browser.
    @Published var enrollment: EnrollmentFlow?
    @Published var history: [GuardHistoryEvent]
    @Published var isChecking = false
    @Published var lastCheckedAt: Date?
    @Published var banner: String?
    @Published var isPreview: Bool
    let isReadOnly: Bool
    @Published var isReady = false
    @Published var isAddingProfile = false
    /// Accounts whose row started a sign-in, with whether it has been seen under way.
    var pendingReconnects: [AccountRef: Bool] = [:]
    /// Other Macs' latest snapshots while sync is on, in display order.
    @Published var remoteDevices: [DeviceSnapshot] = []
    /// Auto-redeem changes this Mac sent to another Mac, keyed by `remoteKey`.
    @Published var pendingRemoteCommands: [String: PendingRemoteCommand] = [:]
    /// Synthetic previews use one reference clock for every relative date label.
    let referenceDate: Date?

    var onCheckNow: (() -> Void)?
    var onToggleAutoReset: ((String, Bool) -> Void)?
    var onReconnect: ((String) -> Void)?
    /// Saves a new account with no identity yet and opens its sign-in.
    var onAddProfile: (() -> Void)?
    var onAddClaudeProfile: (() -> Void)?
    var onConnectClaude: ((String) -> Void)?
    var onCancelClaudeSignIn: ((String) -> Void)?
    /// Removes an account the add-account flow created but never finished connecting.
    var onDiscardUnfinishedAccount: ((AccountRef) async throws -> Void)?
    /// A sign-in finished one way or the other. True when it belongs to the add-account flow.
    var onSignInSettled: ((AccountRef, Bool) -> Void)?
    /// Writes a sign-in link to the clipboard. Tests replace it.
    var copySignInLink: (URL) -> Void = { url in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
    var onAccountActionFailure: ((AccountRef, String) -> Void)?
    /// Called after each provider's snapshot is applied with that provider's full roster in
    /// display order, including never-read accounts as empty records.
    var onQuotaRecordsChanged: ((QuotaProvider, [QuotaAccountRecord]) -> Void)?
    /// Awaitable form of `onToggleAutoReset`: the same runtime path, returning whether it held.
    var applyAutoReset: ((String, Bool) async -> Bool)?
    /// Sends a change to another Mac; failures report to the given card.
    var onSetRemoteAutoReset: ((SyncDeviceID, SharedAccount, Bool, AccountRef) -> Void)?
    var onSyncNow: (() -> Void)?

    init(
        profiles: [GuardProfilePresentation] = [],
        claudeProfiles: [ClaudeProfilePresentation] = [],
        history: [GuardHistoryEvent] = [],
        isPreview: Bool = false,
        isReadOnly: Bool = false,
        referenceDate: Date? = nil
    ) {
        self.profiles = profiles
        self.claudeProfiles = claudeProfiles
        self.history = history
        self.isPreview = isPreview
        self.isReadOnly = isReadOnly
        self.isReady = isPreview
        self.referenceDate = referenceDate
    }

    var hasAccounts: Bool { !profiles.isEmpty || !claudeProfiles.isEmpty }

    var hasRemoteAccounts: Bool { remoteDevices.contains { !$0.accounts.isEmpty } }

    func reportActionFailure(_ message: String, for account: AccountRef) {
        if let onAccountActionFailure {
            onAccountActionFailure(account, message)
        } else {
            banner = message
        }
    }

    var isBusyChecking: Bool { isChecking || isCheckingClaude }

    /// Every account's reading at `now`, Codex first, in display order.
    func quotaReadings(at now: Date) -> [QuotaAccountReading] {
        (profiles.compactMap(\.quota) + claudeProfiles.compactMap(\.quota)).map { $0.reading(at: now) }
    }

    /// All clear only when every account has a current reading and none is low.
    func quotaSummary(at now: Date) -> QuotaSummary {
        QuotaSummary(readings: quotaReadings(at: now))
    }

    /// The least current headroom across every account and window, including the Codex 5-hour
    /// window, shown in the menu bar. Historical figures are left out.
    var minimumRemainingPercent: Double? {
        let now = referenceDate ?? Date()
        func current(_ record: QuotaAccountRecord) -> [Double] {
            record.reading(at: now).windows.filter(\.isCurrent).map(\.window.remainingPercent)
        }
        // Presentations without evidence (older previews) keep their legacy figures.
        let codex = profiles.flatMap { profile in
            profile.quota.map(current) ?? profile.weeklyRemainingPercent.map { [$0] } ?? []
        }
        let claude = claudeProfiles.flatMap { profile in
            profile.quota.map(current) ?? profile.tightestWindow.map { [$0.remainingPercent] } ?? []
        }
        return (codex + claude).min()
    }

    var attentionCount: Int {
        profiles.filter { $0.status == .attention || $0.status == .disconnected }.count
            + claudeProfiles.filter { $0.status == .attention || $0.status == .signedOut }.count
    }

    var hasAttention: Bool { attentionCount > 0 }

    func checkNow() {
        guard !isBusyChecking else { return }
        if isPreview {
            lastCheckedAt = Date()
            banner = "Preview refreshed"
        } else {
            onCheckNow?()
            onSyncNow?()
        }
    }

    func setAutoReset(profileID: String, enabled: Bool) {
        guard !isReadOnly else { return }
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        guard !enabled || profiles[index].isConnected else { return }
        if let refusal = autoResetRefusal(email: profiles[index].email, enabled: enabled) {
            if let account = AccountRef(provider: .codex, rawID: profileID) {
                reportActionFailure(refusal, for: account)
            }
            return
        }
        if isPreview {
            profiles[index].autoResetEnabled = enabled
            return
        }
        // Live mode is persistence-led: the switch changes only after the runtime publishes the
        // committed setting. A failed disable can therefore never look off while remaining on.
        onToggleAutoReset?(profileID, enabled)
    }

    /// A command from another Mac. It passes the same checks as the switch and runs the same
    /// runtime path; it can only change the setting, never request a reset.
    func applyRemoteAutoReset(profileID: UUID, enabled: Bool) async -> Bool {
        guard !isReadOnly, !isPreview else { return false }
        let rawID = profileID.uuidString.lowercased()
        guard let profile = profiles.first(where: { $0.id == rawID }),
              !enabled || profile.isConnected,
              autoResetRefusal(email: profile.email, enabled: enabled) == nil,
              let applyAutoReset
        else { return false }
        return await applyAutoReset(rawID, enabled)
    }

    /// Why Auto-redeem must stay off for this email, or nil. Another Mac whose current snapshot
    /// already redeems the same account would otherwise race this one.
    func autoResetRefusal(email: String?, enabled: Bool, excluding excluded: Set<SyncDeviceID> = []) -> String? {
        guard enabled, let email else { return nil }
        let now = referenceDate ?? Date()
        guard let other = AutoRedeemGuard.conflictingDevice(
            email: email,
            among: remoteDevices,
            excluding: excluded,
            now: now
        ) else { return nil }
        return "Auto-redeem is already on for this account on \(other.deviceName). Turn it off there first."
    }

    // MARK: Other Macs

    nonisolated static func remoteKey(device: SyncDeviceID, account: SharedAccount) -> String {
        "\(device)|\(account.id)"
    }

    /// An account as another Mac shares it.
    struct RemoteCopy {
        let device: DeviceSnapshot
        let account: SharedAccount

        var key: String { GuardAppModel.remoteKey(device: device.deviceID, account: account) }
    }

    /// Accounts are the same account across Macs only when provider and email match. An account
    /// with no email never merges, since its name alone can collide.
    private static func accountKey(_ provider: QuotaProvider, email: String?) -> String? {
        let email = DeviceSyncPolicy.normalizedEmail(email ?? "")
        return email.isEmpty ? nil : "\(provider.rawValue)|\(email)"
    }

    /// One account as every other Mac shares it. Whose reading to show and whose Auto-redeem
    /// switch to drive are separate choices: the Mac that redeems is not always the one that read
    /// last.
    struct SyncedAccount {
        /// `accountKey`, or one Mac's own key for an account with no email.
        let key: String
        let copies: [RemoteCopy]
        /// The copy with the newest current reading, if any copy has one.
        let currentReading: RemoteCopy?
        /// The copy that redeems the account or waits on a change to it.
        let redeemer: RemoteCopy?
        /// The first Mac that can take a change now, preferring a healthy copy.
        let reachable: RemoteCopy?
        /// The copy a remote-only card names and drives: a live redeemer or one with a change in
        /// flight, else the first Mac that can take a change now, else a quiet redeemer, else the
        /// first Mac. A fixed order, so the card does not move between
        /// Macs as each reads.
        let host: RemoteCopy

        /// The figures a card shows: the newest current reading, else the host's last one.
        var reading: RemoteCopy { currentReading ?? host }
    }

    /// Other Macs' accounts, one entry per account, in the order the Macs list them.
    func syncedAccounts(among devices: [DeviceSnapshot]? = nil, now: Date) -> [SyncedAccount] {
        var order: [String] = []
        var groups: [String: [RemoteCopy]] = [:]
        for device in devices ?? remoteDevices {
            for account in device.accounts {
                let key = Self.accountKey(account.provider, email: account.email)
                    ?? Self.remoteKey(device: device.deviceID, account: account)
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(RemoteCopy(device: device, account: account))
            }
        }
        return order.compactMap { key in groups[key].map { synced(key: key, copies: $0, now: now) } }
    }

    private func synced(key: String, copies: [RemoteCopy], now: Date) -> SyncedAccount {
        let byDevice = copies.sorted { $0.device.deviceID.description < $1.device.deviceID.description }
        let observed = { (copy: RemoteCopy) -> Date? in
            let record = copy.account.quotaRecord()
            let current = record.reading(at: now, policy: .remote).windows.contains(where: \.isCurrent)
            return current ? record.lastSuccess?.observedAt : nil
        }
        let current = byDevice
            .compactMap { copy in observed(copy).map { (copy, $0) } }
            .max { $0.1 < $1.1 }?.0
        let redeemRank = { (copy: RemoteCopy) -> Int in
            if case .pending = self.remoteState(of: copy.account, in: copy.device, now: now) { return 3 }
            guard copy.account.autoRedeemEnabled == true else { return 0 }
            return copy.device.freshness(at: now).isLive ? 2 : 1
        }
        let redeemer = byDevice.filter { redeemRank($0) > 0 }.max { redeemRank($0) < redeemRank($1) }
        // Prefer a reachable Mac whose copy is healthy, since a signed-out copy cannot redeem.
        let canTake = byDevice.filter { $0.device.freshness(at: now).isLive && $0.device.acceptsCommands }
        let reachable = canTake.first { $0.account.attentionMessage == nil } ?? canTake.first
        // A quiet redeemer yields to a Mac that can take a change, as `AutoRedeemGuard` ignores it.
        let activeRedeemer = redeemer.flatMap { redeemRank($0) >= 2 ? $0 : nil }
        return SyncedAccount(
            key: key, copies: copies, currentReading: current, redeemer: redeemer, reachable: reachable,
            host: activeRedeemer ?? reachable ?? redeemer ?? byDevice[0]
        )
    }

    /// Other Macs' copies of an account this Mac also has.
    func synced(provider: QuotaProvider, email: String?, now: Date) -> SyncedAccount? {
        guard let key = Self.accountKey(provider, email: email) else { return nil }
        return syncedAccounts(now: now).first { $0.key == key }
    }

    /// Accounts only other Macs have. An account this Mac also has always stays one card here,
    /// whether or not its own reading is current.
    func remoteOnlyAccounts(now: Date) -> [SyncedAccount] {
        let local = Set(
            profiles.compactMap { Self.accountKey(.codex, email: $0.email) }
                + claudeProfiles.compactMap { Self.accountKey(.claude, email: $0.email) }
        )
        return syncedAccounts(now: now).filter { !local.contains($0.key) }
    }

    /// Another Mac's current reading, for a card whose own reading is not current.
    func borrowedReading(provider: QuotaProvider, email: String?, record: QuotaAccountRecord?, now: Date) -> SharedAccount? {
        guard !Self.isCurrent(record, now: now) else { return nil }
        return synced(provider: provider, email: email, now: now)?.currentReading?.account
    }

    /// True when this Mac alerts for this window itself: Claude monitoring does for every window
    /// it reads currently, so another Mac's reading adds nothing unless it is newer. Codex
    /// monitoring has no low alert of its own.
    func alertsLocally(_ account: SharedAccount, window kind: QuotaWindowKind, now: Date) -> Bool {
        guard account.provider == .claude, let key = Self.accountKey(.claude, email: account.email) else { return false }
        let remoteObservedAt = account.quotaRecord().lastSuccess?.observedAt ?? .distantPast
        return claudeProfiles.contains { profile in
            guard Self.accountKey(.claude, email: profile.email) == key,
                  let record = profile.quota,
                  let localObservedAt = record.lastSuccess?.observedAt,
                  localObservedAt >= remoteObservedAt
            else { return false }
            return record.reading(at: now).windows.contains { $0.isCurrent && $0.window.kind == kind }
        }
    }

    private static func isCurrent(_ record: QuotaAccountRecord?, now: Date) -> Bool {
        record?.reading(at: now).windows.contains(where: \.isCurrent) ?? false
    }

    /// The other Mac that redeems this Codex account or waits on a change to it, whatever this
    /// Mac's own switch says. A Mac that went quiet still counts: it may redeem again when it wakes.
    func remoteRedeemer(of profile: GuardProfilePresentation, now: Date) -> RemoteCopy? {
        synced(provider: .codex, email: profile.email, now: now)?.redeemer
    }

    /// The other Mac a card's switch drives while this Mac's own Auto-redeem is off: one that
    /// redeems the account and can take a change now, or, while this Mac cannot redeem because it
    /// is signed out, the first Mac that can. A quiet Mac hands the switch back, matching
    /// `AutoRedeemGuard`, so this Mac can take over instead of waiting days for it to return.
    func drivenRemote(of profile: GuardProfilePresentation, now: Date) -> RemoteCopy? {
        guard !profile.autoResetEnabled,
              let synced = synced(provider: .codex, email: profile.email, now: now)
        else { return nil }
        if let copy = synced.redeemer {
            if case .pending = remoteState(of: copy.account, in: copy.device, now: now) { return copy }
            if copy.device.freshness(at: now).isLive, copy.device.acceptsCommands { return copy }
        }
        return profile.isConnected ? nil : synced.reachable
    }

    /// The switch on an account card. It changes the Mac `drivenRemote` names, through that Mac's
    /// guards, and otherwise this Mac. Failures show on this card.
    func setAccountAutoReset(profileID: String, enabled: Bool) {
        if let profile = profiles.first(where: { $0.id == profileID }),
           let copy = drivenRemote(of: profile, now: referenceDate ?? Date()) {
            setRemoteAutoReset(
                device: copy.device,
                account: copy.account,
                enabled: enabled,
                reportingTo: AccountRef(provider: .codex, rawID: profileID)
            )
        } else {
            setAutoReset(profileID: profileID, enabled: enabled)
        }
    }

    /// The low windows other Macs read for alerting, from every Mac read this pass. The alert key
    /// names the account and window, so the same window from two Macs notifies once, and a window
    /// only one Mac reads is never lost behind another Mac's newer partial reading.
    func remoteAlertSources(among devices: [DeviceSnapshot], now: Date) -> [RemoteCopy] {
        syncedAccounts(among: devices, now: now).flatMap(\.copies)
    }

    func remoteState(of account: SharedAccount, in device: DeviceSnapshot, now: Date) -> RemoteAccountState {
        RemoteAccountState.classify(
            account: account,
            in: device,
            pending: pendingRemoteCommands[Self.remoteKey(device: device.deviceID, account: account)],
            now: now
        )
    }

    /// Sends an absolute Auto-redeem setting to the Mac that hosts the account.
    func setRemoteAutoReset(device: DeviceSnapshot, account: SharedAccount, enabled: Bool, reportingTo card: AccountRef? = nil) {
        guard !isReadOnly, account.provider == .codex, device.acceptsCommands else { return }
        let key = Self.remoteKey(device: device.deviceID, account: account)
        let ref = card ?? AccountRef(provider: .codex, id: account.profileID)
        if case .pending = remoteState(of: account, in: device, now: referenceDate ?? Date()) { return }
        if enabled {
            let local = profiles.contains {
                $0.autoResetEnabled
                    && DeviceSyncPolicy.normalizedEmail($0.email ?? "") == account.email
            }
            let refusal = local
                ? "Auto-redeem is already on for this account on this Mac. Turn it off here first."
                : autoResetRefusal(email: account.email, enabled: true, excluding: [device.deviceID])
            if let refusal {
                reportActionFailure(refusal, for: ref)
                return
            }
        }
        if isPreview {
            pendingRemoteCommands[key] = PendingRemoteCommand(commandID: UUID(), enabled: enabled, issuedAt: referenceDate ?? Date())
            return
        }
        onSetRemoteAutoReset?(device.deviceID, account, enabled, ref)
    }

    /// What this Mac shares: every account, with its readings and the Auto-redeem setting.
    func sharedAccounts() -> [SharedAccount] {
        let codex = profiles.compactMap { profile -> SharedAccount? in
            guard let id = UUID(uuidString: profile.id) else { return nil }
            return SharedAccount(
                profileID: id,
                provider: .codex,
                displayName: profile.displayName,
                email: profile.email ?? "",
                autoRedeemEnabled: profile.autoResetEnabled,
                windows: Self.sharedWindows(profile.quota),
                savedResetCount: profile.quota?.lastKnownInventory?.availableCount,
                attentionMessage: profile.status == .attention || profile.status == .disconnected ? profile.detail : nil
            )
        }
        let claude = claudeProfiles.compactMap { profile -> SharedAccount? in
            guard let id = UUID(uuidString: profile.id) else { return nil }
            return SharedAccount(
                profileID: id,
                provider: .claude,
                displayName: profile.displayName,
                email: profile.email ?? "",
                autoRedeemEnabled: nil,
                windows: Self.sharedWindows(profile.quota),
                attentionMessage: profile.status == .attention || profile.status == .signedOut ? profile.detail : nil
            )
        }
        return codex + claude
    }

    private static func sharedWindows(_ record: QuotaAccountRecord?) -> [SharedWindow] {
        guard let success = record?.lastSuccess else { return [] }
        return success.windows.map {
            SharedWindow(kind: $0.kind, remainingPercent: $0.remainingPercent, resetsAt: $0.resetsAt, observedAt: success.observedAt)
        }
    }

    func reconnect(profileID: String) {
        if isPreview {
            banner = "Preview only. No sign-in was started."
            return
        }
        if let ref = AccountRef(provider: .codex, rawID: profileID) { pendingReconnects[ref] = false }
        onReconnect?(profileID)
    }

    func connectClaude(profileID: String) {
        guard !isReadOnly else { return }
        if isPreview {
            banner = "Preview only. No sign-in was started."
            return
        }
        if let ref = AccountRef(provider: .claude, rawID: profileID) { pendingReconnects[ref] = false }
        onConnectClaude?(profileID)
    }

    func cancelClaudeSignIn(profileID: String) {
        onCancelClaudeSignIn?(profileID)
    }

    func openClaudeUsage() {
        guard !isPreview else {
            banner = "Preview only. Claude usage settings open from the installed app."
            return
        }
        NSWorkspace.shared.open(claudeUsageSettingsURL)
    }
}
