import Foundation

// What one Mac shares with the user's other Macs through a folder they both see. Display, alert
// and Auto-redeem switch data only: no token, file path or idempotency key ever leaves the Mac,
// and nothing here can request a reset. A remote command can only flip a profile's enabled flag
// through the host's own toggle path; the host's policy engine stays the only way to redeem.

/// A Mac's sync identity, generated once and kept in its local state.
public struct SyncDeviceID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init?(string: String) {
        guard let value = UUID(uuidString: string) else { return nil }
        self.init(value)
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Lowercased UUID, the file and folder name this device owns.
    public var description: String { rawValue.uuidString.lowercased() }
}

public struct SharedWindow: Codable, Equatable, Sendable {
    /// `QuotaWindowKind.key`: "session", "weekly" or "weekly:<model>".
    public var kind: String
    public var remainingPercent: Double
    public var resetsAt: Date?
    public var observedAt: Date

    public init(kind: QuotaWindowKind, remainingPercent: Double, resetsAt: Date?, observedAt: Date) {
        self.kind = kind.key
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.observedAt = observedAt
    }

    public var windowKind: QuotaWindowKind? { QuotaWindowKind(key: kind) }
}

public struct SharedAccount: Codable, Equatable, Sendable, Identifiable {
    public var profileID: UUID
    public var provider: QuotaProvider
    public var displayName: String
    public var email: String
    /// Codex only; nil for Claude, which Second Wind never redeems.
    public var autoRedeemEnabled: Bool?
    public var windows: [SharedWindow]
    public var savedResetCount: Int?
    public var attentionMessage: String?

    public init(
        profileID: UUID,
        provider: QuotaProvider,
        displayName: String,
        email: String,
        autoRedeemEnabled: Bool?,
        windows: [SharedWindow],
        savedResetCount: Int? = nil,
        attentionMessage: String? = nil
    ) {
        self.profileID = profileID
        self.provider = provider
        self.displayName = displayName
        self.email = DeviceSyncPolicy.normalizedEmail(email)
        self.autoRedeemEnabled = provider == .codex ? autoRedeemEnabled : nil
        self.windows = windows
        self.savedResetCount = savedResetCount
        self.attentionMessage = attentionMessage
    }

    /// `provider:lowercased-uuid`, unique within one device.
    public var id: String { "\(provider.rawValue):\(profileID.uuidString.lowercased())" }

    /// The shared windows as a quota record, so a remote account reads through the same model
    /// as a local one. Remote readings use `QuotaReadPolicy.remote`.
    public func quotaRecord() -> QuotaAccountRecord {
        let windows = self.windows.compactMap { shared -> QuotaWindow? in
            guard let kind = shared.windowKind else { return nil }
            return QuotaWindow(kind: kind, usedPercent: 100 - shared.remainingPercent, resetsAt: shared.resetsAt)
        }
        guard let observedAt = self.windows.map(\.observedAt).min(), !windows.isEmpty else {
            return QuotaAccountRecord(provider: provider, accountID: profileID)
        }
        let inventory: ResetInventoryReport = switch provider {
        case .claude:
            .notTracked
        case .codex:
            savedResetCount.map {
                .reported(ResetInventorySnapshot(availableCount: $0, expiries: .unlisted, fetchedAt: observedAt))
            } ?? .omitted
        }
        return QuotaAccountRecord(
            provider: provider,
            accountID: profileID,
            lastSuccess: QuotaObservation(observedAt: observedAt, windows: windows, inventory: inventory)
        )
    }
}

