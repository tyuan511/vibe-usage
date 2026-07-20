import Foundation
import GRDB
import Testing
import VibeUsageCore
@testable import VibeUsageStorage

private func makeEvent(
    sourceID: AgentSourceID = .claudeCode,
    timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
    sessionID: String = "session",
    projectOrWorkspace: String? = nil,
    model: String = "claude-sonnet-4-20250514",
    modelFamily: String = "claude-sonnet-4",
    tokens: TokenCounts = TokenCounts(input: 100, output: 50),
    costUSD: Decimal = 1,
    costIsEstimated: Bool = false,
    dedupKey: String = "dedup-1",
    isSidechainReplay: Bool = false,
    sourceFilePath: String = "/tmp/usage.jsonl",
    sourceFileLine: Int? = 1
) -> UsageEvent {
    UsageEvent(
        sourceID: sourceID,
        timestamp: timestamp,
        sessionID: sessionID,
        projectOrWorkspace: projectOrWorkspace,
        requestID: nil,
        model: model,
        modelFamily: modelFamily,
        tokens: tokens,
        costUSD: costUSD,
        costIsEstimated: costIsEstimated,
        dedupKey: dedupKey,
        isSidechainReplay: isSidechainReplay,
        sourceFilePath: sourceFilePath,
        sourceFileLine: sourceFileLine
    )
}

@Test func repricesEstimatedEventsWhenCurrentPricingBecomesAvailable() throws {
    let store = try makeStore()
    let file = DiscoveredFile(path: "/tmp/codex.jsonl", sourceID: .codexCLI)
    let event = makeEvent(
        sourceID: .codexCLI,
        model: "gpt-5.6-sol",
        modelFamily: "gpt-5.6-sol",
        tokens: TokenCounts(
            input: 1_000_000,
            output: 100_000,
            cacheCreate: 40_000,
            cacheRead: 500_000
        ),
        costUSD: 0,
        costIsEstimated: true,
        dedupKey: "previously-unpriced",
        sourceFilePath: file.path
    )
    try store.applyParseResult(
        ParseResult(events: [event], newCheckpoint: .start),
        file: file,
        fileSize: 1,
        fileModifiedAt: nil
    )

    let pricing = TestPricingProvider(rates: [
        "gpt-5.6-sol": ModelPricingRate(
            inputPerMillion: 5,
            outputPerMillion: 30,
            cacheWritePerMillion: 6.25,
            cacheReadPerMillion: 0.5
        )
    ])
    let updatedCount = try store.repriceEstimatedEvents(using: pricing)

    #expect(updatedCount == 1)
    let breakdown = try store.modelBreakdown(
        sourceFilter: [],
        startDay: "2023-01-01",
        endDay: "2023-12-31"
    )
    let repriced = try #require(breakdown.first)
    #expect(repriced.costUSD == Decimal(string: "8.5"))
    #expect(repriced.estimatedEventCount == 0)
    #expect(try store.repriceEstimatedEvents(using: pricing) == 0)
}

