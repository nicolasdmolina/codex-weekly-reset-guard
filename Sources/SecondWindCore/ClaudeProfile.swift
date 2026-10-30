import Foundation

/// A Claude account watched by Second Wind. Each one signs in to Claude Code inside its own
/// app-owned configuration directory, derived from the UUID so persisted state can never point
/// the app at the user's main `~/.claude`.
public struct ClaudeProfileConfiguration: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public var displayName: String
    public var expectedEmail: String?
    public var alertsEnabled: Bool

    public init(
        id: UUID = UUID(),
        displayName: String,
        expectedEmail: String? = nil,
        alertsEnabled: Bool = true,
        schemaVersion: Int = currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.expectedEmail = expectedEmail
        self.alertsEnabled = alertsEnabled
    }

    public static func defaultRootDirectory(
        applicationSupportDirectory: URL = ProfileConfiguration.defaultApplicationSupportDirectory
    ) -> URL {
        applicationSupportDirectory.appendingPathComponent("claude", isDirectory: true)
    }

    public func configDirectoryURL(root: URL) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true).standardizedFileURL
    }

    @discardableResult
    public func prepareConfigDirectory(root: URL) throws -> URL {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ProfileConfigurationError.unsupportedSchemaVersion(schemaVersion)
        }
        let directory = configDirectoryURL(root: root)
        try PrivateFileIO.ensurePrivateDirectory(root.standardizedFileURL)
        try PrivateFileIO.ensurePrivateDirectory(directory)
        return directory
    }
}

/// Last known state of one Claude profile.
public struct ClaudeProfileState: Codable, Equatable, Sendable {
    public var lastReport: ClaudeUsageReport?
    public var verifiedEmail: String?
    public var planName: String?
    /// Set when Claude Code stopped answering `/usage` locally. Polling stays off until the user
    /// reconnects, so a changed CLI can never spend plan usage in the background.
    public var monitoringStopped: Bool

    public init(
        lastReport: ClaudeUsageReport? = nil,
        verifiedEmail: String? = nil,
        planName: String? = nil,
        monitoringStopped: Bool = false
    ) {
        self.lastReport = lastReport
        self.verifiedEmail = verifiedEmail
        self.planName = planName
        self.monitoringStopped = monitoringStopped
    }
}

public struct ClaudePersistentState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumRememberedAlerts = 64

    public let schemaVersion: Int
    public var profiles: [ClaudeProfileConfiguration]
    public var states: [String: ClaudeProfileState]
    /// Alert keys already delivered, oldest first.
    public var sentAlertKeys: [String]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        profiles: [ClaudeProfileConfiguration] = [],
        states: [String: ClaudeProfileState] = [:],
        sentAlertKeys: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.states = states
        self.sentAlertKeys = sentAlertKeys
    }

    public static func key(for id: UUID) -> String { id.uuidString.lowercased() }

    public func state(for id: UUID) -> ClaudeProfileState {
        states[Self.key(for: id)] ?? ClaudeProfileState()
    }

    public mutating func setState(_ state: ClaudeProfileState, for id: UUID) {
        states[Self.key(for: id)] = state
    }

    public mutating func rememberAlerts(_ keys: [String]) {
        for key in keys where !sentAlertKeys.contains(key) {
            sentAlertKeys.append(key)
        }
        if sentAlertKeys.count > Self.maximumRememberedAlerts {
            sentAlertKeys.removeFirst(sentAlertKeys.count - Self.maximumRememberedAlerts)
        }
    }
}
