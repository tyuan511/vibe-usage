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
    func loadAllAccounts() -> [AgentSourceID: ConnectedAccount]
}

extension ConnectedAccountStoring {
    public func loadAllAccounts() -> [AgentSourceID: ConnectedAccount] {
        var accounts: [AgentSourceID: ConnectedAccount] = [:]
        for provider in [AgentSourceID.claudeQuota, .codexQuota] {
            if let account = load(provider) {
                accounts[provider] = account
            }
        }
        return accounts
    }
}

/// Keychain-backed implementation: all connected accounts live in a single
/// generic-password item under service `"VibeUsage-connected-accounts"` so
/// startup only needs one keychain access (one user prompt) regardless of
/// how many providers are connected. Legacy per-provider items are migrated
/// automatically on first read.
public struct KeychainConnectedAccountStore: ConnectedAccountStoring {
    private static let service = "VibeUsage-connected-accounts"
    private static let bundleAccount = "connected-accounts"
    private static let legacyProviders: [AgentSourceID] = [.claudeQuota, .codexQuota]

    public init() {}

    public func load(_ provider: AgentSourceID) -> ConnectedAccount? {
        bundle()[provider.rawValue]
    }

    public func loadAllAccounts() -> [AgentSourceID: ConnectedAccount] {
        let raw = bundle()
        var accounts: [AgentSourceID: ConnectedAccount] = [:]
        for provider in Self.legacyProviders {
            if let account = raw[provider.rawValue] {
                accounts[provider] = account
            }
        }
        return accounts
    }

    public func save(_ account: ConnectedAccount, for provider: AgentSourceID) {
        var all = bundle()
        all[provider.rawValue] = account
        writeBundle(all)
    }

    public func clear(_ provider: AgentSourceID) {
        var all = bundle()
        all.removeValue(forKey: provider.rawValue)
        writeBundle(all)
    }

    private func bundle() -> [String: ConnectedAccount] {
        KeychainBundleCache.shared.get {
            readBundleFromKeychain()
        }
    }

    private func writeBundle(_ bundle: [String: ConnectedAccount]) {
        writeBundleToKeychain(bundle)
        KeychainBundleCache.shared.update(bundle)
    }

    private func readBundleFromKeychain() -> [String: ConnectedAccount] {
        if let bundled = readKeychainItem(account: Self.bundleAccount),
           let accounts = try? JSONDecoder().decode([String: ConnectedAccount].self, from: bundled) {
            return accounts
        }

        var migrated: [String: ConnectedAccount] = [:]
        for provider in Self.legacyProviders {
            guard let data = readKeychainItem(account: provider.rawValue),
                  let account = try? JSONDecoder().decode(ConnectedAccount.self, from: data) else {
                continue
            }
            migrated[provider.rawValue] = account
            deleteKeychainItem(account: provider.rawValue)
        }

        if !migrated.isEmpty {
            writeBundleToKeychain(migrated)
        }
        return migrated
    }

    private func writeBundleToKeychain(_ bundle: [String: ConnectedAccount]) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.bundleAccount
        ]

        if bundle.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }

        guard let data = try? JSONEncoder().encode(bundle) else { return }

        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func readKeychainItem(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    private func deleteKeychainItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private final class KeychainBundleCache: @unchecked Sendable {
    static let shared = KeychainBundleCache()

    private let lock = NSLock()
    private var bundle: [String: ConnectedAccount]?
    private var isLoaded = false

    func get(_ loader: () -> [String: ConnectedAccount]) -> [String: ConnectedAccount] {
        lock.lock()
        defer { lock.unlock() }
        if isLoaded, let bundle {
            return bundle
        }
        let loaded = loader()
        bundle = loaded
        isLoaded = true
        return loaded
    }

    func update(_ bundle: [String: ConnectedAccount]) {
        lock.lock()
        defer { lock.unlock() }
        self.bundle = bundle
        isLoaded = true
    }
}