@Test func repricingPreservesUnresolvedAndFallbackEstimates() throws {
    let store = try makeStore()
    let file = DiscoveredFile(path: "/tmp/codex.jsonl", sourceID: .codexCLI)
    let unresolved = makeEvent(
        sourceID: .codexCLI,
        model: "future-model",
        modelFamily: "future-model",
        tokens: TokenCounts(input: 1_000_000),
        costUSD: 0,
        costIsEstimated: true,
        dedupKey: "unresolved",
        sourceFilePath: file.path
    )
    let fallback = makeEvent(
        sourceID: AgentSourceID(rawValue: "qwen"),
        model: "gpt-fallback",
        modelFamily: "gpt-fallback",
        tokens: TokenCounts(output: 500_000, reasoning: 500_000),
        costUSD: 1,
        costIsEstimated: true,
        dedupKey: "fallback",
        sourceFilePath: file.path
    )
    let confirmed = makeEvent(
        sourceID: .codexCLI,
        model: "gpt-confirmed",
        modelFamily: "gpt-confirmed",
        tokens: TokenCounts(input: 1_000_000),
        costUSD: 9,
        costIsEstimated: false,
        dedupKey: "confirmed",
        sourceFilePath: file.path
    )
    try store.applyParseResult(
        ParseResult(events: [unresolved, fallback, confirmed], newCheckpoint: .start),
        file: file,
        fileSize: 1,
        fileModifiedAt: nil
    )

    let updatedCount = try store.repriceEstimatedEvents(using: TestPricingProvider(rates: [
        "gpt-fallback": ModelPricingRate(inputPerMillion: 2, outputPerMillion: 2),
        "gpt-confirmed": ModelPricingRate(inputPerMillion: 3, outputPerMillion: 10),
    ]))

    #expect(updatedCount == 1)
    let breakdown = try store.modelBreakdown(
        sourceFilter: [],
        startDay: "2023-01-01",
        endDay: "2023-12-31"
    )
    let unresolvedRow = try #require(breakdown.first { $0.modelFamily == "future-model" })
    #expect(unresolvedRow.costUSD == 0)
    #expect(unresolvedRow.estimatedEventCount == 1)
    let fallbackRow = try #require(breakdown.first { $0.modelFamily == "gpt-fallback" })
    #expect(fallbackRow.costUSD == 2)
    #expect(fallbackRow.estimatedEventCount == 1)
    let confirmedRow = try #require(breakdown.first { $0.modelFamily == "gpt-confirmed" })
    #expect(confirmedRow.costUSD == 9)
    #expect(confirmedRow.estimatedEventCount == 0)
}

private func makeStore() throws -> GRDBUsageEventStore {
    let store = GRDBUsageEventStore(database: try UsageDatabase())
    try store.ensureSourceRegistered(AgentSourceDescriptor(
        id: .claudeCode, displayName: "Claude Code", shortLabel: "Claude",
        iconSystemName: "circle", tintColorHex: "#000000", sortOrder: 0
    ))
    try store.ensureSourceRegistered(AgentSourceDescriptor(
        id: .codexCLI, displayName: "Codex CLI", shortLabel: "Codex",
        iconSystemName: "circle", tintColorHex: "#000000", sortOrder: 1
    ))
    try store.ensureSourceRegistered(AgentSourceDescriptor(
        id: AgentSourceID(rawValue: "qwen"), displayName: "Qwen", shortLabel: "Qwen",
        iconSystemName: "circle", tintColorHex: "#000000", sortOrder: 2
    ))
    return store
}

@Test func fileMetadataIsNilBeforeAnyParse() throws {
    let store = try makeStore()
    #expect(try store.fileMetadata(forFile: "/tmp/never-seen.jsonl") == nil)
}

private struct TestPricingProvider: PricingProvider {
    let rates: [String: ModelPricingRate]

    func rate(forModelFamily modelFamily: String) -> ModelPricingRate? {
        rates[modelFamily]
    }
}

@Test func applyParseResultPersistsEventsAndCheckpoint() throws {
    let store = try makeStore()
    let event = makeEvent()
    let file = DiscoveredFile(path: event.sourceFilePath, sourceID: event.sourceID)
    let checkpoint = ParseCheckpoint(byteOffset: 42, lineIndex: 1)

    try store.applyParseResult(
        ParseResult(events: [event], newCheckpoint: checkpoint),
        file: file,
        fileSize: 100,
        fileModifiedAt: nil
    )

    let metadata = try store.fileMetadata(forFile: file.path)
    #expect(metadata?.checkpoint == checkpoint)
    #expect(metadata?.fileSizeAtParse == 100)

    let summaries = try store.dailySummaries(sourceFilter: [], startDay: "2023-01-01", endDay: "2023-12-31")
    #expect(summaries.count == 1)
    #expect(summaries[0].tokens.input == 100)
    #expect(summaries[0].tokens.output == 50)
}

