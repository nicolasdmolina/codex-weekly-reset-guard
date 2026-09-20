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

struct GuardHistoryEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let occurredAt: Date
    let profileName: String
    let summary: String
}

@MainActor
final class GuardAppModel: ObservableObject {
    @Published var profiles: [GuardProfilePresentation]
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

    init(
        profiles: [GuardProfilePresentation] = [],
        history: [GuardHistoryEvent] = [],
        isPreview: Bool = false,
        isReadOnly: Bool = false,
        referenceDate: Date? = nil
    ) {
        self.profiles = profiles
        self.history = history
        self.isPreview = isPreview
        self.isReadOnly = isReadOnly
        self.isReady = isPreview
        self.referenceDate = referenceDate
    }

    var minimumRemainingPercent: Double? {
        profiles.compactMap(\.weeklyRemainingPercent).min()
    }

    var hasAttention: Bool {
        profiles.contains { $0.status == .attention || $0.status == .disconnected }
    }

    func checkNow() {
        guard !isChecking else { return }
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
        guard !isPreview else { return }
        onReconnect?(profileID)
    }

    func addProfile() {
        guard isReady, !isAddingProfile else { return }
        guard MonitorPersistence.isValidEmail(profileEmail) else {
            enrollmentError = MonitorPersistenceError.invalidExpectedIdentity.localizedDescription
            return
        }
        guard !isPreview else {
            enrollmentError = "Preview only. Account setup is available in the installed app."
            return
        }
        enrollmentError = nil
        isAddingProfile = true
        onAddProfile?(MonitorPersistence.normalizedEmail(profileEmail), profileDisplayName)
    }
}
