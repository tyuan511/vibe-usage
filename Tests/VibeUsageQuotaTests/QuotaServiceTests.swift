import Foundation
import Testing
import VibeUsageCore
@testable import VibeUsageQuota

@MainActor
@Suite struct QuotaServiceTests {
    @Test func snapshotReturnsAllDisabledWhenSettingIsOff() async {
        let store = CountingConnectedAccountStore()
        let manager = QuotaConnectionManager(store: store, claudeCredentialReader: FakeClaudeCredentialReader(credential: nil))
        let service = QuotaService(connectionManager: manager, isEnabled: { false })
        let snapshot = await service.snapshot()

        #expect(snapshot.sources.count == 2)
        for source in snapshot.sources {
            #expect(source.state == .disabled)
        }
        #expect(store.loadAllCount == 0)
        #expect(store.totalLoadCount == 0)
    }

    @Test func snapshotReturnsNotConnectedWhenEnabledButNoAccountsConnected() async {
        let manager = QuotaConnectionManager(store: InMemoryConnectedAccountStore(), claudeCredentialReader: FakeClaudeCredentialReader(credential: nil))
        let service = QuotaService(connectionManager: manager, isEnabled: { true })
        let snapshot = await service.snapshot()

        #expect(snapshot.sources.count == 2)
        #expect(snapshot.sources[0].sourceID == .claudeQuota)
        #expect(snapshot.sources[0].state == .notConnected)
        #expect(snapshot.sources[1].sourceID == .codexQuota)
        #expect(snapshot.sources[1].state == .notConnected)
    }

    @Test func snapshotFetchesOkForConnectedProvider() async throws {
        let store = InMemoryConnectedAccountStore()
        store.save(
            ConnectedAccount(accessToken: "tok", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3600)),
            for: .claudeQuota
        )
        let manager = QuotaConnectionManager(store: store, claudeCredentialReader: FakeClaudeCredentialReader(credential: nil))
        let claudeProvider = ClaudeQuotaProvider(
            fetcher: FakeHTTPFetcher(result: .success((Data(#"{ "five_hour": { "utilization": 0.4 } }"#.utf8), 200)))
        )
        let service = QuotaService(claudeProvider: claudeProvider, connectionManager: manager, isEnabled: { true })
        let snapshot = await service.snapshot()

        let claude = try #require(snapshot.sources.first { $0.sourceID == .claudeQuota })
        guard case .ok(let windows) = claude.state else {
            Issue.record("expected ok, got \(claude.state)")
            return
        }
        #expect(windows.count == 1)
    }

    /// The subscription tier stored on the connected account must reach the
    /// UI-facing snapshot, since it's what drives the tier badge.
    @Test func snapshotOverlaysStoredSubscriptionTier() async throws {
        let store = InMemoryConnectedAccountStore()
        store.save(
            ConnectedAccount(
                accessToken: "tok",
                refreshToken: "refresh",
                expiresAt: Date().addingTimeInterval(3600),
                subscriptionType: "max"
            ),
            for: .claudeQuota
        )
        let manager = QuotaConnectionManager(store: store, claudeCredentialReader: FakeClaudeCredentialReader(credential: nil))
        let claudeProvider = ClaudeQuotaProvider(
            fetcher: FakeHTTPFetcher(result: .success((Data(#"{ "five_hour": { "utilization": 0.4 } }"#.utf8), 200)))
        )
        let service = QuotaService(claudeProvider: claudeProvider, connectionManager: manager, isEnabled: { true })
        let snapshot = await service.snapshot()

        let claude = try #require(snapshot.sources.first { $0.sourceID == .claudeQuota })
        #expect(claude.subscriptionTier == "max")
    }

    @Test func snapshotInfersCodexFreeTierFromSoloPrimaryWindow() async throws {
        let store = InMemoryConnectedAccountStore()
        store.save(
            ConnectedAccount(
                accessToken: "tok",
                refreshToken: "refresh",
                expiresAt: Date().addingTimeInterval(3600),
                subscriptionType: nil
            ),
            for: .codexQuota
        )
        let manager = QuotaConnectionManager(store: store, claudeCredentialReader: FakeClaudeCredentialReader(credential: nil))
        let codexProvider = CodexQuotaProvider(
            fetcher: FakeHTTPFetcher(result: .success((Data(#"{ "rate_limit": { "primary_window": { "used_percent": 10 } } }"#.utf8), 200)))
        )
        let service = QuotaService(codexProvider: codexProvider, connectionManager: manager, isEnabled: { true })
        let snapshot = await service.snapshot()

        let codex = try #require(snapshot.sources.first { $0.sourceID == .codexQuota })
        #expect(codex.subscriptionTier == "free")
    }

    @Test func snapshotDoesNotInferCodexFreeTierFromPairedWindows() async throws {
        let store = InMemoryConnectedAccountStore()
        store.save(
            ConnectedAccount(
                accessToken: "tok",
                refreshToken: "refresh",
                expiresAt: Date().addingTimeInterval(3600),
                subscriptionType: nil
            ),
            for: .codexQuota
        )
        let manager = QuotaConnectionManager(store: store, claudeCredentialReader: FakeClaudeCredentialReader(credential: nil))
        let codexProvider = CodexQuotaProvider(
            fetcher: FakeHTTPFetcher(result: .success((Data("""
            {
                "rate_limit": {
                    "primary_window": { "used_percent": 10 },
                    "secondary_window": { "used_percent": 20 }
                }
            }
            """.utf8), 200)))
        )
        let service = QuotaService(codexProvider: codexProvider, connectionManager: manager, isEnabled: { true })
        let snapshot = await service.snapshot()

        let codex = try #require(snapshot.sources.first { $0.sourceID == .codexQuota })
        #expect(codex.subscriptionTier == nil)
    }
}
