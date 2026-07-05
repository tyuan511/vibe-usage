import Foundation
import Testing
@testable import VibeUsageQuota

@Suite struct QuotaFetchCoordinatorTests {
    private let referenceNow = Date(timeIntervalSince1970: 1_800_000_000)
    private let claudeSuccessJSON = Data(#"{ "five_hour": { "utilization": 40.0 } }"#.utf8)
    private let codexSuccessJSON = Data(#"{ "rate_limit": { "primary_window": { "used_percent": 20 } } }"#.utf8)

    @Test func returnsCachedSnapshotWithinMinFetchInterval() async {
        var currentTime = referenceNow
        var fetchCount = 0
        let fetcher = CountingHTTPFetcher { _ in
            fetchCount += 1
            return (self.claudeSuccessJSON, 200)
        }
        let provider = ClaudeQuotaProvider(fetcher: fetcher, now: { currentTime })
        let coordinator = QuotaFetchCoordinator(minFetchInterval: 300, now: { currentTime })

        let first = await coordinator.fetch { await provider.fetch(accessToken: "token") }
        currentTime = referenceNow.addingTimeInterval(60)
        let second = await coordinator.fetch { await provider.fetch(accessToken: "token") }

        guard case .ok(let firstWindows) = first.state,
              case .ok(let secondWindows) = second.state else {
            Issue.record("expected ok snapshots")
            return
        }
        #expect(fetchCount == 1)
        #expect(firstWindows == secondWindows)
        #expect(first.fetchedAt == second.fetchedAt)
    }

    @Test func fetchesAgainAfterMinFetchIntervalElapses() async {
        var currentTime = referenceNow
        var fetchCount = 0
        let fetcher = CountingHTTPFetcher { _ in
            fetchCount += 1
            return (self.claudeSuccessJSON, 200)
        }
        let provider = ClaudeQuotaProvider(fetcher: fetcher, now: { currentTime })
        let coordinator = QuotaFetchCoordinator(minFetchInterval: 300, now: { currentTime })

        _ = await coordinator.fetch { await provider.fetch(accessToken: "token") }
        currentTime = referenceNow.addingTimeInterval(301)
        _ = await coordinator.fetch { await provider.fetch(accessToken: "token") }

        #expect(fetchCount == 2)
    }

    @Test func returnsCachedSnapshotOn429() async {
        var currentTime = referenceNow
        var fetchCount = 0
        let fetcher = CountingHTTPFetcher { _ in
            fetchCount += 1
            if fetchCount == 1 {
                return (self.claudeSuccessJSON, 200)
            }
            return (Data("{}".utf8), 429)
        }
        let provider = ClaudeQuotaProvider(fetcher: fetcher, now: { currentTime })
        let coordinator = QuotaFetchCoordinator(minFetchInterval: 0, now: { currentTime })

        let first = await coordinator.fetch { await provider.fetch(accessToken: "token") }
        currentTime = referenceNow.addingTimeInterval(301)
        let second = await coordinator.fetch { await provider.fetch(accessToken: "token") }

        guard case .ok(let firstWindows) = first.state,
              case .ok(let secondWindows) = second.state else {
            Issue.record("expected cached ok snapshots")
            return
        }
        #expect(firstWindows == secondWindows)
        #expect(fetchCount == 2)
    }

    @Test func returnsCachedSnapshotOn429ForCodex() async {
        var currentTime = referenceNow
        var fetchCount = 0
        let fetcher = CountingHTTPFetcher { _ in
            fetchCount += 1
            if fetchCount == 1 {
                return (self.codexSuccessJSON, 200)
            }
            return (Data("{}".utf8), 429)
        }
        let provider = CodexQuotaProvider(fetcher: fetcher, now: { currentTime })
        let coordinator = QuotaFetchCoordinator(minFetchInterval: 0, now: { currentTime })

        let first = await coordinator.fetch { await provider.fetch(accessToken: "token", accountID: "acc") }
        currentTime = referenceNow.addingTimeInterval(301)
        let second = await coordinator.fetch { await provider.fetch(accessToken: "token", accountID: "acc") }

        guard case .ok(let firstWindows) = first.state,
              case .ok(let secondWindows) = second.state else {
            Issue.record("expected cached ok snapshots")
            return
        }
        #expect(firstWindows == secondWindows)
        #expect(fetchCount == 2)
    }

    @Test func returns429WhenNoCachedSnapshotExists() async {
        let fetcher = CountingHTTPFetcher { _ in
            (Data("{}".utf8), 429)
        }
        let provider = ClaudeQuotaProvider(fetcher: fetcher, now: { self.referenceNow })
        let coordinator = QuotaFetchCoordinator(minFetchInterval: 0, now: { self.referenceNow })

        let snapshot = await coordinator.fetch { await provider.fetch(accessToken: "token") }
        guard case .networkError(let message) = snapshot.state else {
            Issue.record("expected networkError, got \(snapshot.state)")
            return
        }
        #expect(message == "HTTP 429")
    }

    @Test func resetClearsCachedSnapshot() async {
        var currentTime = referenceNow
        var fetchCount = 0
        let fetcher = CountingHTTPFetcher { _ in
            fetchCount += 1
            return (self.claudeSuccessJSON, 200)
        }
        let provider = ClaudeQuotaProvider(fetcher: fetcher, now: { currentTime })
        let coordinator = QuotaFetchCoordinator(minFetchInterval: 300, now: { currentTime })

        _ = await coordinator.fetch { await provider.fetch(accessToken: "token") }
        await coordinator.reset()
        currentTime = referenceNow.addingTimeInterval(60)
        _ = await coordinator.fetch { await provider.fetch(accessToken: "token") }

        #expect(fetchCount == 2)
    }
}

private struct CountingHTTPFetcher: HTTPFetching {
    let handler: @Sendable (URLRequest) -> (Data, Int)

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, statusCode) = handler(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
