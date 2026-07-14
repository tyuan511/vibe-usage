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

@Test func claudeAdapterParsesOnlyAppendedTailAfterCheckpoint() throws {
    let firstLine = #"{"timestamp":"2026-01-09T10:00:00.000Z","sessionId":"session-alpha","message":{"id":"msg-alpha-1","model":"claude-sonnet-4-20250514","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"requestId":"req-alpha-1","costUSD":0.12,"version":"1.0.0"}"# + "\n"
    let secondLine = #"{"timestamp":"2026-01-09T10:02:00.000Z","sessionId":"session-alpha","message":{"id":"msg-alpha-2","model":"claude-sonnet-4-20250514","usage":{"input_tokens":20,"output_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"requestId":"req-alpha-2","costUSD":0.03,"version":"1.0.0"}"# + "\n"

    let file = try TemporaryUsageFile(contents: firstLine)
    let adapter = ClaudeCodeAdapter()
    let first = try adapter.parseIncrementally(fileAt: file.url.path, from: nil, pricing: BundledPricingProvider())
    #expect(first.events.count == 1)
    #expect(first.newCheckpoint.byteOffset == Int64(firstLine.utf8.count))

    let handle = try FileHandle(forWritingTo: file.url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(secondLine.utf8))

    let second = try adapter.parseIncrementally(
        fileAt: file.url.path,
        from: first.newCheckpoint,
        pricing: BundledPricingProvider()
    )
    #expect(second.events.count == 1)
    #expect(second.events.first?.dedupKey == "claude-message:msg-alpha-2")
    #expect(second.events.first?.sourceFileLine == 2)
}

@Test func loadJSONLBytesReadsOnlyTailAfterCheckpoint() throws {
    let prefix = String(repeating: "x", count: 4096) + "\n"
    let suffix = #"{"ok":true}"# + "\n"
    let file = try TemporaryUsageFile(contents: prefix + suffix)

    let slice = try loadJSONLBytes(
        path: file.url.path,
        from: ParseCheckpoint(byteOffset: Int64(prefix.utf8.count), lineIndex: 1)
    )
    #expect(slice.baseOffset == Int64(prefix.utf8.count))
    #expect(slice.data == Data(suffix.utf8))
    #expect(slice.endOffset == Int64((prefix + suffix).utf8.count))
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
