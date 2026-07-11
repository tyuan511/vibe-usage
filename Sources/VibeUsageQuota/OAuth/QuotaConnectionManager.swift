import AppKit
import Foundation
import VibeUsageCore

public enum QuotaConnectionError: Error, Equatable, LocalizedError {
    case stateMismatch
    case notConnected
    /// Claude: no Claude Code login found on this machine to reuse.
    case claudeNotLoggedIn

    public var errorDescription: String? {
        switch self {
        case .stateMismatch:
            VibeUsageStrings.text(zh: "授权响应与发起请求不匹配", en: "The authorization response didn't match the request that started it")
        case .notConnected:
            VibeUsageStrings.text(zh: "该账号未连接", en: "This account isn't connected")
        case .claudeNotLoggedIn:
            VibeUsageStrings.text(zh: "未检测到 Claude Code 登录，请先在 Claude Code 中登录后再连接", en: "Sign in to Claude Code first, then try connecting again")
        }
    }
}

/// Orchestrates connecting quota providers, refreshing tokens, and
/// disconnecting. The two providers differ fundamentally: Codex mints
/// VibeUsage's own token via a loopback OAuth flow, while Claude reuses the
/// token Claude Code already holds (Anthropic blocks third-party token
/// minting). For Codex this manager owns tokens in ``ConnectedAccountStoring``
/// (a VibeUsage-only keychain namespace); for Claude it reads Claude Code's
/// existing credential read-only and never writes back to it.
@MainActor
public final class QuotaConnectionManager {
    private let store: any ConnectedAccountStoring
    private let tokenClient: OAuthTokenClient
    private let claudeCredentialReader: any ClaudeCLICredentialReading
    private let loopbackServerFactory: @Sendable (Int, String) -> LoopbackCallbackServer
    private let browserOpener: @Sendable (URL) -> Void
    private let now: @Sendable () -> Date

    /// Providers whose refresh attempt has already failed once this app
    /// session — `validAccessToken` treats these as unauthorized without
    /// retrying the refresh every call.
    private var flaggedUnauthorized: Set<AgentSourceID> = []

    /// Lazily populated in-memory mirror of ``ConnectedAccountStoring`` so
    /// disabled quota monitoring never touches the keychain, while enabled
    /// polling still avoids repeated reads.
    private var accountCache: [AgentSourceID: ConnectedAccount] = [:]
    private var accountCachePrimed: Set<AgentSourceID> = []