@Test func batchApplyIsAtomicAcrossFiles() throws {
    let store = try makeStore()
    let validFile = DiscoveredFile(path: "/tmp/batch-valid.jsonl", sourceID: .claudeCode)
    let missingSource = AgentSourceID(rawValue: "missing-batch-source")
    let invalidFile = DiscoveredFile(path: "/tmp/batch-invalid.jsonl", sourceID: missingSource)
    let validEvent = makeEvent(
        dedupKey: "batch-valid",
        sourceFilePath: validFile.path
    )
    let invalidEvent = makeEvent(
        sourceID: missingSource,
        dedupKey: "batch-invalid",
        sourceFilePath: invalidFile.path
    )

    #expect(throws: (any Error).self) {
        try store.applyParseResults([
            FileParseApplication(
                result: ParseResult(events: [validEvent], newCheckpoint: ParseCheckpoint(byteOffset: 10)),
                file: validFile,
                fileSize: 10,
                fileModifiedAt: nil
            ),
            FileParseApplication(
                result: ParseResult(events: [invalidEvent], newCheckpoint: ParseCheckpoint(byteOffset: 20)),
                file: invalidFile,
                fileSize: 20,
                fileModifiedAt: nil
            )
        ])
    }

    #expect(try store.fileMetadata(forFile: validFile.path) == nil)
    let summaries = try store.dailySummaries(
        sourceFilter: [],
        startDay: "2023-01-01",
        endDay: "2023-12-31"
    )
    #expect(summaries.isEmpty)
}

@Test func batchApplyResolvesDuplicatesAndPersistsEveryCheckpoint() throws {
    let store = try makeStore()
    let firstFile = DiscoveredFile(path: "/tmp/batch-first.jsonl", sourceID: .claudeCode)
    let secondFile = DiscoveredFile(path: "/tmp/batch-second.jsonl", sourceID: .claudeCode)
    let first = makeEvent(
        tokens: TokenCounts(input: 10),
        dedupKey: "batch-shared",
        sourceFilePath: firstFile.path
    )
    let winner = makeEvent(
        tokens: TokenCounts(input: 999),
        dedupKey: "batch-shared",
        sourceFilePath: secondFile.path
    )

    try store.applyParseResults([
        FileParseApplication(
            result: ParseResult(events: [first], newCheckpoint: ParseCheckpoint(byteOffset: 10)),
            file: firstFile,
            fileSize: 10,
            fileModifiedAt: nil
        ),
        FileParseApplication(
            result: ParseResult(events: [winner], newCheckpoint: ParseCheckpoint(byteOffset: 20)),
            file: secondFile,
            fileSize: 20,
            fileModifiedAt: nil
        )
    ])

    let summaries = try store.dailySummaries(
        sourceFilter: [],
        startDay: "2023-01-01",
        endDay: "2023-12-31"
    )
    #expect(summaries.map(\.tokens.input) == [999])
    #expect(try store.fileMetadata(forFile: firstFile.path)?.checkpoint.byteOffset == 10)
    #expect(try store.fileMetadata(forFile: secondFile.path)?.checkpoint.byteOffset == 20)
}

@Test func upsertReplacesExistingRowOnDedupKeyCollisionWhenCandidateWins() throws {
    let store = try makeStore()
    let file = DiscoveredFile(path: "/tmp/usage.jsonl", sourceID: .claudeCode)

    let first = makeEvent(tokens: TokenCounts(input: 10), dedupKey: "same-key")
    try store.applyParseResult(
        ParseResult(events: [first], newCheckpoint: .start),
        file: file, fileSize: 10, fileModifiedAt: nil
    )

    let replacement = makeEvent(tokens: TokenCounts(input: 999), dedupKey: "same-key")
    try store.applyParseResult(
        ParseResult(events: [replacement], newCheckpoint: .start),
        file: file, fileSize: 10, fileModifiedAt: nil
    )

    let summaries = try store.dailySummaries(sourceFilter: [], startDay: "2023-01-01", endDay: "2023-12-31")
    #expect(summaries.count == 1)
    #expect(summaries[0].tokens.input == 999)
}

@Test func upsertKeepsExistingRowWhenCandidateLoses() throws {
    let store = try makeStore()
    let file = DiscoveredFile(path: "/tmp/usage.jsonl", sourceID: .claudeCode)

    let first = makeEvent(tokens: TokenCounts(input: 999), dedupKey: "same-key")
    try store.applyParseResult(
        ParseResult(events: [first], newCheckpoint: .start),
        file: file, fileSize: 10, fileModifiedAt: nil
    )

    let candidate = makeEvent(tokens: TokenCounts(input: 10), dedupKey: "same-key")
    try store.applyParseResult(
        ParseResult(events: [candidate], newCheckpoint: .start),
        file: file, fileSize: 10, fileModifiedAt: nil
    )

    let summaries = try store.dailySummaries(sourceFilter: [], startDay: "2023-01-01", endDay: "2023-12-31")
    #expect(summaries.count == 1)
    #expect(summaries[0].tokens.input == 999)
}

