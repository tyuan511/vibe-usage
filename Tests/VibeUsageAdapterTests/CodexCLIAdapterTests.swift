import Foundation
import Testing
import VibeUsageCore
import VibeUsagePricing
@testable import VibeUsageAdapter

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

@Test func codexAdapterSkipsForkedParentUsageReplay() throws {
    let sessions = try TemporaryCodexSessionDirectory()
    let parentID = "019f4969-3449-7b91-8d73-bd0def9f96ac"
    _ = try sessions.write(
        fileName: "rollout-2026-05-13T09-00-00-\(parentID).jsonl",
        contents: """
        {"timestamp":"2026-05-13T09:00:00.000Z","type":"session_meta","payload":{"id":"\(parentID)"}}
        {"timestamp":"2026-05-13T09:00:10.000Z","type":"turn_context","payload":{"model":"gpt-5.2-codex"}}
        {"timestamp":"2026-05-13T09:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":250,"output_tokens":125,"reasoning_output_tokens":75,"total_tokens":1200},"total_token_usage":{"input_tokens":1000,"cached_input_tokens":250,"output_tokens":125,"reasoning_output_tokens":75,"total_tokens":1200}}}}
        {"timestamp":"2026-05-13T09:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"cached_input_tokens":50,"output_tokens":75,"reasoning_output_tokens":25,"total_tokens":600},"total_token_usage":{"input_tokens":1500,"cached_input_tokens":300,"output_tokens":200,"reasoning_output_tokens":100,"total_tokens":1800}}}}
        {"timestamp":"2026-05-13T09:04:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":600,"cached_input_tokens":100,"output_tokens":100,"reasoning_output_tokens":40,"total_tokens":740},"total_token_usage":{"input_tokens":2100,"cached_input_tokens":400,"output_tokens":300,"reasoning_output_tokens":140,"total_tokens":2540}}}}

        """
    )
    let child = try sessions.write(
        fileName: "rollout-2026-05-13T09-03-00-019f498d-dd16-7fd3-acb2-61c3fe90abf7.jsonl",
        contents: """
        {"timestamp":"2026-05-13T09:03:00.000Z","type":"session_meta","payload":{"id":"019f498d-dd16-7fd3-acb2-61c3fe90abf7","session_id":"\(parentID)","forked_from_id":"\(parentID)","parent_thread_id":"\(parentID)","thread_source":"subagent"}}
        {"timestamp":"2026-05-13T09:03:00.001Z","type":"session_meta","payload":{"id":"\(parentID)"}}
        {"timestamp":"2026-05-13T09:03:00.002Z","type":"turn_context","payload":{"model":"gpt-5.2-codex"}}
        {"timestamp":"2026-05-13T09:03:00.003Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":250,"output_tokens":125,"reasoning_output_tokens":75,"total_tokens":1200},"total_token_usage":{"input_tokens":1000,"cached_input_tokens":250,"output_tokens":125,"reasoning_output_tokens":75,"total_tokens":1200}}}}
        {"timestamp":"2026-05-13T09:03:00.004Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"cached_input_tokens":50,"output_tokens":75,"reasoning_output_tokens":25,"total_tokens":600},"total_token_usage":{"input_tokens":1500,"cached_input_tokens":300,"output_tokens":200,"reasoning_output_tokens":100,"total_tokens":1800}}}}
        {"timestamp":"2026-05-13T09:03:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"019f498d-ee16-7fd3-acb2-61c3fe90abf7"}}
        {"timestamp":"2026-05-13T09:03:01.001Z","type":"turn_context","payload":{"model":"gpt-5.2-codex"}}
        {"timestamp":"2026-05-13T09:03:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1800,"cached_input_tokens":400,"output_tokens":260,"reasoning_output_tokens":120,"total_tokens":2180}}}}

        """
    )

    let result = try CodexCLIAdapter().parseIncrementally(
        fileAt: child.path,
        from: nil,
        pricing: BundledPricingProvider()
    )

    #expect(result.events.count == 1)
    #expect(result.events.first?.tokens == TokenCounts(input: 200, output: 60, cacheCreate: 0, cacheRead: 100, reasoning: 20))
    #expect(result.events.first?.sourceFileLine == 8)
}

