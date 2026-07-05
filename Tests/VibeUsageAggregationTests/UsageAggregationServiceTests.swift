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
    #expect(codexOnly.sources.isEmpty)
    #expect(codexOnly.totals.eventCount == 0)
}

@Test func dashboardSnapshotHidesZeroActivitySources() throws {
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
    let snapshot = try service.dashboardSnapshot(
        visibleSourceFilter: [.claudeCode, .codexCLI],
        now: Date(timeIntervalSince1970: 1_700_000_000)
    )

    #expect(snapshot.sources.map(\.id) == [.claudeCode])
}

@Test func dashboardSnapshotMarksEstimatedModelCosts() throws {
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
    try store.applyParseResult(
        ParseResult(events: [usageEvent(costIsEstimated: true)], newCheckpoint: .start),
        file: DiscoveredFile(path: "/tmp/usage.jsonl", sourceID: .claudeCode),
        fileSize: 1,
        fileModifiedAt: nil
    )

    let service = UsageAggregationService(store: store, registry: registry)
    let snapshot = try service.dashboardSnapshot(now: Date(timeIntervalSince1970: 1_700_000_000))

    #expect(snapshot.sources.first?.hasEstimatedCost == true)
    #expect(snapshot.models.first?.hasEstimatedCost == true)
}

@Test func dateRangePresetsResolveExpectedLocalDays() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 15, hour: 12)))

    let today = UsageAggregationService.dayBounds(dateRange: .today, daysBack: 30, now: now, calendar: calendar)
    let yesterday = UsageAggregationService.dayBounds(dateRange: .yesterday, daysBack: 30, now: now, calendar: calendar)
    let last7Days = UsageAggregationService.dayBounds(dateRange: .last7Days, daysBack: 30, now: now, calendar: calendar)
    let last30Days = UsageAggregationService.dayBounds(dateRange: .last30Days, daysBack: 30, now: now, calendar: calendar)
    let last90Days = UsageAggregationService.dayBounds(dateRange: .last90Days, daysBack: 30, now: now, calendar: calendar)
    let thisWeek = UsageAggregationService.dayBounds(dateRange: .thisWeek, daysBack: 30, now: now, calendar: calendar)
    let thisMonth = UsageAggregationService.dayBounds(dateRange: .thisMonth, daysBack: 30, now: now, calendar: calendar)

    #expect(calendar.component(.day, from: today.start) == 15)
    #expect(calendar.component(.day, from: yesterday.start) == 14)
    #expect(calendar.component(.day, from: last7Days.start) == 9)
    #expect(calendar.component(.month, from: last30Days.start) == 4)
    #expect(calendar.component(.day, from: last30Days.start) == 16)
    #expect(calendar.component(.month, from: last90Days.start) == 2)
    #expect(calendar.component(.day, from: last90Days.start) == 15)
    #expect(calendar.component(.day, from: thisWeek.start) == 11)
    #expect(calendar.component(.day, from: thisMonth.start) == 1)
    #expect(today.start == today.end)
    #expect(yesterday.start == yesterday.end)
    #expect(last7Days.end == today.end)
    #expect(last30Days.end == today.end)
    #expect(last90Days.end == today.end)
}