@Test func resetFileRemovesEventsAndParseState() throws {
    let store = try makeStore()
    let file = DiscoveredFile(path: "/tmp/usage.jsonl", sourceID: .claudeCode)

    try store.applyParseResult(
        ParseResult(events: [makeEvent()], newCheckpoint: ParseCheckpoint(byteOffset: 5, lineIndex: 1)),
        file: file, fileSize: 10, fileModifiedAt: nil
    )

    try store.resetFile(file.path)

    #expect(try store.fileMetadata(forFile: file.path) == nil)
    let summaries = try store.dailySummaries(sourceFilter: [], startDay: "2023-01-01", endDay: "2023-12-31")
    #expect(summaries.isEmpty)
}

@Test func dailySummariesFilterBySourceAndDateRange() throws {
    let store = try makeStore()
    let claudeFile = DiscoveredFile(path: "/tmp/claude.jsonl", sourceID: .claudeCode)
    let codexFile = DiscoveredFile(path: "/tmp/codex.jsonl", sourceID: .codexCLI)

    let inRange = makeEvent(
        sourceID: .claudeCode,
        timestamp: Date(timeIntervalSince1970: 1_700_000_000), // 2023-11-14
        tokens: TokenCounts(input: 100),
        dedupKey: "a",
        sourceFilePath: claudeFile.path
    )
    let outOfRange = makeEvent(
        sourceID: .claudeCode,
        timestamp: Date(timeIntervalSince1970: 0), // 1970-01-01
        tokens: TokenCounts(input: 200),
        dedupKey: "b",
        sourceFilePath: claudeFile.path
    )
    let otherSource = makeEvent(
        sourceID: .codexCLI,
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        tokens: TokenCounts(input: 300),
        dedupKey: "c",
        sourceFilePath: codexFile.path
    )

    try store.applyParseResult(ParseResult(events: [inRange], newCheckpoint: .start), file: claudeFile, fileSize: 1, fileModifiedAt: nil)
    try store.applyParseResult(ParseResult(events: [outOfRange], newCheckpoint: .start), file: claudeFile, fileSize: 1, fileModifiedAt: nil)
    try store.applyParseResult(ParseResult(events: [otherSource], newCheckpoint: .start), file: codexFile, fileSize: 1, fileModifiedAt: nil)

    let filtered = try store.dailySummaries(sourceFilter: [.claudeCode], startDay: "2023-11-01", endDay: "2023-11-30")
    #expect(filtered.count == 1)
    #expect(filtered[0].tokens.input == 100)
    #expect(filtered[0].sourceID == .claudeCode)
}

@Test func modelBreakdownGroupsByModelFamilyAndOrdersByCostDescending() throws {
    let store = try makeStore()
    let file = DiscoveredFile(path: "/tmp/usage.jsonl", sourceID: .claudeCode)

    let cheap = makeEvent(modelFamily: "claude-haiku", costUSD: 1, dedupKey: "cheap")
    let expensive = makeEvent(modelFamily: "claude-opus-4", costUSD: 50, dedupKey: "expensive")

    try store.applyParseResult(ParseResult(events: [cheap, expensive], newCheckpoint: .start), file: file, fileSize: 1, fileModifiedAt: nil)

    let breakdown = try store.modelBreakdown(sourceFilter: [], startDay: "2023-01-01", endDay: "2023-12-31")
    #expect(breakdown.map(\.modelFamily) == ["claude-opus-4", "claude-haiku"])
    #expect(breakdown[0].eventCount == 1)
}