@Test func codexAdapterReusesParentAcrossForksWithDifferentReplayCutoffs() throws {
    let sessions = try TemporaryCodexSessionDirectory()
    let parentID = "019f4969-3449-7b91-8d73-bd0def9f96ac"
    _ = try sessions.write(
        fileName: "rollout-2026-05-13T09-00-00-\(parentID).jsonl",
        contents: """
        {"timestamp":"2026-05-13T09:00:00.000Z","type":"session_meta","payload":{"id":"\(parentID)"}}
        {"timestamp":"2026-05-13T09:00:10.000Z","type":"turn_context","payload":{"model":"gpt-5.2-codex"}}
        {"timestamp":"2026-05-13T09:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":10,"total_tokens":110},"total_token_usage":{"input_tokens":100,"output_tokens":10,"total_tokens":110}}}}
        {"timestamp":"2026-05-13T09:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":10,"total_tokens":110},"total_token_usage":{"input_tokens":200,"output_tokens":20,"total_tokens":220}}}}

        """
    )
    let earlyChild = try sessions.write(
        fileName: "rollout-2026-05-13T09-01-30-019f498d-dd16-7fd3-acb2-61c3fe90abf7.jsonl",
        contents: """

        {"timestamp":"2026-05-13T09:01:30.000Z","type":"session_meta","payload":{"id":"019f498d-dd16-7fd3-acb2-61c3fe90abf7","forked_from_id":"\(parentID)"}}
        {"timestamp":"2026-05-13T09:01:30.001Z","type":"turn_context","payload":{"model":"gpt-5.2-codex"}}
        {"timestamp":"2026-05-13T09:01:30.002Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":10,"total_tokens":110},"total_token_usage":{"input_tokens":100,"output_tokens":10,"total_tokens":110}}}}
        {"timestamp":"2026-05-13T09:01:40.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"output_tokens":5,"total_tokens":55},"total_token_usage":{"input_tokens":150,"output_tokens":15,"total_tokens":165}}}}

        """
    )
    let lateChild = try sessions.write(
        fileName: "rollout-2026-05-13T09-02-30-019f498d-dd16-7fd3-acb2-61c3fe90abf8.jsonl",
        contents: """
        {"timestamp":"2026-05-13T09:02:30.000Z","type":"session_meta","payload":{"id":"019f498d-dd16-7fd3-acb2-61c3fe90abf8","forked_from_id":"\(parentID)"}}
        {"timestamp":"2026-05-13T09:02:30.001Z","type":"turn_context","payload":{"model":"gpt-5.2-codex"}}
        {"timestamp":"2026-05-13T09:02:30.002Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":10,"total_tokens":110},"total_token_usage":{"input_tokens":100,"output_tokens":10,"total_tokens":110}}}}
        {"timestamp":"2026-05-13T09:02:30.003Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":10,"total_tokens":110},"total_token_usage":{"input_tokens":200,"output_tokens":20,"total_tokens":220}}}}
        {"timestamp":"2026-05-13T09:02:40.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":60,"output_tokens":6,"total_tokens":66},"total_token_usage":{"input_tokens":260,"output_tokens":26,"total_tokens":286}}}}

        """
    )

    let adapter = CodexCLIAdapter()
    let early = try adapter.parseIncrementally(
        fileAt: earlyChild.path,
        from: nil,
        pricing: BundledPricingProvider()
    )
    let late = try adapter.parseIncrementally(
        fileAt: lateChild.path,
        from: nil,
        pricing: BundledPricingProvider()
    )

    #expect(early.events.map(\.tokens) == [TokenCounts(input: 50, output: 5)])
    #expect(late.events.map(\.tokens) == [TokenCounts(input: 60, output: 6)])
}

@Test func codexAdapterSkipsRepeatedCumulativeUsageSnapshot() throws {
    let file = try TemporaryCodexUsageFile(contents: """
    {"timestamp":"2026-05-13T09:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.2-codex"}}
    {"timestamp":"2026-05-13T09:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":250,"output_tokens":125,"reasoning_output_tokens":75,"total_tokens":1200},"total_token_usage":{"input_tokens":1000,"cached_input_tokens":250,"output_tokens":125,"reasoning_output_tokens":75,"total_tokens":1200}}}}
    {"timestamp":"2026-05-13T09:01:10.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":250,"output_tokens":125,"reasoning_output_tokens":75,"total_tokens":1200},"total_token_usage":{"input_tokens":1000,"cached_input_tokens":250,"output_tokens":125,"reasoning_output_tokens":75,"total_tokens":1200}}}}

    """)

    let result = try CodexCLIAdapter().parseIncrementally(
        fileAt: file.url.path,
        from: nil,
        pricing: BundledPricingProvider()
    )

    #expect(result.events.count == 1)
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

private final class TemporaryCodexSessionDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026/05/13", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(fileName: String, contents: String) throws -> URL {
        let file = url.appendingPathComponent(fileName)
        try contents.data(using: .utf8)!.write(to: file)
        return file
    }
}
