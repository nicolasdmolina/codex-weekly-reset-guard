import Darwin
import Foundation

/// Moves the runtime directory of the pre-rename app ("Codex Weekly Reset Guard") into place.
///
/// The whole directory moves in one `rename`, so profiles, isolated Codex homes, history and any
/// durable pending reset attempt (including its idempotency key) arrive together or not at all.
/// The legacy app's single-instance lock is held for the duration, so a running legacy app makes
/// the migration wait for the next launch instead of moving state out from under it.
public enum LegacyStateMigration {
    public enum Outcome: Equatable, Sendable {
        case notNeeded
        case migrated
        /// The legacy app is still running and owns its directory.
        case legacyAppRunning
    }

    /// Text left at the legacy path. A plain file there makes the legacy app fail at startup
    /// (its runtime directory cannot be created), so a stale login item cannot relaunch it
    /// against an empty state.
    static let tombstoneContents = """
    This app was renamed to Second Wind. Its data moved to ~/Library/Application Support/SecondWind.

    """

    public static func migrateIfNeeded(
        legacyDirectory: URL = ProfileConfiguration.legacyApplicationSupportDirectory,
        currentDirectory: URL = ProfileConfiguration.defaultApplicationSupportDirectory,
        fileManager: FileManager = .default
    ) throws -> Outcome {
        let legacy = legacyDirectory.standardizedFileURL
        let current = currentDirectory.standardizedFileURL
        guard !entryExists(at: current) else { return .notNeeded }
        guard isRealDirectory(legacy) else { return .notNeeded }

        let lock: SingleInstanceLock
        do {
            lock = try SingleInstanceLock(
                url: legacy.appendingPathComponent("guard.lock", isDirectory: false)
            )
        } catch SingleInstanceError.alreadyRunning {
            return .legacyAppRunning
        }

        try withExtendedLifetime(lock) {
            try PrivateFileIO.ensurePrivateDirectory(current.deletingLastPathComponent())
            guard Darwin.rename(legacy.path, current.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        // The move has already succeeded; a missing tombstone only weakens the stale-login guard.
        let created = fileManager.createFile(
            atPath: legacy.path,
            contents: Data(tombstoneContents.utf8),
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        )
        _ = created
        return .migrated
    }

    private static func entryExists(at url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0 && status.st_mode & S_IFMT == S_IFDIR
    }
}