@Test func projectBreakdownGroupsByProjectAndSourceOrdersByCostDescending() throws {
    let store = try makeStore()
    let claudeFile = DiscoveredFile(path: "/tmp/claude.jsonl", sourceID: .claudeCode)
    let codexFile = DiscoveredFile(path: "/tmp/codex.jsonl", sourceID: .codexCLI)

    // Project A / Claude: two sessions, two events.
    let aEvent1 = makeEvent(
        sourceID: .claudeCode, sessionID: "session-a1", projectOrWorkspace: "project-a",
        tokens: TokenCounts(input: 10), costUSD: 1, dedupKey: "a1", sourceFilePath: claudeFile.path
    )
    let aEvent2 = makeEvent(
        sourceID: .claudeCode, sessionID: "session-a2", projectOrWorkspace: "project-a",
        tokens: TokenCounts(input: 20), costUSD: 2, dedupKey: "a2", sourceFilePath: claudeFile.path
    )
    // Project B / Codex: one session, high cost so it sorts first.
    let bEvent = makeEvent(
        sourceID: .codexCLI, sessionID: "session-b1", projectOrWorkspace: "project-b",
        tokens: TokenCounts(input: 5), costUSD: 50, dedupKey: "b1", sourceFilePath: codexFile.path
    )
    // NULL project should be grouped under "".
    let noProjectEvent = makeEvent(
        sourceID: .claudeCode, sessionID: "session-none", projectOrWorkspace: nil,
        tokens: TokenCounts(input: 1), costUSD: 0.5, dedupKey: "none", sourceFilePath: claudeFile.path
    )

    try store.applyParseResult(ParseResult(events: [aEvent1, aEvent2, noProjectEvent], newCheckpoint: .start), file: claudeFile, fileSize: 1, fileModifiedAt: nil)
    try store.applyParseResult(ParseResult(events: [bEvent], newCheckpoint: .start), file: codexFile, fileSize: 1, fileModifiedAt: nil)

    let breakdown = try store.projectBreakdown(sourceFilter: [], startDay: "2023-01-01", endDay: "2023-12-31")

    #expect(breakdown.count == 3)
    #expect(breakdown[0].project == "project-b")
    #expect(breakdown[0].sourceID == .codexCLI)
    #expect(breakdown[0].costUSD == 50)
    #expect(breakdown[0].sessionCount == 1)

    let projectA = try #require(breakdown.first { $0.project == "project-a" })
    #expect(projectA.sourceID == .claudeCode)
    #expect(projectA.costUSD == 3)
    #expect(projectA.eventCount == 2)
    #expect(projectA.sessionCount == 2)
    #expect(projectA.tokens.input == 30)

    let unknownProject = try #require(breakdown.first { $0.project == "" })
    #expect(unknownProject.sourceID == .claudeCode)
    #expect(unknownProject.costUSD == 0.5)
    #expect(unknownProject.sessionCount == 1)
}

