import Foundation

public struct DiscoveredCodexIdentity: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let email: String
    public let displayName: String

    public init(id: String, email: String, displayName: String) {
        self.id = id
        self.email = email
        self.displayName = displayName
    }
}

public enum CodexBarProfileDiscovery {
    public static var defaultRegistryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexBar/managed-codex-accounts.json")
    }

    public static func discover(from registryURL: URL = defaultRegistryURL) throws -> [DiscoveredCodexIdentity] {
        let data = try Data(contentsOf: registryURL)
        let registry = try JSONDecoder().decode(Registry.self, from: data)

        var seen = Set<String>()
        return registry.accounts.compactMap { account in
            let email = account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !email.isEmpty, seen.insert(email).inserted else { return nil }

            let localPart = email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? "Codex"
            let displayName = localPart
                .replacingOccurrences(of: ".", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")

            return DiscoveredCodexIdentity(
                id: account.providerAccountID.isEmpty ? account.id : account.providerAccountID,
                email: email,
                displayName: displayName.isEmpty ? "Codex Profile" : displayName
            )
        }
    }

    private struct Registry: Decodable {
        let accounts: [Account]
    }

    private struct Account: Decodable {
        let id: String
        let email: String
        let providerAccountID: String
    }
}
