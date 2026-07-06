import Foundation
import GRDB
import Testing
import VibeUsageCore
import VibeUsagePricing
@testable import VibeUsageAdapter

@Test func additionalAdaptersExposeCcusageProviders() {
    let ids = AdditionalSourceAdapters.all.map { $0.descriptor.id.rawValue }

    #expect(ids.contains("opencode"))
    #expect(ids.contains("amp"))
    #expect(ids.contains("droid"))
    #expect(ids.contains("hermes-agent"))
    #expect(ids.contains("pi-agent"))
    #expect(ids.contains("goose"))
    #expect(ids.contains("openclaw"))
    #expect(ids.contains("kilo"))
    #expect(ids.contains("kimi"))
    #expect(ids.contains("qwen"))
    #expect(ids.contains("github-copilot-cli"))
    #expect(ids.contains("gemini-cli"))
}

@Test func geminiAdapterParsesGeminiTokenEvents() throws {
    let file = try TemporaryUsageFile(
        extension: "jsonl",
        contents: """
        {"sessionId":"session-a","projectHash":"project-a","startTime":"2026-05-17T11:07:00.000Z"}
        {"id":"msg-a","timestamp":"2026-05-17T11:07:32.000Z","type":"gemini","model":"gemini-3-flash-preview","tokens":{"input":15327,"output":23,"cached":11526,"thoughts":919,"tool":7,"total":16276}}

        """
    )
    let adapter = try #require(AdditionalSourceAdapters.all.first { $0.descriptor.id.rawValue == "gemini-cli" })
    let result = try adapter.parseIncrementally(fileAt: file.url.path, from: nil, pricing: BundledPricingProvider())

    let event = try #require(result.events.first)
    #expect(event.sourceID.rawValue == "gemini-cli")
    #expect(event.sessionID == "session-a")
    #expect(event.projectOrWorkspace == "project-a")
    #expect(event.model == "gemini-3-flash-preview")
    #expect(event.tokens == TokenCounts(input: 3808, output: 23, cacheCreate: 0, cacheRead: 11526, reasoning: 919))
}

@Test func ampAdapterParsesThreadLedgerEventsOnRescan() throws {
    let file = try TemporaryUsageFile(
        extension: "json",
        contents: """
        {
          "id": "thread-a",
          "usageLedger": {
            "events": [
              {
                "id": "evt-a",
                "timestamp": "2026-06-01T11:00:00Z",
                "model": "claude-sonnet-4-20250514",
                "tokens": { "input": 10, "output": 20 }
              }
            ]
          }
        }
        """
    )
    let adapter = try #require(AdditionalSourceAdapters.all.first { $0.descriptor.id.rawValue == "amp" })
    let first = try adapter.parseIncrementally(fileAt: file.url.path, from: nil, pricing: BundledPricingProvider())
    let second = try adapter.parseIncrementally(fileAt: file.url.path, from: first.newCheckpoint, pricing: BundledPricingProvider())

    #expect(first.events.count == 1)
    #expect(second.events.count == 1)
    #expect(first.events.first?.sessionID == "thread-a")
    #expect(first.events.first?.modelFamily == "claude-sonnet-4")
}

@Test func ampAdapterAddsLedgerCacheTokensFromTargetMessage() throws {
    let file = try TemporaryUsageFile(
        extension: "json",
        contents: """
        {
          "id": "thread-a",
          "messages": [
            {
              "role": "assistant",
              "messageId": 42,
              "usage": {
                "cacheCreationInputTokens": 7,
                "cacheReadInputTokens": 11
              }
            }
          ],
          "usageLedger": {
            "events": [
              {
                "id": "evt-a",
                "toMessageId": 42,
                "timestamp": "2026-06-01T11:00:00Z",
                "model": "gpt-5",
                "tokens": { "input": 10, "output": 20 }
              }
            ]
          }
        }
        """
    )
    let adapter = try #require(AdditionalSourceAdapters.all.first { $0.descriptor.id.rawValue == "amp" })
    let result = try adapter.parseIncrementally(fileAt: file.url.path, from: nil, pricing: BundledPricingProvider())

    let event = try #require(result.events.first)
    #expect(event.tokens == TokenCounts(input: 10, output: 20, cacheCreate: 7, cacheRead: 11))
}

