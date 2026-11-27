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
    /// The full email once the first sign-in has supplied it.
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
    /// The full email once the first sign-in has supplied it.
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
        }
    }

    func setAutoReset(profileID: String, enabled: Bool) {
        guard !isReadOnly else { return }
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        guard !enabled || profiles[index].isConnected else { return }
        if isPreview {
            profiles[index].autoResetEnabled = enabled
            return
        }
        // Live mode is persistence-led: the switch changes only after the runtime publishes the
        // committed setting. A failed disable can therefore never look off while remaining on.
        onToggleAutoReset?(profileID, enabled)
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
