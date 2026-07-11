import Foundation
import Testing
import VibeUsageCore
@testable import VibeUsageQuota

@MainActor
@Suite struct QuotaConnectionManagerTests {
    private static func tokenJSON(accessToken: String, refreshToken: String? = "refresh", expiresIn: Double = 3600) -> Data {
        var fields = ["\"access_token\":\"\(accessToken)\"", "\"expires_in\":\(expiresIn)"]
        if let refreshToken {
            fields.append("\"refresh_token\":\"\(refreshToken)\"")
        }
        return Data("{\(fields.joined(separator: ","))}".utf8)
    }

    private static func base64URL(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func jwt(_ payload: String) -> String {
        "eyJhbGciOiJub25lIn0." + base64URL(payload) + ".signature"
    }

    // MARK: - validAccessToken

    @Test func validAccessTokenReturnsNilWhenNotConnected() async {
        let manager = QuotaConnectionManager(store: InMemoryConnectedAccountStore(), claudeCredentialReader: FakeClaudeCredentialReader(credential: nil))
        let token = await manager.validAccessToken(for: .claudeQuota)
        #expect(token == nil)
        #expect(manager.isConnected(.claudeQuota) == false)
    }

    @Test func validAccessTokenReturnsStoredTokenWhenFarFromExpiry() async {
        let store = InMemoryConnectedAccountStore()
        store.save(
            ConnectedAccount(accessToken: "fresh-token", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3600)),
            for: .claudeQuota
        )
        let manager = QuotaConnectionManager(store: store, claudeCredentialReader: FakeClaudeCredentialReader(credential: nil))
        let token = await manager.validAccessToken(for: .claudeQuota)
        #expect(token == "fresh-token")
        #expect(manager.isConnected(.claudeQuota))
    }

    @Test func repeatedAccountLookupsHitStoreOnlyOncePerProvider() async {
        let store = CountingConnectedAccountStore()
        store.save(
            ConnectedAccount(accessToken: "fresh-token", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3600)),
            for: .claudeQuota
        )
        let manager = QuotaConnectionManager(store: store, claudeCredentialReader: FakeClaudeCredentialReader(credential: nil))

        _ = manager.isConnected(.claudeQuota)
        _ = manager.subscriptionTier(for: .claudeQuota)
        _ = await manager.validAccessToken(for: .claudeQuota)

