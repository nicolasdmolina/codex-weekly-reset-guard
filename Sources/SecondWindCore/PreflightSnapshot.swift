import Foundation

/// The quota evidence the live app publishes for `SecondWind --preflight`.
///
/// It carries `QuotaAccountRecord` evidence only: provider, profile UUID, the last successful
/// observation's windows and unreported windows, and the last refresh failure. Inventory,
/// emails, names and plan details are never written. `providers` lists the account rosters
/// loaded during the publishing app run; an absent provider means its accounts are not known yet.
public struct PreflightSnapshot: Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var publishedAt: Date
    public var providers: Set<QuotaProvider>
    public var accounts: [QuotaAccountRecord]

    public init(publishedAt: Date, providers: Set<QuotaProvider>, accounts: [QuotaAccountRecord]) {
        self.publishedAt = publishedAt
        self.providers = providers
        self.accounts = accounts
    }
}

public enum PreflightSnapshotReadFailure: String, Error, Sendable, Equatable {
    case missing = "snapshot_missing"
    case unreadable = "snapshot_unreadable"
    case invalid = "snapshot_invalid"
    case unsupportedVersion = "snapshot_unsupported_version"
}

public enum PreflightSnapshotPublishError: Error, Equatable, Sendable {
    case providerMismatch
    case duplicateAccount
    case tooLarge(Int)
}

public enum PreflightSnapshotFile {
    public static let fileName = "quota-snapshot.json"
    public static let maximumBytes = 256 * 1_024

    public static func url(
        applicationSupportDirectory: URL = ProfileConfiguration.defaultApplicationSupportDirectory
    ) -> URL {
        applicationSupportDirectory
            .appendingPathComponent(fileName, isDirectory: false)
            .standardizedFileURL
    }

    /// Reads without creating, locking, repairing or chmod-ing anything.
    public static func read(from url: URL) -> Result<PreflightSnapshot, PreflightSnapshotReadFailure> {
        let data: Data
        do {
            guard let contents = try PrivateFileIO.readIfPresent(from: url, maximumBytes: maximumBytes) else {
                return .failure(.missing)
            }
            data = contents
        } catch {
            return .failure(.unreadable)
        }
        return decode(data)
    }

    static func decode(_ data: Data) -> Result<PreflightSnapshot, PreflightSnapshotReadFailure> {
        struct VersionProbe: Decodable { var schemaVersion: Int }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else {
            return .failure(.invalid)
        }
        guard probe.schemaVersion == PreflightSnapshot.currentSchemaVersion else {
            return .failure(.unsupportedVersion)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(SnapshotFile.self, from: data),
              let snapshot = file.snapshot else {
            return .failure(.invalid)
        }
        return .success(snapshot)
    }

    static func encode(_ snapshot: PreflightSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(SnapshotFile(snapshot))
    }
}

/// Owns the snapshot file for one app run. Call `clear` at launch so a previous run's
/// readings never stand in for this run, then `publish` after each provider snapshot.
public actor PreflightSnapshotPublisher {
    public nonisolated let fileURL: URL
    private let runStartedAt: Date
    private var rosters: [QuotaProvider: [QuotaAccountRecord]] = [:]
    private var publishedRosters: [QuotaProvider: [QuotaAccountRecord]]?

    /// Readings observed before `runStartedAt`, such as Claude's persisted last report, are
    /// published as no reading until this run verifies the account again.
    public init(fileURL: URL, runStartedAt: Date = Date()) {
        self.fileURL = fileURL.standardizedFileURL
        self.runStartedAt = runStartedAt
    }

    /// Forgets every roster and writes an empty snapshot. Use at launch and at quit.
    public func clear(now: Date) throws {
        rosters = [:]
        publishedRosters = nil
        try write(now: now)
    }

    /// Replaces one provider's roster. Call only once that provider's account list has loaded,
    /// with every enrolled account, so removed accounts disappear and failures stay visible.
    public func publish(provider: QuotaProvider, records: [QuotaAccountRecord], now: Date) throws {
        guard records.allSatisfy({ $0.provider == provider }) else {
            throw PreflightSnapshotPublishError.providerMismatch
        }
        guard Set(records.map(\.accountID)).count == records.count else {
            throw PreflightSnapshotPublishError.duplicateAccount
        }
        rosters[provider] = records.map { record in
            guard let success = record.lastSuccess,
                  record.lastSuccessRestored || success.observedAt < runStartedAt else { return record }
            return QuotaAccountRecord(
                provider: record.provider,
                accountID: record.accountID,
                lastFailure: record.lastFailure
            )
        }
        try write(now: now)
    }

    private func write(now: Date) throws {
        guard rosters != publishedRosters else { return }
        // A write can fail after rename. Retry the latest complete set on the next update.
        publishedRosters = nil
        let snapshot = PreflightSnapshot(
            publishedAt: now,
            providers: Set(rosters.keys),
            accounts: QuotaProvider.allCases.flatMap { rosters[$0] ?? [] }
        )
        let data = try PreflightSnapshotFile.encode(snapshot)
        guard data.count <= PreflightSnapshotFile.maximumBytes else {
            throw PreflightSnapshotPublishError.tooLarge(data.count)
        }
        try PrivateFileIO.atomicWrite(data, to: fileURL)
        publishedRosters = rosters
    }
}

// MARK: - File format

private struct SnapshotFile: Codable {
    var schemaVersion: Int
    var publishedAt: Date
    var providers: [QuotaProvider]
    var accounts: [AccountEntry]

    init(_ snapshot: PreflightSnapshot) {
        schemaVersion = PreflightSnapshot.currentSchemaVersion
        publishedAt = snapshot.publishedAt
        providers = QuotaProvider.allCases.filter(snapshot.providers.contains)
        accounts = snapshot.accounts.map(AccountEntry.init)
    }

