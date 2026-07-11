import Foundation

public protocol PricingDataFetching: Sendable {
    func fetch(from url: URL) async throws -> Data
}

public struct URLSessionPricingDataFetcher: PricingDataFetching {
    public init() {}

    public func fetch(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            throw PricingUpdateError.invalidResponse
        }
        return data
    }
}

public struct PricingUpdateResult: Sendable, Equatable {
    public let modelCount: Int
    public let updatedAt: Date

    public init(modelCount: Int, updatedAt: Date) {
        self.modelCount = modelCount
        self.updatedAt = updatedAt
    }
}

public enum PricingUpdateError: LocalizedError, Sendable, Equatable {
    case invalidResponse
    case noRelevantRates
    case invalidSnapshot

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The pricing service returned an invalid response."
        case .noRelevantRates:
            return "The pricing service did not contain prices for supported models."
        case .invalidSnapshot:
            return "The pricing snapshot is incomplete."
        }
    }
}

/// Downloads the repository-maintained pricing snapshot that GitHub Actions
/// refreshes from LiteLLM each day.
public struct PricingUpdateService: Sendable {
    public static let sourceURL = URL(
        string: "https://raw.githubusercontent.com/tyuan511/vibe-usage/main/Sources/VibeUsagePricing/Resources/model_prices.json"
    )!

    private let fetcher: any PricingDataFetching
    private let store: PricingSnapshotStore
    private let sourceURL: URL
    private static let minimumModelCount = 100
    private static let requiredFamilyPrefixes = [
        "gpt-", "claude-", "grok-", "gemini-", "deepseek-", "glm-", "kimi-", "minimax-"
    ]

    public init(
        fetcher: any PricingDataFetching = URLSessionPricingDataFetcher(),
        store: PricingSnapshotStore = PricingSnapshotStore(),
        sourceURL: URL = Self.sourceURL
    ) {
        self.fetcher = fetcher
        self.store = store
        self.sourceURL = sourceURL
    }

    public func update() async throws -> PricingUpdateResult {
        let data = try await fetcher.fetch(from: sourceURL)
        let snapshot = try JSONDecoder().decode(PricingSnapshot.self, from: data)
        guard !snapshot.isEmpty else {
            throw PricingUpdateError.noRelevantRates
        }
        guard Self.isComplete(snapshot) else {
            throw PricingUpdateError.invalidSnapshot
        }
        try store.save(snapshot)
        return PricingUpdateResult(modelCount: snapshot.count, updatedAt: store.lastUpdatedAt ?? Date())
    }

    private static func isComplete(_ snapshot: PricingSnapshot) -> Bool {
        guard snapshot.count >= minimumModelCount else { return false }
        let families = snapshot.keys.map { $0.lowercased() }
        return requiredFamilyPrefixes.allSatisfy { prefix in
            families.contains { $0.hasPrefix(prefix) }
        }
    }
}
