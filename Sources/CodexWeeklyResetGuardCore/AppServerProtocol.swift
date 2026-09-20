import Foundation

public enum AppServerMethod: String, Sendable {
    case initialize
    case initialized
    case accountRead = "account/read"
    case accountLoginStart = "account/login/start"
    case accountRateLimitsRead = "account/rateLimits/read"
    case accountRateLimitResetCreditConsume = "account/rateLimitResetCredit/consume"
}

/// A JSON value used only at the app-server transport boundary.
///
/// Keeping the untyped value at this boundary lets tests inject protocol fixtures while all
/// application-facing calls continue to use the typed response models below.
public enum RPCJSONValue: Codable, Equatable, Sendable {
    case object([String: RPCJSONValue])
    case array([RPCJSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RPCJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: RPCJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public static func encoding<Value: Encodable>(_ value: Value) throws -> RPCJSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(RPCJSONValue.self, from: data)
    }

    public func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }
}

public struct AppServerRequestEnvelope: Codable, Equatable, Sendable {
    public let id: Int64
    public let method: String
    public let params: RPCJSONValue?

    public init(id: Int64, method: String, params: RPCJSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct AppServerNotificationEnvelope: Codable, Equatable, Sendable {
    public let method: String
    public let params: RPCJSONValue?

    public init(method: String, params: RPCJSONValue? = nil) {
        self.method = method
        self.params = params
    }
}

public struct AppServerRPCErrorPayload: Codable, Equatable, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public struct AppServerResponseEnvelope: Decodable, Equatable, Sendable {
    public let id: Int64?
    public let result: RPCJSONValue?
    public let error: AppServerRPCErrorPayload?
    public let method: String?
    public let params: RPCJSONValue?

    public init(
        id: Int64? = nil,
        result: RPCJSONValue? = nil,
        error: AppServerRPCErrorPayload? = nil,
        method: String? = nil,
        params: RPCJSONValue? = nil
    ) {
        self.id = id
        self.result = result
        self.error = error
        self.method = method
        self.params = params
    }
}

public struct RPCInitializeParams: Codable, Equatable, Sendable {
    public struct ClientInfo: Codable, Equatable, Sendable {
        public let name: String
        public let title: String?
        public let version: String

        public init(name: String, title: String? = nil, version: String) {
            self.name = name
            self.title = title
            self.version = version
        }
    }

    public let clientInfo: ClientInfo

    public init(clientInfo: ClientInfo) {
        self.clientInfo = clientInfo
    }
}

public struct RPCInitializeResponse: Codable, Equatable, Sendable {
    public let userAgent: String
    public let platformFamily: String
    public let platformOs: String
    public let codexHome: String

    public init(userAgent: String, platformFamily: String, platformOs: String, codexHome: String) {
        self.userAgent = userAgent
        self.platformFamily = platformFamily
        self.platformOs = platformOs
        self.codexHome = codexHome
    }
}

public struct RPCAccountSummary: Codable, Equatable, Sendable {
    public let type: String
    public let email: String?
    public let planType: String?
    public let credentialSource: String?
    public let usesCodexManagedCredentials: Bool?

    public init(
        type: String,
        email: String? = nil,
        planType: String? = nil,
        credentialSource: String? = nil,
        usesCodexManagedCredentials: Bool? = nil
    ) {
        self.type = type
        self.email = email
        self.planType = planType
        self.credentialSource = credentialSource
        self.usesCodexManagedCredentials = usesCodexManagedCredentials
    }
}

public struct RPCAccountReadResponse: Codable, Equatable, Sendable {
    public let account: RPCAccountSummary?
    public let requiresOpenaiAuth: Bool

    public init(account: RPCAccountSummary?, requiresOpenaiAuth: Bool) {
        self.account = account
        self.requiresOpenaiAuth = requiresOpenaiAuth
    }
}

public struct RPCChatGPTLoginStartResponse: Codable, Equatable, Sendable {
    public let type: String
    public let loginID: String
    public let authURL: URL

    enum CodingKeys: String, CodingKey {
        case type
        case loginID = "loginId"
        case authURL = "authUrl"
    }

    public init(type: String = "chatgpt", loginID: String, authURL: URL) {
        self.type = type
        self.loginID = loginID
        self.authURL = authURL
    }
}

public struct RPCRateLimitWindow: Codable, Equatable, Sendable {
    public let usedPercent: Int
    public let windowDurationMinutes: Int64?
    public let resetsAt: Int64?

    enum CodingKeys: String, CodingKey {
        case usedPercent
        case windowDurationMinutes = "windowDurationMins"
        case resetsAt
    }

    public init(usedPercent: Int, windowDurationMinutes: Int64?, resetsAt: Int64?) {
        self.usedPercent = usedPercent
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }
}

public struct RPCRateLimitSnapshot: Codable, Equatable, Sendable {
    public let limitID: String?
    public let limitName: String?
    public let primary: RPCRateLimitWindow?
    public let secondary: RPCRateLimitWindow?
    public let planType: String?
    public let rateLimitReachedType: String?

    enum CodingKeys: String, CodingKey {
        case limitID = "limitId"
        case limitName
        case primary
        case secondary
        case planType
        case rateLimitReachedType
    }

    public init(
        limitID: String?,
        limitName: String?,
        primary: RPCRateLimitWindow?,
        secondary: RPCRateLimitWindow?,
        planType: String? = nil,
        rateLimitReachedType: String? = nil
    ) {
        self.limitID = limitID
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
        self.rateLimitReachedType = rateLimitReachedType
    }
}

public struct RPCResetCredit: Codable, Equatable, Sendable {
    public let id: String
    public let resetType: String
    public let status: String
    public let grantedAt: Int64
    public let expiresAt: Int64?
    public let title: String?
    public let detail: String?

    enum CodingKeys: String, CodingKey {
        case id
        case resetType
        case status
        case grantedAt
        case expiresAt
        case title
        case detail = "description"
    }

    public init(
        id: String,
        resetType: String,
        status: String,
        grantedAt: Int64,
        expiresAt: Int64?,
        title: String?,
        detail: String?
    ) {
        self.id = id
        self.resetType = resetType
        self.status = status
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.title = title
        self.detail = detail
    }
}

public struct RPCResetCreditsSummary: Codable, Equatable, Sendable {
    public let availableCount: Int64
    public let credits: [RPCResetCredit]?

    public init(availableCount: Int64, credits: [RPCResetCredit]?) {
        self.availableCount = availableCount
        self.credits = credits
    }
}

public struct RPCRateLimitsReadResponse: Codable, Equatable, Sendable {
    public let rateLimits: RPCRateLimitSnapshot
    public let rateLimitsByLimitID: [String: RPCRateLimitSnapshot]?
    public let rateLimitResetCredits: RPCResetCreditsSummary?

    enum CodingKeys: String, CodingKey {
        case rateLimits
        case rateLimitsByLimitID = "rateLimitsByLimitId"
        case rateLimitResetCredits
    }

    public init(
        rateLimits: RPCRateLimitSnapshot,
        rateLimitsByLimitID: [String: RPCRateLimitSnapshot]? = nil,
        rateLimitResetCredits: RPCResetCreditsSummary? = nil
    ) {
        self.rateLimits = rateLimits
        self.rateLimitsByLimitID = rateLimitsByLimitID
        self.rateLimitResetCredits = rateLimitResetCredits
    }

    /// The canonical Codex bucket. A present multi-bucket map is authoritative and must contain
    /// the exact `codex` key; legacy top-level fallback is allowed only when the map is absent.
    public var canonicalCodexRateLimits: RPCRateLimitSnapshot? {
        if let rateLimitsByLimitID {
            return rateLimitsByLimitID["codex"]
        }
        return rateLimits
    }
}

public enum RPCConsumeResetOutcome: String, Codable, CaseIterable, Equatable, Sendable {
    case reset
    case nothingToReset
    case noCredit
    case alreadyRedeemed
}

public struct RPCConsumeResetResponse: Codable, Equatable, Sendable {
    public let outcome: RPCConsumeResetOutcome

    public init(outcome: RPCConsumeResetOutcome) {
        self.outcome = outcome
    }
}

public struct RPCLoginCompletedNotification: Codable, Equatable, Sendable {
    public let loginID: String?
    public let success: Bool
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case loginID = "loginId"
        case success
        case error
    }

    public init(loginID: String?, success: Bool, error: String?) {
        self.loginID = loginID
        self.success = success
        self.error = error
    }
}

public struct RPCAccountUpdatedNotification: Codable, Equatable, Sendable {
    public let authMode: String?
    public let planType: String?