/// `devices/<deviceID>.json`, written only by the device it describes.
public struct DeviceSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var deviceID: SyncDeviceID
    public var deviceName: String
    public var publishedAt: Date
    public var accounts: [SharedAccount]
    /// Commands this device has handled, newest last, bounded to `DeviceSyncPolicy.rememberedCommands`.
    public var appliedCommandIDs: [UUID]
    /// True only when the pass that wrote this snapshot could list this device's command folder.
    /// Absent in older files, which read as false.
    public var acceptsCommands: Bool
    /// True when this device can remove one of its accounts on another Mac's request. Absent in
    /// older files, which read as false, so a Mac never asks a version that would drop the request.
    public var acceptsRemoval: Bool

    public init(
        schemaVersion: Int = DeviceSnapshot.currentSchemaVersion,
        deviceID: SyncDeviceID,
        deviceName: String,
        publishedAt: Date,
        accounts: [SharedAccount],
        appliedCommandIDs: [UUID],
        acceptsCommands: Bool = false,
        acceptsRemoval: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.publishedAt = publishedAt
        self.accounts = accounts
        self.appliedCommandIDs = appliedCommandIDs
        self.acceptsCommands = acceptsCommands
        self.acceptsRemoval = acceptsRemoval
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, deviceID, deviceName, publishedAt, accounts, appliedCommandIDs, acceptsCommands, acceptsRemoval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        deviceID = try container.decode(SyncDeviceID.self, forKey: .deviceID)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        publishedAt = try container.decode(Date.self, forKey: .publishedAt)
        accounts = try container.decode([SharedAccount].self, forKey: .accounts)
        appliedCommandIDs = try container.decode([UUID].self, forKey: .appliedCommandIDs)
        acceptsCommands = try container.decodeIfPresent(Bool.self, forKey: .acceptsCommands) ?? false
        acceptsRemoval = try container.decodeIfPresent(Bool.self, forKey: .acceptsRemoval) ?? false
    }

    /// True when a removal sent now would be read and acted on.
    public func canRemove(at now: Date) -> Bool {
        acceptsCommands && acceptsRemoval && freshness(at: now).isLive
    }

    public func freshness(at now: Date) -> SnapshotFreshness {
        SnapshotFreshness(publishedAt: publishedAt, now: now)
    }
}

/// An absolute state, never a toggle, so a repeat or late delivery cannot invert the intent.
public enum RemoteAction: Codable, Equatable, Sendable {
    case setAutoRedeem(profileID: UUID, enabled: Bool)
    /// Removes one account from the host, the same way its own Remove does. Sent only to a Mac
    /// whose snapshot says `acceptsRemoval`; an older Mac cannot read it and deletes the file.
    case removeAccount(profileID: UUID)
}

/// `commands/<targetDeviceID>/<commandID>.json`. Unique names, so two Macs never edit one file.
public struct RemoteCommand: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var issuedBy: SyncDeviceID
    public var issuedAt: Date
    public var action: RemoteAction

    public init(id: UUID = UUID(), issuedBy: SyncDeviceID, issuedAt: Date, action: RemoteAction) {
        self.id = id
        self.issuedBy = issuedBy
        self.issuedAt = issuedAt
        self.action = action
    }
}

public enum DeviceSyncPolicy {
    /// A snapshot or reading older than this is stale: shown with its age, never alerted from.
    public static let staleAfter: TimeInterval = 10 * 60
    /// A host refuses a command older than this, and the sender stops waiting for it. Long enough
    /// for iCloud Drive to deliver a file to a Mac that was briefly asleep or offline.
    public static let commandLifetime: TimeInterval = 30 * 60
    /// How far ahead of the host's clock a command may claim to be.
    public static let allowedClockSkew: TimeInterval = 2 * 60
    /// A Mac that has not published for this long is no longer listed.
    public static let forgetDeviceAfter: TimeInterval = 7 * 24 * 60 * 60
    public static let rememberedCommands = 50

    public static func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension QuotaReadPolicy {
    /// Readings relayed from another Mac stay current as long as its snapshot does.
    public static let remote = QuotaReadPolicy(staleAfter: DeviceSyncPolicy.staleAfter)
}

public enum SnapshotFreshness: Equatable, Sendable {
    case live(age: TimeInterval)
    case stale(age: TimeInterval)

    public init(publishedAt: Date, now: Date) {
        // A clock running slightly ahead on the other Mac reads as just now, not as negative.
        let age = max(0, now.timeIntervalSince(publishedAt))
        self = age < DeviceSyncPolicy.staleAfter ? .live(age: age) : .stale(age: age)
    }

    public var isLive: Bool {
        if case .live = self { return true }
        return false
    }
}

/// A command this Mac sent and has not yet seen settled.
public struct PendingRemoteCommand: Codable, Equatable, Sendable {
    public var commandID: UUID
    public var enabled: Bool
    public var issuedAt: Date

    public init(commandID: UUID, enabled: Bool, issuedAt: Date) {
        self.commandID = commandID
        self.enabled = enabled
        self.issuedAt = issuedAt
    }
}

/// How a remote account reads on this Mac right now.
public enum RemoteAccountState: Equatable, Sendable {
    case live(age: TimeInterval)
    case stale(age: TimeInterval)
    /// A switch change was sent and the host has not answered yet.
    case pending(enabled: Bool)
    /// The host handled the change without making it, or never answered in time.
    case notApplied(enabled: Bool)

