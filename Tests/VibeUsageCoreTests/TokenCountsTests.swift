import Testing
@testable import VibeUsageCore

@Test func cacheReadRatioUsesOnlyCacheableInputTokens() {
    let tokens = TokenCounts(input: 400, output: 800, cacheCreate: 100, cacheRead: 500, reasoning: 200)

    #expect(tokens.cacheableInputTotal == 1_000)
    #expect(tokens.cacheReadRatio == 0.5)
}

@Test func cacheReadRatioIsAbsentWithoutACacheRead() {
    let tokens = TokenCounts(input: 400, cacheCreate: 100)

    #expect(tokens.cacheReadRatio == nil)
}
