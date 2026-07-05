import Foundation

/// Serializes quota usage fetches, enforces a minimum interval between
/// network calls (upstream endpoints return HTTP 429 when polled too
/// aggressively), and serves the last successful snapshot when a fetch is
/// skipped or rate-limited.
actor QuotaFetchCoordinator {
    /// Matches the app's quota refresh timer cadence so popover-open /
    /// manual-refresh churn cannot hammer endpoints between timer ticks.
    static let defaultMinFetchInterval: TimeInterval = 5 * 60

    private let minFetchInterval: TimeInterval
    private let now: @Sendable () -> Date

    private var cachedSnapshot: QuotaSourceSnapshot?
    private var lastNetworkFetchAt: Date?

    init(
        minFetchInterval: TimeInterval = 5 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.minFetchInterval = minFetchInterval
        self.now = now
    }

    func reset() {
        cachedSnapshot = nil
        lastNetworkFetchAt = nil
    }

    func fetch(_ performFetch: @Sendable () async -> QuotaSourceSnapshot) async -> QuotaSourceSnapshot {
        let currentTime = now()

        if let lastFetch = lastNetworkFetchAt,
           currentTime.timeIntervalSince(lastFetch) < minFetchInterval,
           let cached = cachedSnapshot,
           case .ok = cached.state {
            return cached
        }

        lastNetworkFetchAt = currentTime
        let snapshot = await performFetch()

        if case .ok = snapshot.state {
            cachedSnapshot = snapshot
            return snapshot
        }

        if Self.isRateLimited(snapshot), let cached = cachedSnapshot {
            return cached
        }

        return snapshot
    }

    private static func isRateLimited(_ snapshot: QuotaSourceSnapshot) -> Bool {
        guard case .networkError(let message) = snapshot.state else { return false }
        return message == "HTTP 429"
    }
}
