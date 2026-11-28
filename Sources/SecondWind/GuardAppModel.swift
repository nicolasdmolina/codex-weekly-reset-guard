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
    var onSetRemoteAutoReset: ((SyncDeviceID, SharedAccount, Bool) -> Void)?
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

    private var localAccountKeys: Set<String> {
        Set(
            profiles.compactMap { Self.accountKey(.codex, email: $0.email) }
                + claudeProfiles.compactMap { Self.accountKey(.claude, email: $0.email) }
        )
    }

    /// Accounts from other Macs that this Mac does not also have, one card per account. When
    /// several Macs share the same account, the copy that redeems it or the freshest one is shown.
    func remoteOnlyAccounts(now: Date) -> [RemoteCopy] {
        let local = localAccountKeys
        var order: [String] = []
        var chosen: [String: RemoteCopy] = [:]
        for device in remoteDevices {
            for account in device.accounts {
                let key = Self.accountKey(account.provider, email: account.email)
                    ?? Self.remoteKey(device: device.deviceID, account: account)
                guard !local.contains(key) else { continue }
                let copy = RemoteCopy(device: device, account: account)
                guard let existing = chosen[key] else {
                    order.append(key)
                    chosen[key] = copy
                    continue
                }
                if Self.ranks(copy, above: existing, now: now) { chosen[key] = copy }
            }
        }
        return order.compactMap { chosen[$0] }
    }

    private static func ranks(_ copy: RemoteCopy, above other: RemoteCopy, now: Date) -> Bool {
        let redeems = { (c: RemoteCopy) in c.account.autoRedeemEnabled == true && c.device.freshness(at: now).isLive }
        if redeems(copy) != redeems(other) { return redeems(copy) }
        return copy.device.publishedAt > other.device.publishedAt
    }

    /// The other Mac that redeems this Codex account, or has a change to it in flight. Its switch
    /// stands in for this Mac's while this Mac's own is off.
    func remoteRedeemer(of profile: GuardProfilePresentation, now: Date) -> RemoteCopy? {
        guard !profile.autoResetEnabled, let key = Self.accountKey(.codex, email: profile.email) else { return nil }
        for device in remoteDevices {
            for account in device.accounts where Self.accountKey(account.provider, email: account.email) == key {
                let pending = pendingRemoteCommands[Self.remoteKey(device: device.deviceID, account: account)] != nil
                if pending || (account.autoRedeemEnabled == true && device.freshness(at: now).isLive) {
                    return RemoteCopy(device: device, account: account)
                }
            }
        }
        return nil
    }

    /// The switch on an account card: it changes whichever Mac redeems the account, so turning it
    /// off where another Mac runs it asks that Mac, and turning it on always runs it here.
    func setAccountAutoReset(profileID: String, enabled: Bool) {
        if let profile = profiles.first(where: { $0.id == profileID }),
           let copy = remoteRedeemer(of: profile, now: referenceDate ?? Date()) {
            setRemoteAutoReset(device: copy.device, account: copy.account, enabled: enabled)
        } else {
            setAutoReset(profileID: profileID, enabled: enabled)
        }
    }

    /// True when this Mac reads the same account itself, so another Mac's alert would repeat its own.
    func readsLocally(_ account: SharedAccount, now: Date) -> Bool {
        guard let key = Self.accountKey(account.provider, email: account.email) else { return false }
        let records: [QuotaAccountRecord?] = switch account.provider {
        case .codex: profiles.filter { Self.accountKey(.codex, email: $0.email) == key }.map(\.quota)
        case .claude: claudeProfiles.filter { Self.accountKey(.claude, email: $0.email) == key }.map(\.quota)
        }
        return records.contains { record in
            record?.reading(at: now).windows.contains(where: \.isCurrent) ?? false
        }
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
    func setRemoteAutoReset(device: DeviceSnapshot, account: SharedAccount, enabled: Bool) {
        guard !isReadOnly, account.provider == .codex, device.acceptsCommands else { return }
        let key = Self.remoteKey(device: device.deviceID, account: account)
        let ref = AccountRef(provider: .codex, id: account.profileID)
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
        onSetRemoteAutoReset?(device.deviceID, account, enabled)
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
