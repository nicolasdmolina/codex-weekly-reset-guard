import AppKit
import Combine
import Foundation

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
        case .nearLimit: "Near weekly limit"
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
}

@MainActor
final class GuardAppModel: ObservableObject {
    @Published var profiles: [GuardProfilePresentation]
    @Published var claudeProfiles: [ClaudeProfilePresentation]
    @Published var isCheckingClaude = false
    @Published var enrollmentProvider: ProviderKind = .codex
    @Published var history: [GuardHistoryEvent]
    @Published var isChecking = false
    @Published var lastCheckedAt: Date?
    @Published var banner: String?
    @Published var isPreview: Bool
    let isReadOnly: Bool
    @Published var isReady = false
    @Published var isShowingAddProfile = false
    @Published var isAddingProfile = false
    @Published var profileEmail = ""
    @Published var profileDisplayName = ""
    @Published var enrollmentError: String?
    /// Synthetic previews use one reference clock for every relative date label.
    let referenceDate: Date?

    var onCheckNow: (() -> Void)?
    var onToggleAutoReset: ((String, Bool) -> Void)?
    var onReconnect: ((String) -> Void)?
    var onAddProfile: ((String, String) -> Void)?
    var onAddClaudeProfile: ((String, String) -> Void)?
    var onConnectClaude: ((String) -> Void)?
    var onCancelClaudeSignIn: ((String) -> Void)?

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

    var isBusyChecking: Bool { isChecking || isCheckingClaude }

    /// The least headroom across every account and window, shown in the menu bar.
    var minimumRemainingPercent: Double? {
        (profiles.compactMap(\.weeklyRemainingPercent)
            + claudeProfiles.compactMap { $0.tightestWindow?.remainingPercent }).min()
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
        onReconnect?(profileID)
    }

    func addProfile() {
        guard isReady, !isAddingProfile else { return }
        guard MonitorPersistence.isValidEmail(profileEmail) else {
            enrollmentError = enrollmentProvider == .codex
                ? MonitorPersistenceError.invalidExpectedIdentity.localizedDescription
                : ClaudeMonitorError.invalidEmail.localizedDescription
            return
        }
        guard !isPreview else {
            enrollmentError = "Preview only. Account setup is available in the installed app."
            return
        }
        enrollmentError = nil
        isAddingProfile = true
        let email = MonitorPersistence.normalizedEmail(profileEmail)
        switch enrollmentProvider {
        case .codex: onAddProfile?(email, profileDisplayName)
        case .claude: onAddClaudeProfile?(email, profileDisplayName)
        }
    }

    func connectClaude(profileID: String) {
        guard !isReadOnly else { return }
        if isPreview {
            banner = "Preview only. No sign-in was started."
            return
        }
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
