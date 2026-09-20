import Foundation

public struct ProfileConfiguration: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public var displayName: String
    public var expectedEmail: String?
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        displayName: String,
        expectedEmail: String? = nil,
        isEnabled: Bool = false,
        schemaVersion: Int = currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.expectedEmail = expectedEmail
        self.isEnabled = isEnabled
    }

    public static var defaultApplicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexWeeklyResetGuard", isDirectory: true)
    }

    public static var defaultProfilesDirectory: URL {
        defaultApplicationSupportDirectory.appendingPathComponent("profiles", isDirectory: true)
    }

    public func codexHomeURL(
        profilesDirectory: URL = ProfileConfiguration.defaultProfilesDirectory
    ) -> URL {
        profilesDirectory
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
            .standardizedFileURL
    }

    /// Creates the app-owned Codex home and its non-secret configuration.
    ///
    /// The path is derived from the profile UUID instead of being loaded from persisted state, so
    /// a modified profile file cannot redirect the app toward an existing Codex credential store.
    @discardableResult
    public func prepareCodexHome(
        profilesDirectory: URL = ProfileConfiguration.defaultProfilesDirectory,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ProfileConfigurationError.unsupportedSchemaVersion(schemaVersion)
        }

        let profilesRoot = profilesDirectory.standardizedFileURL
        let codexHome = codexHomeURL(profilesDirectory: profilesRoot)
        try createPrivateDirectory(profilesRoot, fileManager: fileManager)
        try createPrivateDirectory(codexHome, fileManager: fileManager)

        let configURL = codexHome.appendingPathComponent("config.toml", isDirectory: false)
        let config = """
        cli_auth_credentials_store = "file"

        [history]
        persistence = "none"
        """
        try PrivateFileIO.atomicWrite(Data((config + "\n").utf8), to: configURL)
        return codexHome
    }

    private func createPrivateDirectory(_ url: URL, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ProfileConfigurationError.pathIsNotDirectory(url)
            }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw ProfileConfigurationError.symbolicLink(url)
            }
        } else {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: url.path
        )
    }
}

public enum ProfileConfigurationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case pathIsNotDirectory(URL)
    case symbolicLink(URL)
}
