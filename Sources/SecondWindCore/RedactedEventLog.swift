import Foundation

public struct RedactedEventRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let profileID: UUID?
    public let kind: Kind
    public let message: String?
    public let fields: [String: String]

    public enum Kind: String, Codable, CaseIterable, Equatable, Sendable {
        case profileConnected
        case profileDisconnected
        case checkSucceeded
        case checkFailed
        case thresholdConfirmed
        case redemptionStarted
        case redemptionSucceeded
        case redemptionDeferred
        case redemptionFailed
        case verificationFailed
        case authenticationRequired
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        profileID: UUID?,
        kind: Kind,
        message: String?,
        fields: [String: String]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.profileID = profileID
        self.kind = kind
        self.message = message
        self.fields = fields
    }
}

public actor RedactedEventLog {
    public nonisolated let fileURL: URL
    public nonisolated let maximumEntries: Int

    private let store: SecureStateStore<[RedactedEventRecord]>

    public init(fileURL: URL, maximumEntries: Int = 500) {
        self.fileURL = fileURL.standardizedFileURL
        self.maximumEntries = max(1, maximumEntries)
        self.store = SecureStateStore(fileURL: self.fileURL)
    }

    @discardableResult
    public func append(
        profileID: UUID?,
        kind: RedactedEventRecord.Kind,
        message: String? = nil,
        fields: [String: String] = [:],
        at timestamp: Date = Date()
    ) async throws -> RedactedEventRecord {
        let safeFields = fields.reduce(into: [String: String]()) { result, item in
            guard !Self.isSensitiveKey(item.key) else { return }
            result[item.key] = Self.redact(item.value)
        }
        let record = RedactedEventRecord(
            timestamp: timestamp,
            profileID: profileID,
            kind: kind,
            message: message.map(Self.redact),
            fields: safeFields
        )

        let maximumEntries = self.maximumEntries
        try await store.update(defaultValue: []) { records in
            records.append(record)
            if records.count > maximumEntries {
                records.removeFirst(records.count - maximumEntries)
            }
        }
        return record
    }

    public func entries(limit: Int? = nil) async throws -> [RedactedEventRecord] {
        let records = try await store.load() ?? []
        guard let limit else { return records }
        return Array(records.suffix(max(0, limit)))
    }

    static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        let forbiddenFragments = [
            "token", "secret", "password", "authorization", "credential", "apikey",
            "email", "creditid", "idempotencykey", "authurl"
        ]
        return forbiddenFragments.contains { normalized.contains($0) }
    }

    static func redact(_ input: String) -> String {
        var value = input
        let replacements: [(String, String)] = [
            (#"(?i)https?://[^\s]+"#, "<redacted-url>"),
            (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "<redacted-email>"),
            (#"(?i)\bBearer\s+[A-Z0-9._~+/=-]+"#, "Bearer <redacted>"),
            (#"\bsk-[A-Za-z0-9_-]{8,}\b"#, "<redacted-api-key>"),
            (#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, "<redacted-token>"),
            (#"\bRateLimitResetCredit_[A-Za-z0-9_-]+\b"#, "<redacted-credit>"),
            (#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}\b"#, "<redacted-identifier>")
        ]
        for (pattern, replacement) in replacements {
            value = value.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return value
    }
}