@Test func insightsSnapshotComposesProjectsAndTotals() throws {
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
    try store.ensureSourceRegistered(codex)

    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let cheapEvent = UsageEvent(
        sourceID: .claudeCode,
        timestamp: now,
        sessionID: "session-cheap",
        projectOrWorkspace: "project-a",
        requestID: nil,
        model: "claude-haiku",
        modelFamily: "claude-haiku",
        tokens: TokenCounts(input: 10, output: 5),
        costUSD: 1,
        costIsEstimated: false,
        dedupKey: "cheap",
        sourceFilePath: "/tmp/claude.jsonl",
        sourceFileLine: 1
    )
    let expensiveEvent = UsageEvent(
        sourceID: .codexCLI,
        timestamp: now.addingTimeInterval(3_600),
        sessionID: "session-expensive",
        projectOrWorkspace: "project-b",
        requestID: nil,
        model: "gpt-5",
        modelFamily: "gpt-5",
        tokens: TokenCounts(input: 20, output: 8),
        costUSD: 50,
        costIsEstimated: false,
        dedupKey: "expensive",
        sourceFilePath: "/tmp/codex.jsonl",
        sourceFileLine: 1
    )

    try store.applyParseResult(
        ParseResult(events: [cheapEvent], newCheckpoint: .start),
        file: DiscoveredFile(path: "/tmp/claude.jsonl", sourceID: .claudeCode),
        fileSize: 1, fileModifiedAt: nil
    )
    try store.applyParseResult(
        ParseResult(events: [expensiveEvent], newCheckpoint: .start),
        file: DiscoveredFile(path: "/tmp/codex.jsonl", sourceID: .codexCLI),
        fileSize: 1, fileModifiedAt: nil
    )

    let service = UsageAggregationService(store: store, registry: registry)
    let snapshot = try service.insightsSnapshot(
        visibleSourceFilter: [.claudeCode, .codexCLI],
        range: .last30Days,
        now: now.addingTimeInterval(7_200)
    )

    #expect(snapshot.totals.costUSD == 51)
    #expect(snapshot.totals.eventCount == 2)

    // Sorted by cost descending.
    #expect(snapshot.projects.map(\.project) == ["project-b", "project-a"])
    #expect(snapshot.projects[0].costUSD == 50)
    #expect(snapshot.projects[0].sessionCount == 1)

    #expect(Set(snapshot.sources.map(\.id)) == [.claudeCode, .codexCLI])

    // Both events fall on the same day within the current 30-day range, so
    // the preceding 30-day period has no activity.
    #expect(snapshot.previousTotals.costUSD == 0)
    #expect(snapshot.previousTotals.eventCount == 0)
    #expect(snapshot.activeDayCount == 1)

    // Models are populated, sorted by cost descending, and carry the right
    // source attribution (one row per (modelFamily, source) pair).
    #expect(snapshot.models.map(\.modelFamily) == ["gpt-5", "claude-haiku"])
    #expect(snapshot.models[0].sourceID == .codexCLI)
    #expect(snapshot.models[0].costUSD == 50)
    #expect(snapshot.models[0].eventCount == 1)
    #expect(snapshot.models[1].sourceID == .claudeCode)
    #expect(snapshot.models[1].costUSD == 1)
}

@Test func insightsSnapshotComputesPreviousPeriodTotals() throws {
    let registry = AdapterRegistry()
    let claude = AgentSourceDescriptor(
        id: .claudeCode,
        displayName: "Claude Code",
        shortLabel: "Claude",
        iconSystemName: "sparkles",
        tintColorHex: "#C15F3C",
        sortOrder: 0
    )
    registry.register(EmptyAdapter(descriptor: claude))

    let store = GRDBUsageEventStore(database: try UsageDatabase())
    try store.ensureSourceRegistered(claude)

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 15, hour: 12)))
    let previousPeriodDay = try #require(calendar.date(byAdding: .day, value: -10, to: now))

    let currentEvent = UsageEvent(
        sourceID: .claudeCode,
        timestamp: now,
        sessionID: "session-current",
        projectOrWorkspace: "project-a",
        requestID: nil,
        model: "claude-haiku",
        modelFamily: "claude-haiku",
        tokens: TokenCounts(input: 10, output: 5),
        costUSD: 4,
        costIsEstimated: false,
        dedupKey: "current",
        sourceFilePath: "/tmp/claude.jsonl",
        sourceFileLine: 1
    )
    let previousEvent = UsageEvent(
        sourceID: .claudeCode,
        timestamp: previousPeriodDay,
        sessionID: "session-previous",
        projectOrWorkspace: "project-a",
        requestID: nil,
        model: "claude-haiku",
        modelFamily: "claude-haiku",
        tokens: TokenCounts(input: 10, output: 5),
        costUSD: 5,
        costIsEstimated: false,
        dedupKey: "previous",
        sourceFilePath: "/tmp/claude.jsonl",
        sourceFileLine: 2
    )

    try store.applyParseResult(
        ParseResult(events: [currentEvent], newCheckpoint: .start),
        file: DiscoveredFile(path: "/tmp/claude.jsonl", sourceID: .claudeCode),
        fileSize: 1, fileModifiedAt: nil
    )
    try store.applyParseResult(
        ParseResult(events: [previousEvent], newCheckpoint: .start),
        file: DiscoveredFile(path: "/tmp/claude.jsonl", sourceID: .claudeCode),
        fileSize: 1, fileModifiedAt: nil
    )

    let service = UsageAggregationService(store: store, registry: registry)
    // last7Days: current period is [now-6, now], so the previous-period
    // event 10 days back falls just outside the current range and inside
    // the immediately preceding 7-day window.
    let snapshot = try service.insightsSnapshot(
        visibleSourceFilter: [.claudeCode],
        range: .last7Days,
        now: now
    )

    #expect(snapshot.totals.costUSD == 4)
    #expect(snapshot.previousTotals.costUSD == 5)
}