    public init(
        store: any ConnectedAccountStoring = KeychainConnectedAccountStore(),
        tokenClient: OAuthTokenClient = OAuthTokenClient(),
        claudeCredentialReader: any ClaudeCLICredentialReading = KeychainClaudeCLICredentialReader(),
        loopbackServerFactory: @escaping @Sendable (Int, String) -> LoopbackCallbackServer = { port, path in
            LoopbackCallbackServer(port: port, path: path)
        },
        browserOpener: @escaping @Sendable (URL) -> Void = { url in NSWorkspace.shared.open(url) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.tokenClient = tokenClient
        self.claudeCredentialReader = claudeCredentialReader
        self.loopbackServerFactory = loopbackServerFactory
        self.browserOpener = browserOpener
        self.now = now
    }

    public func isConnected(_ provider: AgentSourceID) -> Bool {
        cachedAccount(for: provider) != nil
    }

    /// The stored `ChatGPT-Account-Id` (Codex only) for the given provider,
    /// if any was captured from the `id_token` during connect/refresh.
    public func accountID(for provider: AgentSourceID) -> String? {
        cachedAccount(for: provider)?.accountID
    }

    /// The account's subscription tier, whatever granularity the upstream
    /// data actually gives us — Claude's `subscriptionType` from the imported
    /// CLI credential (e.g. `"free"`/`"pro"`/`"max"`), or Codex's
    /// `chatgpt_plan_type` id_token claim (e.g. `"free"`/`"go"`/`"plus"`/
    /// `"pro"`). Neither source is known to expose a finer split (Claude's
    /// Max 5x vs 20x multiplier, or a Codex "pro 5x/20x" tier) — this
    /// surfaces exactly what's available rather than guessing the rest.
    public func subscriptionTier(for provider: AgentSourceID) -> String? {
        cachedAccount(for: provider)?.subscriptionType
    }

    /// Connects a provider. Codex runs the automatic loopback OAuth flow
    /// (opens the browser, awaits the local callback, exchanges the code).
    /// Claude imports Claude Code's existing credential (no browser step);
    /// throws `.claudeNotLoggedIn` when Claude Code isn't signed in. Callers
    /// should show a spinner for the (brief) Codex browser round-trip.
    public func connect(_ provider: AgentSourceID) async throws {
        let config = config(for: provider)
        switch config.callbackStyle {
        case .loopback(let port, let path):
            let pkce = OAuthPKCE.generate()
            let state = OAuthPKCE.generateVerifier()
            let authorizeURL = config.authorizeURL(codeChallenge: pkce.challenge, state: state)

            let server = loopbackServerFactory(port, path)
            async let callbackTask = server.awaitCallback()

            browserOpener(authorizeURL)

            let callback = try await callbackTask
            guard callback.state == state else {
                throw QuotaConnectionError.stateMismatch
            }

            let tokens = try await tokenClient.exchange(code: callback.code, verifier: pkce.verifier, state: state, config: config)
            persist(tokens, for: provider)

        case .importFromCLI:
            guard let credential = claudeCredentialReader.read() else {
                throw QuotaConnectionError.claudeNotLoggedIn
            }
            flaggedUnauthorized.remove(provider)
            let account = ConnectedAccount(
                accessToken: credential.accessToken,
                refreshToken: credential.refreshToken,
                expiresAt: credential.expiresAt ?? now(),
                accountID: nil,
                subscriptionType: credential.subscriptionType
            )
            store.save(account, for: provider)
            setCachedAccount(account, for: provider)
        }
    }

    public func disconnect(_ provider: AgentSourceID) {
        store.clear(provider)
        clearCachedAccount(for: provider)
        flaggedUnauthorized.remove(provider)
    }

    /// Returns a valid access token for `provider`, transparently refreshing
    /// it if it's within 60s of expiry (or already flagged unauthorized this
    /// session isn't retried — callers should `disconnect`/prompt reconnect
    /// instead). Returns `nil` if not connected or refresh fails (clearing
    /// the stored tokens and flagging unauthorized in the latter case). Only
    /// ever touches our own stored copy — Claude Code's keychain item is read
    /// exactly once, at `connect(_:)` time (an explicit user action), never on
    /// every launch/periodic poll. If our copy's refresh eventually fails
    /// (`markUnauthorized`), the UI prompts to reconnect, which re-imports a
    /// fresh token from Claude Code.
    public func validAccessToken(for provider: AgentSourceID) async -> String? {
        guard let account = cachedAccount(for: provider) else { return nil }
        guard !flaggedUnauthorized.contains(provider) else { return nil }

        let needsRefresh = account.expiresAt.timeIntervalSince(now()) < 60
        guard needsRefresh else { return account.accessToken }

        guard let refreshToken = account.refreshToken else {
            markUnauthorized(provider)
            return nil
        }

        do {
            let config = config(for: provider)
            let refreshed = try await tokenClient.refresh(refreshToken: refreshToken, config: config)
            let merged = ConnectedAccount(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken ?? refreshToken,
                expiresAt: refreshed.expiresAt,
                accountID: refreshed.accountID ?? account.accountID,
                subscriptionType: refreshed.planType ?? account.subscriptionType
            )
            store.save(merged, for: provider)
            setCachedAccount(merged, for: provider)
            return merged.accessToken
        } catch {
            markUnauthorized(provider)
            return nil
        }
    }

    /// Marks a provider unauthorized after a fetch returns 401 even though
    /// `validAccessToken` believed the token was fresh (e.g. server-side
    /// revocation) — called by `QuotaService` so the UI can prompt reconnect
    /// without waiting for the natural expiry window.
    public func markUnauthorized(_ provider: AgentSourceID) {
        flaggedUnauthorized.insert(provider)
        store.clear(provider)
        clearCachedAccount(for: provider)
    }

    private func cachedAccount(for provider: AgentSourceID) -> ConnectedAccount? {
        if accountCachePrimed.contains(provider) {
            return accountCache[provider]
        }
        let loaded = store.load(provider)
        accountCachePrimed.insert(provider)
        if let loaded {
            accountCache[provider] = loaded
        }
        return loaded
    }

    private func setCachedAccount(_ account: ConnectedAccount, for provider: AgentSourceID) {
        accountCachePrimed.insert(provider)
        accountCache[provider] = account
    }

    private func clearCachedAccount(for provider: AgentSourceID) {
        accountCachePrimed.insert(provider)
        accountCache.removeValue(forKey: provider)
    }

    private func persist(_ tokens: OAuthTokens, for provider: AgentSourceID) {
        flaggedUnauthorized.remove(provider)
        let account = ConnectedAccount(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresAt,
            accountID: tokens.accountID,
            subscriptionType: tokens.planType
        )
        store.save(account, for: provider)
        setCachedAccount(account, for: provider)
    }

    private func config(for provider: AgentSourceID) -> OAuthProviderConfig {
        switch provider {
        case .claudeQuota: .claude
        case .codexQuota: .codex
        default: preconditionFailure("No OAuth config for provider \(provider.rawValue)")
        }
    }
}
