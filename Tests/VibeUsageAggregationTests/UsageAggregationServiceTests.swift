import Foundation
import Testing
import VibeUsageCore
import VibeUsageStorage
@testable import VibeUsageAggregation

@Test func dashboardSnapshotCombinesDailyRowsAndModelEventCounts() throws {
    let registry = AdapterRegistry()
    let descriptor = AgentSourceDescriptor(
        id: .claudeCode,
        displayName: "Claude Code",
        shortLabel: "Claude",
        iconSystemName: "sparkles",
        tintColorHex: "#C15F3C",
        sortOrder: 0
    )
    registry.register(EmptyAdapter(descriptor: descriptor))

    let store = GRDBUsageEventStore(database: try UsageDatabase())
    try store.ensureSourceRegistered(descriptor)
    let file = DiscoveredFile(path: "/tmp/usage.jsonl", sourceID: .claudeCode)
    try store.applyParseResult(
        ParseResult(events: [usageEvent()], newCheckpoint: .start),
        file: file,
        fileSize: 1,
        fileModifiedAt: nil
    )

    let service = UsageAggregationService(store: store, registry: registry)
    let snapshot = try service.dashboardSnapshot(daysBack: 30, now: Date(timeIntervalSince1970: 1_700_000_000))

    #expect(snapshot.totals.tokens.input == 100)
    #expect(snapshot.totals.eventCount == 1)
    #expect(snapshot.sources.first?.totals.costUSD == 1)
    #expect(snapshot.models.first?.modelFamily == "claude-sonnet-4")
}

@Test func dashboardSnapshotCanHideUndiscoveredSources() throws {
    let registry = AdapterRegistry()
    let claude = AgentSourceDescriptor(
        id: .claudeCode,
        displayName: "Claude Code",
        shortLabel: "Claude",
        iconSystemName: "sparkles",
        tintColorHex: "#C15F3C",
        sortOrder: 0
    )
    let codex = AgentSourceDescriptor(
        id: .codexCLI,
        displayName: "Codex CLI",
        shortLabel: "Codex",
        iconSystemName: "terminal",
        tintColorHex: "#2D7D72",
        sortOrder: 1
    )
    registry.register(EmptyAdapter(descriptor: claude))
    registry.register(EmptyAdapter(descriptor: codex))

    let store = GRDBUsageEventStore(database: try UsageDatabase())
    try store.ensureSourceRegistered(claude)
    try store.applyParseResult(
        ParseResult(events: [usageEvent()], newCheckpoint: .start),
        file: DiscoveredFile(path: "/tmp/usage.jsonl", sourceID: .claudeCode),
        fileSize: 1,
        fileModifiedAt: nil
    )

    let service = UsageAggregationService(store: store, registry: registry)
    let noLocalSources = try service.dashboardSnapshot(
        visibleSourceFilter: [],
        now: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let codexOnly = try service.dashboardSnapshot(
        visibleSourceFilter: [.codexCLI],
        now: Date(timeIntervalSince1970: 1_700_000_000)
    )

    #expect(noLocalSources.sources.isEmpty)
    #expect(noLocalSources.totals.eventCount == 0)
    #expect(codexOnly.sources.map(\.id) == [.codexCLI])
    #expect(codexOnly.totals.eventCount == 0)
}

@Test func dateRangePresetsResolveExpectedLocalDays() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 15, hour: 12)))

    let today = UsageAggregationService.dayBounds(dateRange: .today, daysBack: 30, now: now, calendar: calendar)
    let yesterday = UsageAggregationService.dayBounds(dateRange: .yesterday, daysBack: 30, now: now, calendar: calendar)
    let thisWeek = UsageAggregationService.dayBounds(dateRange: .thisWeek, daysBack: 30, now: now, calendar: calendar)
    let thisMonth = UsageAggregationService.dayBounds(dateRange: .thisMonth, daysBack: 30, now: now, calendar: calendar)

    #expect(calendar.component(.day, from: today.start) == 15)
    #expect(calendar.component(.day, from: yesterday.start) == 14)
    #expect(calendar.component(.day, from: thisWeek.start) == 11)
    #expect(calendar.component(.day, from: thisMonth.start) == 1)
    #expect(today.start == today.end)
    #expect(yesterday.start == yesterday.end)
}

private struct EmptyAdapter: UsageSourceAdapter {
    let descriptor: AgentSourceDescriptor

    func discoverRootDirectories() -> [URL] { [] }
    func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] { [] }
    func parseIncrementally(fileAt path: String, from checkpoint: ParseCheckpoint?, pricing: PricingProvider) throws -> ParseResult {
        ParseResult(events: [], newCheckpoint: .start)
    }
}

private func usageEvent() -> UsageEvent {
    UsageEvent(
        sourceID: .claudeCode,
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        sessionID: "session",
        projectOrWorkspace: "project",
        requestID: nil,
        model: "claude-sonnet-4-20250514",
        modelFamily: "claude-sonnet-4",
        tokens: TokenCounts(input: 100, output: 50),
        costUSD: 1,
        costIsEstimated: false,
        dedupKey: "event",
        sourceFilePath: "/tmp/usage.jsonl",
        sourceFileLine: 1
    )
}