@Test func insightsSnapshotTodayRangeComparesAgainstYesterday() throws {
    let registry = AdapterRegistry()
    let claude = AgentSourceDescriptor(
        id: .claudeCode,
        displayName: "Claude Code",
        shortLabel: "Claude",
        iconSystemName: "sparkles",
        tintColorHex: "#C15F3C",
        sortOrder: 0
    )
    registry.register(EmptyAdapter(descriptor: claude))

    let store = GRDBUsageEventStore(database: try UsageDatabase())
    try store.ensureSourceRegistered(claude)

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 15, hour: 12)))
    let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: now))
    let twoDaysAgo = try #require(calendar.date(byAdding: .day, value: -2, to: now))

    for (index, entry) in [(now, Decimal(4)), (yesterday, Decimal(5)), (twoDaysAgo, Decimal(9))].enumerated() {
        let event = UsageEvent(
            sourceID: .claudeCode,
            timestamp: entry.0,
            sessionID: "session-\(index)",
            projectOrWorkspace: "project-a",
            requestID: nil,
            model: "claude-haiku",
            modelFamily: "claude-haiku",
            tokens: TokenCounts(input: 10, output: 5),
            costUSD: entry.1,
            costIsEstimated: false,
            dedupKey: "event-\(index)",
            sourceFilePath: "/tmp/claude.jsonl",
            sourceFileLine: index
        )
        try store.applyParseResult(
            ParseResult(events: [event], newCheckpoint: .start),
            file: DiscoveredFile(path: "/tmp/claude.jsonl", sourceID: .claudeCode),
            fileSize: 1, fileModifiedAt: nil
        )
    }

    let service = UsageAggregationService(store: store, registry: registry)
    let snapshot = try service.insightsSnapshot(
        visibleSourceFilter: [.claudeCode],
        range: .today,
        now: now
    )

    #expect(snapshot.totals.costUSD == 4)
    #expect(snapshot.previousTotals.costUSD == 5)
    #expect(snapshot.activeDayCount == 1)
    #expect(snapshot.rangeStartDay == snapshot.rangeEndDay)
}

@Test func insightsSnapshotReturnsEmptyWhenNoVisibleSources() throws {
    let registry = AdapterRegistry()
    let store = GRDBUsageEventStore(database: try UsageDatabase())
    let service = UsageAggregationService(store: store, registry: registry)

    let snapshot = try service.insightsSnapshot(
        visibleSourceFilter: [],
        range: .last7Days,
        now: Date(timeIntervalSince1970: 1_700_000_000)
    )

    #expect(snapshot.totals.eventCount == 0)
    #expect(snapshot.projects.isEmpty)
}

private struct EmptyAdapter: UsageSourceAdapter {
    let descriptor: AgentSourceDescriptor

    func discoverRootDirectories() -> [URL] { [] }
    func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] { [] }
    func parseIncrementally(fileAt path: String, from checkpoint: ParseCheckpoint?, pricing: PricingProvider) throws -> ParseResult {
        ParseResult(events: [], newCheckpoint: .start)
    }
}

private func usageEvent(costIsEstimated: Bool = false) -> UsageEvent {
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
        costIsEstimated: costIsEstimated,
        dedupKey: "event",
        sourceFilePath: "/tmp/usage.jsonl",
        sourceFileLine: 1
    )
}
