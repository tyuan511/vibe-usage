import Foundation
import Security

/// The OAuth credential Claude Code itself stores locally. Anthropic enforces
/// (server-side, since Jan 2026) that consumer-plan OAuth tokens only work
/// when they were minted by Claude Code / Claude.ai — a third-party app can't
/// mint its own via the OAuth authorize flow (it 403s). So, like CodexBar,
/// VibeUsage reuses the token Claude Code already holds rather than running
/// its own Claude authorize flow. VibeUsage only ever READS this credential;
/// it never writes back to Claude Code's storage.
public struct ClaudeCLICredential: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let subscriptionType: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date?, subscriptionType: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
    }
}

/// Read seam so tests can inject a fake credential without touching the real
/// keychain / home directory.
public protocol ClaudeCLICredentialReading: Sendable {
    /// Returns the current Claude Code credential, or `nil` when Claude Code
    /// isn't logged in (no item, or an empty access token).
    func read() -> ClaudeCLICredential?
}

/// Reads the `Claude Code-credentials` generic-password keychain item (payload
/// shape `{ "claudeAiOauth": { accessToken, refreshToken, expiresAt, ... } }`),
/// falling back to `~/.claude/.credentials.json` (same shape). Read-only.
///
/// The credentials file is tried first so connecting Claude doesn't trigger a
/// cross-app keychain prompt when Claude Code already wrote the token to disk.
public struct KeychainClaudeCLICredentialReader: ClaudeCLICredentialReading {
    private static let keychainService = "Claude Code-credentials"

    private let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public func read() -> ClaudeCLICredential? {
        if let fromFile = readFromFile() { return fromFile }
        return readFromKeychain()
    }

    private func readFromKeychain() -> ClaudeCLICredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return Self.parse(data)
    }

    private func readFromFile() -> ClaudeCLICredential? {
        let url = homeDirectory.appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Self.parse(data)
    }

    static func parse(_ data: Data) -> ClaudeCLICredential? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              !accessToken.isEmpty else {
            return nil
        }
        let refreshToken = (oauth["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // Claude stores `expiresAt` as a millisecond epoch; 0 means "unset".
        let expiresAt: Date?
        if let ms = oauth["expiresAt"] as? Double, ms > 0 {
            expiresAt = Date(timeIntervalSince1970: ms / 1000)
        } else {
            expiresAt = nil
        }
        return ClaudeCLICredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }
}
