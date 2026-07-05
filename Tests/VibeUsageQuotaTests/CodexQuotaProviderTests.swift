import Foundation
import Testing
@testable import VibeUsageQuota

@Suite struct CodexQuotaProviderTests {
    private let referenceNow = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func parsesPrimaryAndSecondaryWindows() throws {
        let json = """
        {
            "rate_limit": {
                "primary_window": { "used_percent": 45, "resets_in_seconds": 900 },
                "secondary_window": { "used_percent": 88, "resets_in_seconds": 604800 }
            },
            "additional_rate_limits": []
        }
        """
        let windows = try CodexQuotaProvider.parseWindows(data: Data(json.utf8), now: referenceNow)

        #expect(windows.count == 2)
        let primary = try #require(windows.first { $0.id == "primary_window" })
        #expect(primary.usedPercentText == "45%")
        let secondary = try #require(windows.first { $0.id == "secondary_window" })
        #expect(secondary.usedPercentText == "88%")
    }

    @Test func missingRateLimitObjectProducesNoWindows() throws {
        let json = "{}"
        let windows = try CodexQuotaProvider.parseWindows(data: Data(json.utf8), now: referenceNow)
        #expect(windows.isEmpty)
    }

    /// Free accounts only ever report `primary_window` (no `secondary_window`
    /// at all) and it represents a rolling 30-day quota, not a 5-hour one —
    /// so its label must differ from the paired (paid-tier) case below.
    @Test func soloPrimaryWindowIsLabeledAsThirtyDayQuota() throws {
        let json = """
        {
            "rate_limit": {
                "primary_window": { "used_percent": 10, "resets_in_seconds": 2592000 }
            }
        }
        """
        let windows = try CodexQuotaProvider.parseWindows(data: Data(json.utf8), now: referenceNow)

        #expect(windows.count == 1)
        #expect(windows[0].id == "primary_window")
    }

    /// Paid accounts (Plus/Pro/Team) report both windows: `primary_window` is
    /// the 5-hour lane, `secondary_window` the 7-day lane. The primary
    /// window's label must differ from the free-tier (solo) case above, since
    /// it's a different quota entirely despite sharing a key name.
    @Test func pairedPrimaryWindowLabelDiffersFromSoloPrimaryWindowLabel() throws {
        let soloJSON = """
        { "rate_limit": { "primary_window": { "used_percent": 10, "resets_in_seconds": 2592000 } } }
        """
        let pairedJSON = """
        {
            "rate_limit": {
                "primary_window": { "used_percent": 10, "resets_in_seconds": 900 },
                "secondary_window": { "used_percent": 20, "resets_in_seconds": 604800 }
            }
        }
        """
        let soloWindows = try CodexQuotaProvider.parseWindows(data: Data(soloJSON.utf8), now: referenceNow)
        let pairedWindows = try CodexQuotaProvider.parseWindows(data: Data(pairedJSON.utf8), now: referenceNow)

        let soloPrimary = try #require(soloWindows.first { $0.id == "primary_window" })
        let pairedPrimary = try #require(pairedWindows.first { $0.id == "primary_window" })
        #expect(soloPrimary.label != pairedPrimary.label)
    }

    // MARK: - State mapping

    @Test func fetchReturnsUnauthorizedOn401() async {
        let provider = CodexQuotaProvider(
            fetcher: FakeHTTPFetcher(result: .success((Data("{}".utf8), 401))),
            now: { self.referenceNow }
        )
        let snapshot = await provider.fetch(accessToken: "tok", accountID: "acc")
        #expect(snapshot.state == .unauthorized)
    }

    @Test func fetchReturnsNetworkErrorOn429() async {
        let provider = CodexQuotaProvider(
            fetcher: FakeHTTPFetcher(result: .success((Data("{}".utf8), 429))),
            now: { self.referenceNow }
        )
        let snapshot = await provider.fetch(accessToken: "tok", accountID: "acc")
        guard case .networkError(let message) = snapshot.state else {
            Issue.record("expected networkError, got \(snapshot.state)")
            return
        }
        #expect(message == "HTTP 429")
    }

    @Test func fetchReturnsNetworkErrorWhenFetcherThrows() async {
        let provider = CodexQuotaProvider(
            fetcher: FakeHTTPFetcher(result: .failure(URLError(.timedOut))),
            now: { self.referenceNow }
        )
        let snapshot = await provider.fetch(accessToken: "tok", accountID: nil)
        guard case .networkError = snapshot.state else {
            Issue.record("expected networkError, got \(snapshot.state)")
            return
        }
    }

    @Test func fetchReturnsOkWithWindowsOnSuccess() async {
        let json = """
        { "rate_limit": { "primary_window": { "used_percent": 20 } } }
        """
        let provider = CodexQuotaProvider(
            fetcher: FakeHTTPFetcher(result: .success((Data(json.utf8), 200))),
            now: { self.referenceNow }
        )
        let snapshot = await provider.fetch(accessToken: "tok", accountID: "acc")
        guard case .ok(let windows) = snapshot.state else {
            Issue.record("expected ok, got \(snapshot.state)")
            return
        }
        #expect(windows.count == 1)
    }
}