@Test func hermesAdapterParsesSessionRows() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("state.db")
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
        try db.execute(sql: """
        CREATE TABLE sessions (
          id TEXT,
          started_at TEXT,
          model TEXT,
          provider TEXT,
          message_count INTEGER,
          input_tokens INTEGER,
          output_tokens INTEGER,
          cache_read_tokens INTEGER,
          cache_creation_tokens INTEGER,
          reasoning_tokens INTEGER,
          estimated_cost REAL,
          actual_cost REAL
        )
        """)
        try db.execute(
            sql: """
            INSERT INTO sessions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                "row-1",
                "2026-06-01T12:00:00Z",
                "gpt-5",
                "openai",
                3,
                12,
                34,
                5,
                6,
                7,
                0.02,
                0.03
            ]
        )
    }

    let adapter = try #require(AdditionalSourceAdapters.all.first { $0.descriptor.id.rawValue == "hermes-agent" })
    let result = try adapter.parseIncrementally(fileAt: url.path, from: nil, pricing: BundledPricingProvider())

    let event = try #require(result.events.first)
    #expect(result.events.count == 1)
    #expect(event.sourceID.rawValue == "hermes-agent")
    #expect(event.tokens == TokenCounts(input: 12, output: 34, cacheCreate: 6, cacheRead: 5, reasoning: 7))
    #expect(event.costUSD == Decimal(string: "0.03"))
}

@Test func hermesAdapterParsesSessionsWithoutActualCostColumn() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("state.db")
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
        try db.execute(sql: """
        CREATE TABLE sessions (
          id TEXT,
          started_at TEXT,
          model TEXT,
          provider TEXT,
          message_count INTEGER,
          input_tokens INTEGER,
          output_tokens INTEGER,
          cache_read_tokens INTEGER,
          cache_creation_tokens INTEGER,
          reasoning_tokens INTEGER,
          estimated_cost REAL
        )
        """)
        try db.execute(
            sql: """
            INSERT INTO sessions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                "row-legacy",
                "2026-06-01T12:00:00Z",
                "gpt-5",
                "openai",
                3,
                12,
                34,
                5,
                6,
                7,
                0.02
            ]
        )
    }

    let adapter = try #require(AdditionalSourceAdapters.all.first { $0.descriptor.id.rawValue == "hermes-agent" })
    let result = try adapter.parseIncrementally(fileAt: url.path, from: nil, pricing: BundledPricingProvider())

    let event = try #require(result.events.first)
    #expect(result.events.count == 1)
    #expect(event.costUSD == Decimal(string: "0.02"))
}

