import Foundation

/// One enrolled account, identified by provider and the app's own profile UUID. It carries no
/// email or display name, so it is safe to put in notification payloads and logs.
struct AccountRef: Hashable, Sendable, CustomStringConvertible {
    let provider: ProviderKind
    let id: UUID

    init(provider: ProviderKind, id: UUID) {
        self.provider = provider
        self.id = id
    }

    /// Parses a presentation identifier, which is a UUID string.
    init?(provider: ProviderKind, rawID: String) {
        guard let id = UUID(uuidString: rawID) else { return nil }
        self.init(provider: provider, id: id)
    }

    /// "codex:<lowercased uuid>".
    var token: String { "\(provider.rawValue):\(id.uuidString.lowercased())" }

    init?(token: String) {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let provider = ProviderKind(rawValue: parts[0]),
              let id = UUID(uuidString: parts[1])
        else { return nil }
        self.init(provider: provider, id: id)
    }

    var description: String { token }
}
