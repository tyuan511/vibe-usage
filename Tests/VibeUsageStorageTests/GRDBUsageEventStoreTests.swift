import Foundation
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
        costIsEstimated: false,
        dedupKey: dedupKey,
        isSidechainReplay: isSidechainReplay,
        sourceFilePath: sourceFilePath,
        sourceFileLine: sourceFileLine
    )
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
    return store
}

@Test func fileMetadataIsNilBeforeAnyParse() throws {
    let store = try makeStore()
    #expect(try store.fileMetadata(forFile: "/tmp/never-seen.jsonl") == nil)
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