@Test func hermesAdapterParsesSessionsWithoutEstimatedCostColumn() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("state.db")
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
        try db.execute(sql: """
        CREATE TABLE sessions (
          id TEXT,
          started_at TEXT,
          model TEXT,
          provider TEXT,
          message_count INTEGER,
          input_tokens INTEGER,
          output_tokens INTEGER,
          cache_read_tokens INTEGER,
          cache_creation_tokens INTEGER,
          reasoning_tokens INTEGER,
          actual_cost REAL
        )
        """)
        try db.execute(
            sql: """
            INSERT INTO sessions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                "row-actual-only",
                "2026-06-01T12:00:00Z",
                "gpt-5",
                "openai",
                3,
                12,
                34,
                5,
                6,
                7,
                0.03
            ]
        )
    }

    let adapter = try #require(AdditionalSourceAdapters.all.first { $0.descriptor.id.rawValue == "hermes-agent" })
    let result = try adapter.parseIncrementally(fileAt: url.path, from: nil, pricing: BundledPricingProvider())

    let event = try #require(result.events.first)
    #expect(result.events.count == 1)
    #expect(event.costUSD == Decimal(string: "0.03"))
}

@Test func openCodeAdapterParsesMessageTableRows() throws {
    let database = try TemporaryUsageDatabase(name: "opencode.db")
    try database.queue.write { db in
        try db.execute(sql: "CREATE TABLE message (id TEXT, session_id TEXT, data TEXT)")
        try db.execute(
            sql: "INSERT INTO message (id, session_id, data) VALUES (?, ?, ?)",
            arguments: [
                "row-msg-1",
                "session-a",
                """
                {"id":"embedded-msg-1","sessionID":"ignored-session","providerID":"anthropic","modelID":"claude-sonnet-4-20250514","time":{"created":1767312000000},"tokens":{"input":100,"output":50,"cache":{"read":10,"write":20}},"cost":0.02}
                """
            ]
        )
    }

    let adapter = try #require(AdditionalSourceAdapters.all.first { $0.descriptor.id.rawValue == "opencode" })
    let result = try adapter.parseIncrementally(fileAt: database.url.path, from: nil, pricing: BundledPricingProvider())

    let event = try #require(result.events.first)
    #expect(result.events.count == 1)
    #expect(event.sourceID.rawValue == "opencode")
    #expect(event.sessionID == "session-a")
    #expect(event.requestID == "row-msg-1")
    #expect(event.model == "claude-sonnet-4-20250514")
    #expect(event.tokens == TokenCounts(input: 100, output: 50, cacheCreate: 20, cacheRead: 10))
    #expect(event.costUSD == Decimal(string: "0.02"))
}

@Test func openCodeAdapterUsesCcusageModelCandidatesForPricing() throws {
    let file = try TemporaryUsageFile(
        extension: "json",
        contents: """
        {"id":"msg-1","sessionID":"session-a","providerID":"moonshot","modelID":"k2p6","time":{"created":1767312000000},"tokens":{"input":1000000,"output":0}}
        """
    )
    let pricing = TestPricingProvider(rates: [
        "kimi-k2.6": ModelPricingRate(inputPerMillion: 2, outputPerMillion: 0)
    ])

    let adapter = try #require(AdditionalSourceAdapters.all.first { $0.descriptor.id.rawValue == "opencode" })
    let result = try adapter.parseIncrementally(fileAt: file.url.path, from: nil, pricing: pricing)

    let event = try #require(result.events.first)
    #expect(event.model == "k2p6")
    #expect(event.costUSD == 2)
}

@Test func kiloAdapterParsesMessageTableRows() throws {
    let database = try TemporaryUsageDatabase(name: "kilo.db")
    try database.queue.write { db in
        try db.execute(sql: "CREATE TABLE message (id TEXT, session_id TEXT, data TEXT)")
        try db.execute(
            sql: "INSERT INTO message (id, session_id, data) VALUES (?, ?, ?)",
            arguments: [
                "row-1",
                "session-a",
                """
                {"id":"msg-1","role":"assistant","providerID":"anthropic","modelID":"claude-sonnet-4-20250514","time":{"created":1767312000},"tokens":{"input":100,"output":50,"reasoning":5,"cache":{"read":10,"write":20}},"cost":0.02}
                """
            ]
        )
    }

    let adapter = try #require(AdditionalSourceAdapters.all.first { $0.descriptor.id.rawValue == "kilo" })
    let result = try adapter.parseIncrementally(fileAt: database.url.path, from: nil, pricing: BundledPricingProvider())

    let event = try #require(result.events.first)
    #expect(result.events.count == 1)
    #expect(event.sourceID.rawValue == "kilo")
    #expect(event.sessionID == "session-a")
    #expect(event.requestID == "msg-1")
    #expect(event.model == "claude-sonnet-4-20250514")
    #expect(event.tokens == TokenCounts(input: 100, output: 50, cacheCreate: 20, cacheRead: 10, reasoning: 5))
    #expect(event.costUSD == Decimal(string: "0.02"))
}

@Test func gooseAdapterParsesAccumulatedSessionRows() throws {
    let database = try TemporaryUsageDatabase(name: "sessions.db")
    try database.queue.write { db in
        try db.execute(sql: """
        CREATE TABLE sessions (
          id TEXT,
          model_config_json TEXT,
          provider_name TEXT,
          created_at TEXT,
          total_tokens INTEGER,
          input_tokens INTEGER,
          output_tokens INTEGER,
          accumulated_total_tokens INTEGER,
          accumulated_input_tokens INTEGER,
          accumulated_output_tokens INTEGER
        )
        """)
        try db.execute(
            sql: "INSERT INTO sessions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            arguments: [
                "session-a",
                #"{"model_name":"claude-sonnet-4-20250514"}"#,
                "anthropic",
                "2026-05-01 01:02:03",
                9,
                1,
                2,
                180,
                100,
                50
            ]
        )
    }

    let adapter = try #require(AdditionalSourceAdapters.all.first { $0.descriptor.id.rawValue == "goose" })
    let result = try adapter.parseIncrementally(fileAt: database.url.path, from: nil, pricing: BundledPricingProvider())

    let event = try #require(result.events.first)
    #expect(event.sourceID.rawValue == "goose")
    #expect(event.sessionID == "session-a")
    #expect(event.model == "claude-sonnet-4-20250514")
    #expect(event.tokens == TokenCounts(input: 100, output: 50, reasoning: 30))
}

@Test func droidAdapterFallsBackToSidecarModel() throws {
    let directory = try TemporaryUsageDirectory()
    let settings = directory.url.appendingPathComponent("session-b.settings.json")
    let sidecar = directory.url.appendingPathComponent("session-b.jsonl")
    try """
    {
      "providerLock": "anthropic",
      "providerLockTimestamp": "2026-05-02T01:02:03.000Z",
      "tokenUsage": { "inputTokens": 10, "outputTokens": 20 }
    }
    """.data(using: .utf8)!.write(to: settings)
    try #"{"content":"Model: Claude Opus 4.5 Thinking [Anthropic]"}"#.data(using: .utf8)!.write(to: sidecar)

    let adapter = try #require(AdditionalSourceAdapters.all.first { $0.descriptor.id.rawValue == "droid" })
    let result = try adapter.parseIncrementally(fileAt: settings.path, from: nil, pricing: BundledPricingProvider())

    let event = try #require(result.events.first)
    #expect(event.sessionID == "session-b")
    #expect(event.model == "claude-opus-4-5-thinking")
    #expect(event.tokens == TokenCounts(input: 10, output: 20))
}

@Test func piAdapterParsesMessageRecordsAndExtractsProjectSession() throws {
    let directory = try TemporaryUsageDirectory()
    let sessions = directory.url.appendingPathComponent("sessions/project-a", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let file = sessions.appendingPathComponent("agent_session-a.jsonl")
    try """
    {"type":"message","timestamp":"2026-01-02T00:00:00.000Z","message":{"role":"assistant","model":"gpt-5","usage":{"input":100,"output":200,"cacheRead":10,"cacheWrite":20,"cost":{"total":0.03}}}}

    """.data(using: .utf8)!.write(to: file)

    let adapter = try #require(AdditionalSourceAdapters.all.first { $0.descriptor.id.rawValue == "pi-agent" })
    let result = try adapter.parseIncrementally(fileAt: file.path, from: nil, pricing: BundledPricingProvider())

    let event = try #require(result.events.first)
    #expect(event.sourceID.rawValue == "pi-agent")
    #expect(event.projectOrWorkspace == "project-a")
    #expect(event.sessionID == "session-a")
    #expect(event.model == "[pi] gpt-5")
    #expect(event.tokens == TokenCounts(input: 100, output: 200, cacheCreate: 20, cacheRead: 10))
    #expect(event.costUSD == Decimal(string: "0.03"))
}

@Test func openClawAdapterTracksModelSnapshotForAssistantUsage() throws {
    let file = try TemporaryUsageFile(
        extension: "jsonl",
        contents: """
        {"type":"model_change","modelId":"gpt-5.2","provider":"openai","message":"not-an-object"}
        {"type":"message","timestamp":"2026-03-04T05:06:07.000Z","message":{"role":"assistant","usage":{"input":10,"output":20,"cacheRead":3,"cacheWrite":4,"cost":{"total":0.05}}}}

        """
    )

    let adapter = try #require(AdditionalSourceAdapters.all.first { $0.descriptor.id.rawValue == "openclaw" })
    let result = try adapter.parseIncrementally(fileAt: file.url.path, from: nil, pricing: BundledPricingProvider())

    let event = try #require(result.events.first)
    #expect(result.events.count == 1)
    #expect(event.sourceID.rawValue == "openclaw")
    #expect(event.model == "[openclaw] gpt-5.2")
    #expect(event.tokens == TokenCounts(input: 10, output: 20, cacheCreate: 4, cacheRead: 3))
    #expect(event.costUSD == Decimal(string: "0.05"))
}

@Test func qwenAdapterParsesUsageMetadataWithUnknownDefaultModel() throws {
    let file = try TemporaryUsageFile(
        extension: "jsonl",
        contents: """
        {"type":"assistant","timestamp":"2026-03-04T05:06:07.000Z","sessionId":"session-a","usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":20,"cachedContentTokenCount":3,"thoughtsTokenCount":4,"totalTokenCount":37}}

        """
    )

    let adapter = try #require(AdditionalSourceAdapters.all.first { $0.descriptor.id.rawValue == "qwen" })
    let result = try adapter.parseIncrementally(fileAt: file.url.path, from: nil, pricing: BundledPricingProvider())

    let event = try #require(result.events.first)
    #expect(event.sourceID.rawValue == "qwen")
    #expect(event.sessionID == "session-a")
    #expect(event.model == "unknown")
    #expect(event.tokens == TokenCounts(input: 10, output: 20, cacheRead: 3, reasoning: 4))
}

@Test func qwenAdapterBillsReasoningAsOutputForEstimatedCost() throws {
    let file = try TemporaryUsageFile(
        extension: "jsonl",
        contents: """
        {"type":"assistant","timestamp":"2026-03-04T05:06:07.000Z","sessionId":"session-a","model":"qwen-test","usageMetadata":{"thoughtsTokenCount":100,"totalTokenCount":100}}

        """
    )
    let pricing = TestPricingProvider(rates: [
        "qwen-test": ModelPricingRate(inputPerMillion: 0, outputPerMillion: 1)
    ])

    let adapter = try #require(AdditionalSourceAdapters.all.first { $0.descriptor.id.rawValue == "qwen" })
    let result = try adapter.parseIncrementally(fileAt: file.url.path, from: nil, pricing: pricing)

    let event = try #require(result.events.first)
    #expect(event.tokens == TokenCounts(reasoning: 100))
    #expect(event.costUSD == Decimal(string: "0.0001"))
}

@Test func kimiAdapterReadsRootConfigForWireModel() throws {
    let directory = try TemporaryUsageDirectory()
    try #"{"model":"kimi-k2"}"#.data(using: .utf8)!.write(to: directory.url.appendingPathComponent("config.json"))
    let sessionDir = directory.url.appendingPathComponent("sessions/group/session-a", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
    let file = sessionDir.appendingPathComponent("wire.jsonl")
    try """
    {"timestamp":1770983427.123,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":100,"output":50,"input_cache_read":10,"input_cache_creation":20},"message_id":"msg-1"}}}

    """.data(using: .utf8)!.write(to: file)

    let adapter = try #require(AdditionalSourceAdapters.all.first { $0.descriptor.id.rawValue == "kimi" })
    let result = try adapter.parseIncrementally(fileAt: file.path, from: nil, pricing: BundledPricingProvider())

    let event = try #require(result.events.first)
    #expect(event.sourceID.rawValue == "kimi")
    #expect(event.sessionID == "session-a")
    #expect(event.model == "kimi-k2")
    #expect(event.tokens == TokenCounts(input: 100, output: 50, cacheCreate: 20, cacheRead: 10))
}

@Test func copilotAdapterParsesInferenceLogsAndFiltersSummaryDuplicates() throws {
    let file = try TemporaryUsageFile(
        extension: "jsonl",
        contents: """
        {"type":"span","name":"chat completion","traceId":"trace-a","spanId":"span-chat","endTime":[1767312000,0],"attributes":{"gen_ai.operation.name":"chat","gen_ai.response.id":"resp-a","gen_ai.conversation.id":"session-a","gen_ai.response.model":"gpt-5","gen_ai.usage.input_tokens":100,"gen_ai.usage.cache_read.input_tokens":10,"gen_ai.usage.output_tokens":50}}
        {"type":"span","name":"invoke_agent completion","traceId":"trace-a","spanId":"span-agent","endTime":[1767312001,0],"attributes":{"gen_ai.operation.name":"invoke_agent","gen_ai.response.id":"resp-a","gen_ai.conversation.id":"session-a","gen_ai.response.model":"gpt-5","gen_ai.usage.input_tokens":100,"gen_ai.usage.output_tokens":50}}
        {"body":"GenAI inference: complete","traceId":"trace-b","spanId":"log-1","timestamp":1767312002,"attributes":{"event.name":"gen_ai.client.inference.operation.details","gen_ai.response.id":"resp-b","copilot_chat.session_id":"session-b","gen_ai.response.model":"gpt-5","gen_ai.usage.input_tokens":40,"gen_ai.usage.output_tokens":6}}

        """
    )

    let adapter = try #require(AdditionalSourceAdapters.all.first { $0.descriptor.id.rawValue == "github-copilot-cli" })
    let result = try adapter.parseIncrementally(fileAt: file.url.path, from: nil, pricing: BundledPricingProvider())

    #expect(result.events.count == 2)
    let chat = try #require(result.events.first { $0.sessionID == "session-a" })
    let inference = try #require(result.events.first { $0.sessionID == "session-b" })
    #expect(chat.tokens == TokenCounts(input: 90, output: 50, cacheRead: 10))
    #expect(inference.tokens == TokenCounts(input: 40, output: 6))
}

private final class TemporaryUsageFile {
    let url: URL

    init(extension pathExtension: String, contents: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("usage.\(pathExtension)")
        try contents.data(using: .utf8)!.write(to: url)
    }
}

private final class TemporaryUsageDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

private final class TemporaryUsageDatabase {
    let url: URL
    let queue: DatabaseQueue

    init(name: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(name)
        queue = try DatabaseQueue(path: url.path)
    }
}

private struct TestPricingProvider: PricingProvider {
    let rates: [String: ModelPricingRate]

    func rate(forModelFamily modelFamily: String) -> ModelPricingRate? {
        rates[modelFamily]
    }
}
