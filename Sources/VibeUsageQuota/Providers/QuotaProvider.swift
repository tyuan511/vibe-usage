import Foundation
import VibeUsageCore

extension AgentSourceID {
    /// Distinct from `.claudeCode`/`.codexCLI` in `VibeUsageCore` — those
    /// identify *local log adapters* for the cost-aggregation pipeline.
    /// Quota sources happen to cover the same underlying tools, so reusing
    /// the same IDs keeps the UI's agent icon/display-name lookups working
    /// without a second mapping table.
    public static var claudeQuota: AgentSourceID { .claudeCode }
    public static var codexQuota: AgentSourceID { .codexCLI }
}

/// Aggregates Claude/Codex quota fetches, honors the `enablesLimitMonitoring`
/// setting and each provider's connection state (via
/// ``QuotaConnectionManager``), and fetches concurrently.
///
/// Unlike the pre-OAuth-pivot design, providers no longer read credentials
/// themselves — this service asks `QuotaConnectionManager` for a valid access
/// token per provider first, and only calls the provider's `fetch` when one
/// is available.
///
/// `@MainActor` because it holds a reference to `QuotaConnectionManager`
/// (itself `@MainActor` — it drives `NSWorkspace` and keychain access from
/// the same actor the rest of the app's UI state lives on).
@MainActor
public struct QuotaService {
    private let claudeProvider: ClaudeQuotaProvider
    private let codexProvider: CodexQuotaProvider
    private let connectionManager: QuotaConnectionManager
    private let isEnabled: @Sendable () -> Bool

    public init(
        claudeProvider: ClaudeQuotaProvider = ClaudeQuotaProvider(),
        codexProvider: CodexQuotaProvider = CodexQuotaProvider(),
        connectionManager: QuotaConnectionManager,
        isEnabled: @escaping @Sendable () -> Bool
    ) {
        self.claudeProvider = claudeProvider
        self.codexProvider = codexProvider
        self.connectionManager = connectionManager
        self.isEnabled = isEnabled
    }

    public func snapshot() async -> QuotaSnapshot {
        let now = Date()
        guard isEnabled() else {
            let disabledSources = [
                QuotaSourceSnapshot(sourceID: .claudeQuota, displayName: claudeProvider.displayName, state: .disabled, fetchedAt: now),
                QuotaSourceSnapshot(sourceID: .codexQuota, displayName: codexProvider.displayName, state: .disabled, fetchedAt: now)
            ]
            return QuotaSnapshot(sources: disabledSources, generatedAt: now)
        }

        async let claude = fetchClaude()
        async let codex = fetchCodex()
        let sources = await [claude, codex]

        return QuotaSnapshot(sources: sources, generatedAt: now)
    }

    private func fetchClaude() async -> QuotaSourceSnapshot {
        guard connectionManager.isConnected(.claudeQuota) else {
            return QuotaSourceSnapshot(sourceID: .claudeQuota, displayName: claudeProvider.displayName, state: .notConnected, fetchedAt: Date())
        }
        guard let token = await connectionManager.validAccessToken(for: .claudeQuota) else {
            return QuotaSourceSnapshot(sourceID: .claudeQuota, displayName: claudeProvider.displayName, state: .unauthorized, fetchedAt: Date())
        }
        let snapshot = await claudeProvider.fetch(accessToken: token)
        if case .unauthorized = snapshot.state {
            connectionManager.markUnauthorized(.claudeQuota)
        }
        return withTier(snapshot, provider: .claudeQuota)
    }

    private func fetchCodex() async -> QuotaSourceSnapshot {
        guard connectionManager.isConnected(.codexQuota) else {
            return QuotaSourceSnapshot(sourceID: .codexQuota, displayName: codexProvider.displayName, state: .notConnected, fetchedAt: Date())
        }
        guard let token = await connectionManager.validAccessToken(for: .codexQuota) else {
            return QuotaSourceSnapshot(sourceID: .codexQuota, displayName: codexProvider.displayName, state: .unauthorized, fetchedAt: Date())
        }
        let accountID = connectionManager.accountID(for: .codexQuota)
        let snapshot = await codexProvider.fetch(accessToken: token, accountID: accountID)
        if case .unauthorized = snapshot.state {
            connectionManager.markUnauthorized(.codexQuota)
        }
        return withTier(snapshot, provider: .codexQuota)
    }

    /// Overlays the connected account's subscription tier onto a provider's
    /// snapshot — known independently of whether this particular fetch
    /// succeeded, so it survives transient `.networkError`s too.
    private func withTier(_ snapshot: QuotaSourceSnapshot, provider: AgentSourceID) -> QuotaSourceSnapshot {
        let storedTier = connectionManager.subscriptionTier(for: provider)
        return QuotaSourceSnapshot(
            sourceID: snapshot.sourceID,
            displayName: snapshot.displayName,
            state: snapshot.state,
            fetchedAt: snapshot.fetchedAt,
            subscriptionTier: storedTier ?? inferredSubscriptionTier(from: snapshot, provider: provider)
        )
    }

    /// Codex free accounts may omit `chatgpt_plan_type` from the OAuth token,
    /// but their quota payload is still distinctive: only `primary_window` is
    /// present, representing the rolling 30-day free quota.
    private func inferredSubscriptionTier(from snapshot: QuotaSourceSnapshot, provider: AgentSourceID) -> String? {
        guard provider == .codexQuota,
              case .ok(let windows) = snapshot.state else {
            return nil
        }
        let windowIDs = Set(windows.map(\.id))
        if windowIDs.contains("primary_window"), !windowIDs.contains("secondary_window") {
            return "free"
        }
        return nil
    }
}
