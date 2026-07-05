import Foundation
import Testing
@testable import VibeUsageQuota

@Suite struct ClaudeQuotaProviderTests {
    private let referenceNow = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func parsesUtilizationPercentWindowsWithMicrosecondISOReset() throws {
        // Mirrors the real /api/oauth/usage payload: `utilization` is a
        // 0...100 percent, and `resets_at` has microsecond precision.
        let json = """
        {
            "five_hour": { "utilization": 60.0, "resets_at": "2026-07-05T13:29:59.875437+00:00" },
            "seven_day": { "utilization": 31.0, "resets_at": "2026-07-10T07:59:59.875459+00:00" }
        }
        """
        let windows = try ClaudeQuotaProvider.parseWindows(data: Data(json.utf8), now: referenceNow)

        #expect(windows.count == 2)
        let fiveHour = try #require(windows.first { $0.id == "five_hour" })
        #expect(fiveHour.usedPercentText == "60%")
        #expect(abs(fiveHour.usedFraction - 0.60) < 0.0001)
        #expect(fiveHour.resetsAt != nil)

        let sevenDay = try #require(windows.first { $0.id == "seven_day" })
        #expect(sevenDay.usedPercentText == "31%")
    }

    @Test func parsesUsedAndLimitRatioStyleWindows() throws {
        let json = """
        {
            "five_hour": { "used": 62, "limit": 100, "resets_in_seconds": 1800 },
            "seven_day_opus": { "used": 910, "limit": 1000, "resets_in_seconds": 3600 }
        }
        """
        let windows = try ClaudeQuotaProvider.parseWindows(data: Data(json.utf8), now: referenceNow)

        let fiveHour = try #require(windows.first { $0.id == "five_hour" })
        #expect(fiveHour.usedPercentText == "62%")

        let opus = try #require(windows.first { $0.id == "seven_day_opus" })
        #expect(opus.usedPercentText == "91%")
        #expect(opus.resetsAt == referenceNow.addingTimeInterval(3600))
    }

    @Test func clampsOutOfRangePercentAndIgnoresUnknownWindowKeys() throws {
        let json = """
        {
            "five_hour": { "utilization": 140.0 },
            "some_future_window": { "utilization": 50.0 }
        }
        """
        let windows = try ClaudeQuotaProvider.parseWindows(data: Data(json.utf8), now: referenceNow)

        #expect(windows.count == 1)
        #expect(windows[0].id == "five_hour")
        #expect(windows[0].usedFraction == 1.0)
        #expect(windows[0].usedPercentText == "100%")
    }

    @Test func windowsWithoutRecognizableUsageFieldsAreSkipped() throws {
        let json = """
        {
            "five_hour": { "some_unrelated_field": "value" },
            "seven_day": { "utilization": 30.0 }
        }
        """
        let windows = try ClaudeQuotaProvider.parseWindows(data: Data(json.utf8), now: referenceNow)

        #expect(windows.count == 1)
        #expect(windows[0].id == "seven_day")
    }

    // MARK: - State mapping

    @Test func fetchReturnsUnauthorizedOn401() async {
        let provider = ClaudeQuotaProvider(
            fetcher: FakeHTTPFetcher(result: .success((Data("{}".utf8), 401))),
            now: { self.referenceNow }
        )
        let snapshot = await provider.fetch(accessToken: "token")
        #expect(snapshot.state == .unauthorized)
    }

    @Test func fetchReturnsNetworkErrorWhenFetcherThrows() async {
        let provider = ClaudeQuotaProvider(
            fetcher: FakeHTTPFetcher(result: .failure(URLError(.notConnectedToInternet))),
            now: { self.referenceNow }
        )
        let snapshot = await provider.fetch(accessToken: "token")
        guard case .networkError = snapshot.state else {
            Issue.record("expected networkError, got \(snapshot.state)")
            return
        }
    }

    @Test func fetchReturnsOkWithWindowsOnSuccess() async {
        let json = """
        { "five_hour": { "utilization": 0.5 } }
        """
        let provider = ClaudeQuotaProvider(
            fetcher: FakeHTTPFetcher(result: .success((Data(json.utf8), 200))),
            now: { self.referenceNow }
        )
        let snapshot = await provider.fetch(accessToken: "token")
        guard case .ok(let windows) = snapshot.state else {
            Issue.record("expected ok, got \(snapshot.state)")
            return
        }
        #expect(windows.count == 1)
    }
}

// MARK: - Fakes

struct FakeHTTPFetcher: HTTPFetching {
    let result: Result<(Data, Int), Error>

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, statusCode) = try result.get()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