    public init(authMode: String?, planType: String?) {
        self.authMode = authMode
        self.planType = planType
    }
}

public enum AppServerNotification: Equatable, Sendable {
    case loginCompleted(RPCLoginCompletedNotification)
    case accountUpdated(RPCAccountUpdatedNotification)
    case rateLimitsUpdated(RPCRateLimitSnapshot)
    case unhandled(method: String)
}

/// Injectable newline-delimited JSON transport. Production uses a child process; tests can use
/// a deterministic fixture transport without starting Codex or touching authentication state.
public protocol AppServerTransport: Sendable {
    func start() async throws
    func send(_ message: Data) async throws
    func receive() async throws -> Data?
    func stop() async
}

public typealias AppServerTransportFactory = @Sendable () -> any AppServerTransport

// MARK: - Core-domain adapters

extension RPCRateLimitWindow {
    public func domainValue() -> RateLimitWindow {
        RateLimitWindow(
            usedPercent: Double(usedPercent),
            windowDurationMinutes: windowDurationMinutes.map(Double.init),
            resetsAt: resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

extension RPCRateLimitSnapshot {
    public func domainValue(observedAt: Date) -> RateLimitSnapshot {
        RateLimitSnapshot(
            limitID: limitID,
            limitName: limitName,
            primary: primary?.domainValue(),
            secondary: secondary?.domainValue(),
            observedAt: observedAt
        )
    }
}

extension RPCResetCredit {
    public func domainValue() -> ResetCredit {
        let kind: ResetCreditKind = resetType == "codexRateLimits"
            ? .codexRateLimits
            : .unknown(resetType)
        let mappedStatus: ResetCreditStatus
        switch status {
        case "available": mappedStatus = .available
        case "redeeming": mappedStatus = .redeeming
        case "redeemed": mappedStatus = .redeemed
        default: mappedStatus = .unknown(status)
        }

        return ResetCredit(
            id: id,
            kind: kind,
            status: mappedStatus,
            grantedAt: Date(timeIntervalSince1970: TimeInterval(grantedAt)),
            expiresAt: expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            title: title,
            detail: detail
        )
    }
}

extension RPCResetCreditsSummary {
    public func domainValue() -> ResetCreditInventory {
        ResetCreditInventory(
            availableCount: Int(availableCount),
            credits: credits?.map { $0.domainValue() }
        )
    }
}

extension RPCConsumeResetOutcome {
    public var domainValue: ConsumeResetOutcome {
        switch self {
        case .reset: .reset
        case .nothingToReset: .nothingToReset
        case .noCredit: .noCredit
        case .alreadyRedeemed: .alreadyRedeemed
        }
    }
}