    /// Nil when anything is out of range, repeated, or belongs to an unlisted roster.
    var snapshot: PreflightSnapshot? {
        let loaded = Set(providers)
        guard loaded.count == providers.count,
              Set(accounts.map { "\($0.provider.rawValue):\($0.id.lowercased())" }).count == accounts.count,
              accounts.allSatisfy({ loaded.contains($0.provider) }) else {
            return nil
        }
        var records: [QuotaAccountRecord] = []
        for entry in accounts {
            guard let record = entry.record else { return nil }
            records.append(record)
        }
        return PreflightSnapshot(publishedAt: publishedAt, providers: loaded, accounts: records)
    }
}

private struct AccountEntry: Codable {
    var provider: QuotaProvider
    var id: String
    var lastSuccess: ObservationEntry?
    var lastFailure: FailureEntry?

    init(_ record: QuotaAccountRecord) {
        provider = record.provider
        id = record.accountID.uuidString.lowercased()
        lastSuccess = record.lastSuccess.map(ObservationEntry.init)
        lastFailure = record.lastFailure.map(FailureEntry.init)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(id, forKey: .id)
        try container.encode(lastSuccess, forKey: .lastSuccess)
        try container.encode(lastFailure, forKey: .lastFailure)
    }

    var record: QuotaAccountRecord? {
        guard let accountID = UUID(uuidString: id) else { return nil }
        let observation: QuotaObservation?
        if let lastSuccess {
            guard let value = lastSuccess.observation(for: provider) else { return nil }
            observation = value
        } else {
            observation = nil
        }
        let failure: QuotaRefreshFailure?
        if let lastFailure {
            guard let value = lastFailure.failure else { return nil }
            failure = value
        } else {
            failure = nil
        }
        return QuotaAccountRecord(
            provider: provider,
            accountID: accountID,
            lastSuccess: observation,
            lastFailure: failure
        )
    }
}

private struct ObservationEntry: Codable {
    var observedAt: Date
    var windows: [WindowEntry]
    var unreportedWindows: [String]
    var includedUsageAccess: IncludedUsageAccess?

    init(_ observation: QuotaObservation) {
        observedAt = observation.observedAt
        includedUsageAccess = observation.includedUsageAccess == .unreported ? nil : observation.includedUsageAccess
        // A value outside 0...100 cannot be trusted, so it is published as unreported.
        let valid = observation.windows.filter { $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) }
        let rejected = observation.windows.filter { !valid.contains($0) }.map(\.kind)
        windows = valid.map(WindowEntry.init)
        unreportedWindows = (observation.unreportedWindows + rejected).map(\.key)
    }

    func observation(for provider: QuotaProvider) -> QuotaObservation? {
        var parsed: [QuotaWindow] = []
        var unreported: [QuotaWindowKind] = []
        var seen = Set<String>()
        for entry in windows {
            guard let kind = QuotaWindowKind(key: entry.kind),
                  seen.insert(kind.key).inserted,
                  entry.usedPercent.isFinite, (0...100).contains(entry.usedPercent) else {
                return nil
            }
            if provider == .codex && entry.resetsAt == nil {
                unreported.append(kind)
            } else {
                parsed.append(QuotaWindow(kind: kind, usedPercent: entry.usedPercent, resetsAt: entry.resetsAt))
            }
        }
        for key in unreportedWindows {
            guard let kind = QuotaWindowKind(key: key), seen.insert(key).inserted else { return nil }
            unreported.append(kind)
        }
        return QuotaObservation(
            observedAt: observedAt,
            windows: parsed,
            unreportedWindows: unreported,
            inventory: .omitted,
            includedUsageAccess: includedUsageAccess ?? .unreported
        )
    }
}

private struct WindowEntry: Codable {
    var kind: String
    var usedPercent: Double
    var resetsAt: Date?

    init(_ window: QuotaWindow) {
        kind = window.kind.key
        usedPercent = window.usedPercent
        resetsAt = window.resetsAt
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(usedPercent, forKey: .usedPercent)
        try container.encode(resetsAt, forKey: .resetsAt)
    }
}

private struct FailureEntry: Codable {
    var failedAt: Date
    var reason: String

    init(_ failure: QuotaRefreshFailure) {
        failedAt = failure.failedAt
        reason = failure.reason.preflightCode
    }

    var failure: QuotaRefreshFailure? {
        QuotaFailureReason(preflightCode: reason).map { QuotaRefreshFailure(failedAt: failedAt, reason: $0) }
    }
}

extension QuotaWindowKind {
    init?(key: String) {
        switch key {
        case "session": self = .session
        case "weekly": self = .weekly
        case "monthly": self = .monthly
        default:
            let prefix = "weekly:"
            guard key.hasPrefix(prefix), key.count > prefix.count else { return nil }
            self = .modelWeekly(String(key.dropFirst(prefix.count)))
        }
    }
}

extension QuotaFailureReason {
    /// Stable snake_case text used in the snapshot file and preflight output.
    public var preflightCode: String {
        switch self {
        case .signInRequired: "sign_in_required"
        case .wrongAccount: "wrong_account"
        case .noPlanLimits: "no_plan_limits"
        case .unreadable: "unreadable"
        case .unavailable: "unavailable"
        case .monitoringStopped: "monitoring_stopped"
        }
    }

    init?(preflightCode: String) {
        guard let match = [
            QuotaFailureReason.signInRequired, .wrongAccount, .noPlanLimits,
            .unreadable, .unavailable, .monitoringStopped,
        ].first(where: { $0.preflightCode == preflightCode }) else {
            return nil
        }
        self = match
    }
}
