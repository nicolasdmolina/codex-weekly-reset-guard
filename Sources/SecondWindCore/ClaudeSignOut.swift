import Foundation

extension ClaudeCLI {
    /// Signs one app-owned profile out through the official `claude auth logout`.
    ///
    /// Claude Code keys its Keychain item by a hash of `CLAUDE_CONFIG_DIR`, and the runner always
    /// sets that variable to the profile's own folder with every inherited `CLAUDE_*` value
    /// removed, so this only touches that profile's sign-in. Second Wind never reads the item.
    /// Returns true only when Claude Code reports success.
    public func signOut(configDirectory: URL) async throws -> Bool {
        let output = try await runner.run(
            arguments: ["auth", "logout"],
            configDirectory: configDirectory,
            timeout: commandTimeout
        )
        return output.status == 0
    }
}