        #expect(store.loadCount(for: .claudeQuota) == 1)
        #expect(store.loadAllCount == 0)
    }

    @Test func validAccessTokenRefreshesWhenNearExpiry() async {
        let store = InMemoryConnectedAccountStore()
        store.save(
            ConnectedAccount(accessToken: "stale-token", refreshToken: "refresh-me", expiresAt: Date().addingTimeInterval(30)),
            for: .claudeQuota
        )
        let fetcher = FakeHTTPFetcher(result: .success((Self.tokenJSON(accessToken: "new-token"), 200)))
        let manager = QuotaConnectionManager(store: store, tokenClient: OAuthTokenClient(fetcher: fetcher), claudeCredentialReader: FakeClaudeCredentialReader(credential: nil))

        let token = await manager.validAccessToken(for: .claudeQuota)

        #expect(token == "new-token")
        #expect(store.load(.claudeQuota)?.accessToken == "new-token")
    }

    /// Codex refresh responses can carry a fresh `id_token` with an updated
    /// `chatgpt_plan_type` (e.g. the user upgraded plans) — the merged
    /// account should pick that up rather than freezing the tier at whatever
    /// it was when first connected.
    @Test func validAccessTokenUpdatesSubscriptionTierFromRefreshedIDToken() async {
        let store = InMemoryConnectedAccountStore()
        store.save(
            ConnectedAccount(
                accessToken: "stale-token",
                refreshToken: "refresh-me",
                expiresAt: Date().addingTimeInterval(30),
                subscriptionType: "free"
            ),
            for: .codexQuota
        )
        let idToken = Self.jwt(#"{"chatgpt_plan_type":"pro"}"#)
        let responseJSON = Data(#"{"access_token":"new-token","refresh_token":"r2","expires_in":3600,"id_token":"\#(idToken)"}"#.utf8)
        let fetcher = FakeHTTPFetcher(result: .success((responseJSON, 200)))
        let manager = QuotaConnectionManager(store: store, tokenClient: OAuthTokenClient(fetcher: fetcher), claudeCredentialReader: FakeClaudeCredentialReader(credential: nil))

        _ = await manager.validAccessToken(for: .codexQuota)

        #expect(manager.subscriptionTier(for: .codexQuota) == "pro")
    }

    @Test func validAccessTokenClearsAccountAndReturnsNilWhenRefreshFails() async {
        let store = InMemoryConnectedAccountStore()
        store.save(
            ConnectedAccount(accessToken: "stale-token", refreshToken: "refresh-me", expiresAt: Date().addingTimeInterval(1)),
            for: .codexQuota
        )
        let fetcher = FakeHTTPFetcher(result: .success((Data("{}".utf8), 401)))
        let manager = QuotaConnectionManager(store: store, tokenClient: OAuthTokenClient(fetcher: fetcher), claudeCredentialReader: FakeClaudeCredentialReader(credential: nil))

        let token = await manager.validAccessToken(for: .codexQuota)

        #expect(token == nil)
        #expect(store.load(.codexQuota) == nil)
        #expect(manager.isConnected(.codexQuota) == false)
    }

    @Test func validAccessTokenReturnsNilWhenNoRefreshTokenAvailableAndExpired() async {
        let store = InMemoryConnectedAccountStore()
        store.save(
            ConnectedAccount(accessToken: "stale-token", refreshToken: nil, expiresAt: Date().addingTimeInterval(1)),
            for: .claudeQuota
        )
        let manager = QuotaConnectionManager(store: store, claudeCredentialReader: FakeClaudeCredentialReader(credential: nil))
        let token = await manager.validAccessToken(for: .claudeQuota)
        #expect(token == nil)
        #expect(store.load(.claudeQuota) == nil)
    }

    // MARK: - disconnect

    @Test func disconnectClearsStoredAccount() async {
        let store = InMemoryConnectedAccountStore()
        store.save(ConnectedAccount(accessToken: "tok", refreshToken: nil, expiresAt: Date().addingTimeInterval(3600)), for: .claudeQuota)
        let manager = QuotaConnectionManager(store: store, claudeCredentialReader: FakeClaudeCredentialReader(credential: nil))

        manager.disconnect(.claudeQuota)

        #expect(manager.isConnected(.claudeQuota) == false)
        #expect(store.load(.claudeQuota) == nil)
    }

    // MARK: - Claude import-from-CLI flow

    @Test func connectClaudeImportsCLICredential() async throws {
        let store = InMemoryConnectedAccountStore()
        let reader = FakeClaudeCredentialReader(credential: ClaudeCLICredential(
            accessToken: "cli-token",
            refreshToken: "cli-refresh",
            expiresAt: Date().addingTimeInterval(3600),
            subscriptionType: "max"
        ))
        let manager = QuotaConnectionManager(store: store, claudeCredentialReader: reader)

        try await manager.connect(.claudeQuota)

        #expect(manager.isConnected(.claudeQuota))
        #expect(store.load(.claudeQuota)?.accessToken == "cli-token")
    }

    @Test func connectClaudeThrowsWhenNotLoggedIn() async {
        let manager = QuotaConnectionManager(
            store: InMemoryConnectedAccountStore(),
            claudeCredentialReader: FakeClaudeCredentialReader(credential: nil)
        )

        await #expect(throws: QuotaConnectionError.claudeNotLoggedIn) {
            try await manager.connect(.claudeQuota)
        }
    }

    /// `validAccessToken` must never touch Claude Code's own keychain item for
    /// an already-connected account — only `connect(_:)` (an explicit user
    /// action) does. Otherwise every launch/periodic poll would re-prompt for
    /// keychain access, which is exactly the regression being guarded here.
    @Test func claudeValidAccessTokenNeverReadsCLIWhenAlreadyFresh() async {
        let store = InMemoryConnectedAccountStore()
        store.save(
            ConnectedAccount(accessToken: "imported-token", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600)),
            for: .claudeQuota
        )
        let reader = RecordingClaudeCredentialReader(credential: ClaudeCLICredential(
            accessToken: "cli-fresh",
            refreshToken: "r2",
            expiresAt: Date().addingTimeInterval(3600),
            subscriptionType: nil
        ))
        let manager = QuotaConnectionManager(store: store, claudeCredentialReader: reader)

        let token = await manager.validAccessToken(for: .claudeQuota)

        #expect(token == "imported-token")
        #expect(reader.readCount == 0)
    }

    /// Only an expired stored token triggers Anthropic's own refresh grant —
    /// still never touching Claude Code's keychain item.
    @Test func claudeValidAccessTokenRefreshesViaAnthropicNotCLIWhenExpired() async {
        let store = InMemoryConnectedAccountStore()
        store.save(
            ConnectedAccount(accessToken: "stale", refreshToken: "refresh-me", expiresAt: Date().addingTimeInterval(1)),
            for: .claudeQuota
        )
        let fetcher = FakeHTTPFetcher(result: .success((Self.tokenJSON(accessToken: "refreshed-via-anthropic"), 200)))
        let reader = RecordingClaudeCredentialReader(credential: nil)
        let manager = QuotaConnectionManager(
            store: store,
            tokenClient: OAuthTokenClient(fetcher: fetcher),
            claudeCredentialReader: reader
        )

        let token = await manager.validAccessToken(for: .claudeQuota)

        #expect(token == "refreshed-via-anthropic")
        #expect(reader.readCount == 0)
    }
}

final class RecordingClaudeCredentialReader: ClaudeCLICredentialReading, @unchecked Sendable {
    let credential: ClaudeCLICredential?
    private(set) var readCount = 0

    init(credential: ClaudeCLICredential?) { self.credential = credential }

    func read() -> ClaudeCLICredential? {
        readCount += 1
        return credential
    }
}

struct FakeClaudeCredentialReader: ClaudeCLICredentialReading {
    let credential: ClaudeCLICredential?
    func read() -> ClaudeCLICredential? { credential }
}

final class CountingConnectedAccountStore: ConnectedAccountStoring, @unchecked Sendable {
    private var accounts: [AgentSourceID: ConnectedAccount] = [:]
    private var loadCounts: [AgentSourceID: Int] = [:]
    private(set) var loadAllCount = 0
    var totalLoadCount: Int { loadCounts.values.reduce(0, +) }

    func load(_ provider: AgentSourceID) -> ConnectedAccount? {
        loadCounts[provider, default: 0] += 1
        return accounts[provider]
    }

    func loadAllAccounts() -> [AgentSourceID: ConnectedAccount] {
        loadAllCount += 1
        return accounts
    }

    func save(_ account: ConnectedAccount, for provider: AgentSourceID) {
        accounts[provider] = account
    }

    func clear(_ provider: AgentSourceID) {
        accounts.removeValue(forKey: provider)
    }

    func loadCount(for provider: AgentSourceID) -> Int {
        loadCounts[provider, default: 0]
    }
}