@Test func databaseUpgradeReindexesOnlyAffectedCodexFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("usage.sqlite").path
    let forkFile = directory.appendingPathComponent("fork.jsonl")
    let duplicateFile = directory.appendingPathComponent("duplicate.jsonl")
    let legitimateFile = directory.appendingPathComponent("legitimate.jsonl")
    let regularFile = directory.appendingPathComponent("regular.jsonl")
    let claudeFile = directory.appendingPathComponent("claude.jsonl")
    try Data("""
        {"timestamp":"2026-05-13T09:00:00Z","type":"session_meta","payload":{"forked_from_id":"parent-session"}}
        """.utf8).write(to: forkFile)
    try Data("""
        {"timestamp":"2026-05-13T09:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":50,"output_tokens":10,"reasoning_output_tokens":5,"total_tokens":115}}}}
        {"timestamp":"2026-05-13T09:01:10Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":50,"output_tokens":10,"reasoning_output_tokens":5,"total_tokens":115}}}}
        """.utf8).write(to: duplicateFile)
    try Data("""
        {"timestamp":"2026-05-13T09:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":50,"output_tokens":10,"reasoning_output_tokens":5,"total_tokens":115}}}}
        {"timestamp":"2026-05-13T09:01:10Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":100,"output_tokens":20,"reasoning_output_tokens":10,"total_tokens":230}}}}
        """.utf8).write(to: legitimateFile)
    try Data("{}\n".utf8).write(to: regularFile)
    try Data("{}\n".utf8).write(to: claudeFile)

    do {
        let legacyQueue = try DatabaseQueue(path: path)
        var legacyMigrator = DatabaseMigrator()
        legacyMigrator.registerMigration("v1_initial_schema") { db in
            try V1InitialSchema.migrate(db)
        }
        try legacyMigrator.migrate(legacyQueue)
        try legacyQueue.write { db in
            try db.execute(sql: """
                INSERT INTO agent_source (id, display_name, first_seen_at)
                VALUES ('codex-cli', 'Codex CLI', '2026-05-13 09:00:00'),
                       ('claude-code', 'Claude Code', '2026-05-13 09:00:00')
                """)
            let eventSQL = """
                INSERT INTO usage_event (
                    source_id, dedup_key, timestamp_utc, session_id,
                    model_raw, model_family, input_tokens, output_tokens,
                    cost_usd, cost_is_estimated, source_file_path,
                    source_file_line, created_at
                ) VALUES (?, ?, '2026-05-13 09:00:00', ?, ?, ?, ?, ?, ?, 0, ?, ?, '2026-05-13 09:00:00')
                """
            try db.execute(
                sql: eventSQL,
                arguments: ["codex-cli", "fork-replay", "fork", "gpt-5.6-sol", "gpt-5.6-sol", 100, 10, 1.5, forkFile.path, 1]
            )
            try db.execute(
                sql: eventSQL,
                arguments: ["codex-cli", "duplicate-1", "duplicate", "gpt-5.6-sol", "gpt-5.6-sol", 200, 20, 2.5, duplicateFile.path, 1]
            )
            try db.execute(
                sql: eventSQL,
                arguments: ["codex-cli", "duplicate-2", "duplicate", "gpt-5.6-sol", "gpt-5.6-sol", 200, 20, 2.5, duplicateFile.path, 2]
            )
            try db.execute(
                sql: eventSQL,
                arguments: ["codex-cli", "legitimate-1", "legitimate", "gpt-5.6-sol", "gpt-5.6-sol", 250, 25, 2.75, legitimateFile.path, 1]
            )
            try db.execute(
                sql: eventSQL,
                arguments: ["codex-cli", "legitimate-2", "legitimate", "gpt-5.6-sol", "gpt-5.6-sol", 250, 25, 2.75, legitimateFile.path, 2]
            )
            try db.execute(
                sql: eventSQL,
                arguments: ["codex-cli", "regular-kept", "regular", "gpt-5.6-sol", "gpt-5.6-sol", 300, 30, 3.5, regularFile.path, 1]
            )
            try db.execute(
                sql: eventSQL,
                arguments: ["claude-code", "claude-kept", "claude", "claude-sonnet-4", "claude-sonnet-4", 400, 40, 4.5, claudeFile.path, 1]
            )

            let stateSQL = """
                INSERT INTO file_parse_state (file_path, source_id, updated_at)
                VALUES (?, ?, '2026-05-13 09:00:00')
                """
            try db.execute(sql: stateSQL, arguments: [forkFile.path, "codex-cli"])
            try db.execute(sql: stateSQL, arguments: [duplicateFile.path, "codex-cli"])
            try db.execute(sql: stateSQL, arguments: [legitimateFile.path, "codex-cli"])
            try db.execute(sql: stateSQL, arguments: [regularFile.path, "codex-cli"])
            try db.execute(sql: stateSQL, arguments: [claudeFile.path, "claude-code"])
        }
    }

    let upgraded = try UsageDatabase(path: path)
    try upgraded.dbQueue.read { db in
        let eventCount: (String) throws -> Int? = { file in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_event WHERE source_file_path = ?", arguments: [file])
        }
        let stateCount: (String) throws -> Int? = { file in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file_parse_state WHERE file_path = ?", arguments: [file])
        }
        let migration = try String.fetchOne(
            db,
            sql: "SELECT identifier FROM grdb_migrations WHERE identifier = 'v2_reindex_codex_fork_replays'"
        )

        #expect(try eventCount(forkFile.path) == 0)
        #expect(try stateCount(forkFile.path) == 0)
        #expect(try eventCount(duplicateFile.path) == 1)
        #expect(try stateCount(duplicateFile.path) == 1)
        #expect(try eventCount(legitimateFile.path) == 2)
        #expect(try stateCount(legitimateFile.path) == 1)
        #expect(try eventCount(regularFile.path) == 1)
        #expect(try stateCount(regularFile.path) == 1)
        #expect(try eventCount(claudeFile.path) == 1)
        #expect(try stateCount(claudeFile.path) == 1)
        #expect(migration == "v2_reindex_codex_fork_replays")
    }
}
