import Foundation
import Security
import VibeUsageCore

/// Persisted OAuth state for one connected provider account — entirely
/// VibeUsage's own tokens, never the CLI's.
public struct ConnectedAccount: Sendable, Equatable, Codable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public let accountID: String?
    public let subscriptionType: String?

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date,
        accountID: String? = nil,
        subscriptionType: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountID = accountID
        self.subscriptionType = subscriptionType
    }
}

/// Storage seam for VibeUsage's own connected-account tokens, keyed by
/// provider. Implementations must never read or write anything belonging to
/// the Claude Code CLI or Codex CLI's own credential storage.
public protocol ConnectedAccountStoring: Sendable {
    func load(_ provider: AgentSourceID) -> ConnectedAccount?
    func save(_ account: ConnectedAccount, for provider: AgentSourceID)
    func clear(_ provider: AgentSourceID)
}

/// Keychain-backed implementation: one generic-password item per provider,
/// under a service string exclusively owned by VibeUsage
/// (`"VibeUsage-connected-accounts"`), account = provider id
/// (e.g. `"claude-code"`, `"codex-cli"`). Never touches the
/// `"Claude Code-credentials"` keychain item or `~/.codex/auth.json` — this
/// is an entirely separate credential namespace.
public struct KeychainConnectedAccountStore: ConnectedAccountStoring {
    private static let service = "VibeUsage-connected-accounts"

    public init() {}

    public func load(_ provider: AgentSourceID) -> ConnectedAccount? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        query.removeAll()
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(ConnectedAccount.self, from: data)
    }

    public func save(_ account: ConnectedAccount, for provider: AgentSourceID) {
        guard let data = try? JSONEncoder().encode(account) else { return }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: provider.rawValue
        ]

        // Delete-then-add is simpler and adequate here (single-writer,
        // low-frequency token refresh) than update-with-fallback-to-add.
        SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    public func clear(_ provider: AgentSourceID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: provider.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }
}
