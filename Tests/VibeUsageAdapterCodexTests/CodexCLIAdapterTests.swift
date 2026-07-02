import Foundation
import Testing
import VibeUsageCore
import VibeUsagePricing
@testable import VibeUsageAdapterCodex

@Test func codexAdapterParsesLastTokenUsage() throws {
    let file = try TemporaryCodexUsageFile(contents: """
    {"timestamp":"2026-05-13T09:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.2-codex"}}
    {"timestamp":"2026-05-13T09:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":250,"output_tokens":125,"reasoning_output_tokens":75,"total_tokens":1200},"total_token_usage":{"input_tokens":1000,"cached_input_tokens":250,"output_tokens":125,"reasoning_output_tokens":75,"total_tokens":1200}}}}

    """)

    let adapter = CodexCLIAdapter()
    let result = try adapter.parseIncrementally(fileAt: file.url.path, from: nil, pricing: BundledPricingProvider())

    #expect(result.events.count == 1)
    let event = try #require(result.events.first)
    #expect(event.sourceID == .codexCLI)
    #expect(event.sessionID == "session-alpha")
    #expect(event.modelFamily == "gpt-5.2-codex")
    #expect(event.tokens == TokenCounts(input: 750, output: 125, cacheCreate: 0, cacheRead: 250, reasoning: 75))
    #expect(event.costUSD > 0)
    #expect(event.costIsEstimated == false)
}

@Test func codexAdapterDiffsCumulativeTotalsAcrossIncrementalScans() throws {
    let file = try TemporaryCodexUsageFile(contents: """
    {"timestamp":"2026-05-13T09:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.2-codex"}}
    {"timestamp":"2026-05-13T09:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":250,"output_tokens":125,"reasoning_output_tokens":75,"total_tokens":1200}}}}

    """)

    let adapter = CodexCLIAdapter()
    let first = try adapter.parseIncrementally(fileAt: file.url.path, from: nil, pricing: BundledPricingProvider())
    try file.append("""
    {"timestamp":"2026-05-13T09:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500,"cached_input_tokens":300,"output_tokens":200,"reasoning_output_tokens":100,"total_tokens":1800}}}}

    """)
    let second = try adapter.parseIncrementally(fileAt: file.url.path, from: first.newCheckpoint, pricing: BundledPricingProvider())

    #expect(first.events.first?.tokens.input == 750)
    #expect(second.events.count == 1)
    #expect(second.events.first?.tokens == TokenCounts(input: 450, output: 75, cacheCreate: 0, cacheRead: 50, reasoning: 25))
}

private final class TemporaryCodexUsageFile {
    let url: URL

    init(contents: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("session-alpha.jsonl")
        try contents.data(using: .utf8)!.write(to: url)
    }

    func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: text.data(using: .utf8)!)
        try handle.close()
    }
}
