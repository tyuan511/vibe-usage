import Foundation
import Testing
@testable import VibeUsageCore

private struct StubAdapter: UsageSourceAdapter {
    let descriptor: AgentSourceDescriptor

    func discoverRootDirectories() -> [URL] { [] }
    func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] { [] }
    func parseIncrementally(
        fileAt path: String,
        from checkpoint: ParseCheckpoint?,
        pricing: PricingProvider
    ) throws -> ParseResult {
        ParseResult(events: [], newCheckpoint: .start)
    }
}

@Test func registryReturnsAdaptersSortedBySortOrder() {
    let registry = AdapterRegistry()
    registry.register(StubAdapter(descriptor: AgentSourceDescriptor(
        id: AgentSourceID(rawValue: "b"), displayName: "B", shortLabel: "B",
        iconSystemName: "circle", tintColorHex: "#000000", sortOrder: 2
    )))
    registry.register(StubAdapter(descriptor: AgentSourceDescriptor(
        id: AgentSourceID(rawValue: "a"), displayName: "A", shortLabel: "A",
        iconSystemName: "circle", tintColorHex: "#000000", sortOrder: 1
    )))

    #expect(registry.descriptors.map(\.id.rawValue) == ["a", "b"])
}

@Test func costCalculatorFallsBackToInputRateWhenCacheRateMissing() {
    let rate = ModelPricingRate(inputPerMillion: 3, outputPerMillion: 15)
    let tokens = TokenCounts(input: 1_000_000, output: 0, cacheCreate: 0, cacheRead: 1_000_000)
    let cost = CostCalculator.cost(for: tokens, rate: rate)
    #expect(cost == 6) // 1M input @ $3 + 1M cacheRead falling back to $3
}
