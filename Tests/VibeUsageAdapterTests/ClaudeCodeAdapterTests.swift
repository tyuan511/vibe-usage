import Foundation
import Testing
import VibeUsageCore
import VibeUsagePricing
@testable import VibeUsageAdapter

@Test func claudeAdapterParsesUsageJSONLAndUsesReportedCost() throws {
    let file = try TemporaryUsageFile(contents: """
    {"timestamp":"2026-01-09T10:00:00.000Z","sessionId":"session-alpha","message":{"role":"assistant","id":"msg-alpha-1","model":"claude-sonnet-4-20250514","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":25,"cache_read_input_tokens":10}},"requestId":"req-alpha-1","costUSD":0.12,"version":"1.0.0"}
    {"timestamp":"2026-01-09T10:01:00.000Z","type":"progress"}

    """)

    let adapter = ClaudeCodeAdapter()
    let result = try adapter.parseIncrementally(fileAt: file.url.path, from: nil, pricing: BundledPricingProvider())

    #expect(result.events.count == 1)
    let event = try #require(result.events.first)
    #expect(event.sourceID == .claudeCode)
    #expect(event.sessionID == "session-alpha")
    #expect(event.modelFamily == "claude-sonnet-4")
    #expect(event.tokens == TokenCounts(input: 100, output: 50, cacheCreate: 25, cacheRead: 10))
    #expect(event.costUSD == Decimal(string: "0.12"))
    #expect(event.costIsEstimated == false)
    #expect(event.dedupKey == "claude-message:msg-alpha-1")
}

@Test func claudeAdapterResumesFromCheckpoint() throws {
    let file = try TemporaryUsageFile(contents: """
    {"timestamp":"2026-01-09T10:00:00.000Z","sessionId":"session-alpha","message":{"id":"msg-alpha-1","model":"claude-sonnet-4-20250514","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":25,"cache_read_input_tokens":10}},"requestId":"req-alpha-1","costUSD":0.12,"version":"1.0.0"}

    """)

    let adapter = ClaudeCodeAdapter()
    let first = try adapter.parseIncrementally(fileAt: file.url.path, from: nil, pricing: BundledPricingProvider())
    let second = try adapter.parseIncrementally(fileAt: file.url.path, from: first.newCheckpoint, pricing: BundledPricingProvider())

    #expect(first.events.count == 1)
    #expect(second.events.isEmpty)
}

private struct TemporaryUsageFile {
    let url: URL

    init(contents: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("chat.jsonl")
        try contents.data(using: .utf8)!.write(to: url)
    }
}