    public static func classify(
        account: SharedAccount,
        in snapshot: DeviceSnapshot,
        pending: PendingRemoteCommand?,
        now: Date
    ) -> RemoteAccountState {
        if let pending {
            if snapshot.appliedCommandIDs.contains(pending.commandID) {
                if account.autoRedeemEnabled != pending.enabled { return .notApplied(enabled: pending.enabled) }
            } else if account.autoRedeemEnabled == pending.enabled, snapshot.publishedAt >= pending.issuedAt {
                // The host already had this setting, or another Mac set it; nothing is left to wait for.
            } else if now.timeIntervalSince(pending.issuedAt) > DeviceSyncPolicy.commandLifetime + DeviceSyncPolicy.allowedClockSkew {
                return .notApplied(enabled: pending.enabled)
            } else {
                return .pending(enabled: pending.enabled)
            }
        }
        switch snapshot.freshness(at: now) {
        case let .live(age): return .live(age: age)
        case let .stale(age): return .stale(age: age)
        }
    }

    public var isSettled: Bool {
        switch self {
        case .live, .stale: true
        case .pending, .notApplied: false
        }
    }
}

/// Keeps one account from auto-redeeming on two Macs at once.
public enum AutoRedeemGuard {
    /// The first device among `snapshots` whose live snapshot has Auto-redeem on for `email`.
    public static func conflictingDevice(
        email: String,
        among snapshots: [DeviceSnapshot],
        excluding excluded: Set<SyncDeviceID> = [],
        now: Date
    ) -> DeviceSnapshot? {
        let email = DeviceSyncPolicy.normalizedEmail(email)
        guard !email.isEmpty else { return nil }
        return snapshots.first { snapshot in
            !excluded.contains(snapshot.deviceID)
                && snapshot.freshness(at: now).isLive
                && snapshot.accounts.contains {
                    $0.provider == .codex && $0.autoRedeemEnabled == true && $0.email == email
                }
        }
    }
}

public enum CommandRejection: Equatable, Sendable {
    case alreadyApplied
    case issuedBySelf
    case expired
    case issuedInFuture
    case unknownProfile
    /// Only Codex profiles have Auto-redeem.
    case unsupportedProfile
    case autoRedeemOnElsewhere(deviceName: String)
    /// A removal must come from a Mac this one currently sees in the sync folder.
    case unknownSender
}

public enum CommandDecision: Equatable, Sendable {
    case apply(profileID: UUID, enabled: Bool)
    case remove(profileID: UUID)
    case reject(CommandRejection)
}

public enum RemoteCommandPolicy {
    public static func decide(
        _ command: RemoteCommand,
        host: SyncDeviceID,
        hostAccounts: [SharedAccount],
        handledCommandIDs: [UUID],
        otherDevices: [DeviceSnapshot],
        now: Date
    ) -> CommandDecision {
        guard !handledCommandIDs.contains(command.id) else { return .reject(.alreadyApplied) }
        guard command.issuedBy != host else { return .reject(.issuedBySelf) }
        let age = now.timeIntervalSince(command.issuedAt)
        guard age >= -DeviceSyncPolicy.allowedClockSkew else { return .reject(.issuedInFuture) }
        guard age <= DeviceSyncPolicy.commandLifetime else { return .reject(.expired) }

        switch command.action {
        case let .setAutoRedeem(profileID, enabled):
            guard let account = hostAccounts.first(where: { $0.profileID == profileID }) else {
                return .reject(.unknownProfile)
            }
            guard account.provider == .codex else { return .reject(.unsupportedProfile) }
            // Turning off is always safe; only an enable can create a second redeemer.
            if enabled, let other = AutoRedeemGuard.conflictingDevice(
                email: account.email,
                among: otherDevices,
                excluding: [host],
                now: now
            ) {
                return .reject(.autoRedeemOnElsewhere(deviceName: other.deviceName))
            }
            return .apply(profileID: profileID, enabled: enabled)
        case let .removeAccount(profileID):
            guard hostAccounts.contains(where: { $0.profileID == profileID }) else {
                return .reject(.unknownProfile)
            }
            guard otherDevices.contains(where: { $0.deviceID == command.issuedBy }) else {
                return .reject(.unknownSender)
            }
            return .remove(profileID: profileID)
        }
    }
}
