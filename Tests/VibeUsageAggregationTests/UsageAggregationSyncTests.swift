import Foundation
import VibeUsageCore
import VibeUsageStorage
import XCTest
@testable import VibeUsageAggregation

final class UsageAggregationSyncTests: XCTestCase {
    func testDashboardSnapshotFiltersAndBreaksDownSyncedDevices() throws {
        let registry = AdapterRegistry()
        let claude = AgentSourceDescriptor(
            id: .claudeCode,
            displayName: "Claude Code",
            shortLabel: "Claude",
            iconSystemName: "circle",
            tintColorHex: "#000000",
            sortOrder: 0
        )
        registry.register(SyncTestAdapter(descriptor: claude))
        let store = GRDBUsageEventStore(database: try UsageDatabase())
        try store.ensureSourceRegistered(claude)
        _ = try store.localDevice(defaultName: "Work Mac")
        let now = Date()
        let local = UsageEvent(
            sourceID: .claudeCode,
            timestamp: now,
            sessionID: "local",
            projectOrWorkspace: nil,
            requestID: nil,
            model: "claude-sonnet-4",
            modelFamily: "claude-sonnet-4",
            tokens: TokenCounts(input: 100),
            costUSD: 1,
            costIsEstimated: false,
            dedupKey: "local-device-event",
            sourceFilePath: "/tmp/local-device.jsonl",
            sourceFileLine: 1
        )
        try store.applyParseResult(
            ParseResult(events: [local], newCheckpoint: .start),
            file: DiscoveredFile(path: local.sourceFilePath, sourceID: local.sourceID),
            fileSize: 1,
            fileModifiedAt: nil
        )
        let remote = SyncedUsageDevice(id: "home", name: "Home Mac", lastSyncedAt: now, isLocal: false)
        let utcTimeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let utcDay = ISO8601DateFormatter.string(
            from: now,
            timeZone: utcTimeZone,
            formatOptions: [.withFullDate]
        )
        let hour = ISO8601DateFormatter.string(
            from: now,
            timeZone: utcTimeZone,
            formatOptions: [.withInternetDateTime]
        )
        let hourPrefix = String(hour.prefix(13)) + ":00:00Z"
        try store.replaceRemoteDay(
            device: remote,
            utcDay: utcDay,
            checksum: "remote",
            buckets: [SyncedUsageBucket(
                deviceID: remote.id,
                hourUTC: hourPrefix,
                sourceID: .claudeCode,
                modelFamily: "claude-sonnet-4",
                tokens: TokenCounts(input: 300),
                costUSD: 3,
                eventCount: 2,
                estimatedEventCount: 0
            )]
        )

        let snapshot = try UsageAggregationService(store: store, registry: registry).dashboardSnapshot(
            visibleSourceFilter: [.claudeCode],
            visibleDeviceFilter: [remote.id],
            dateRange: .today,
            now: now
        )

        XCTAssertEqual(snapshot.totals.tokens.input, 300)
        XCTAssertEqual(snapshot.totals.eventCount, 2)
        XCTAssertEqual(snapshot.devices.map(\.name), ["Home Mac"])
        XCTAssertEqual(snapshot.devices[0].totals.tokens.input, 300)
    }
}

private struct SyncTestAdapter: UsageSourceAdapter {
    let descriptor: AgentSourceDescriptor

    func discoverRootDirectories() -> [URL] { [] }
    func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] { [] }
    func parseIncrementally(
        fileAt path: String,
        from checkpoint: ParseCheckpoint?,
        pricing: PricingProvider
    ) throws -> ParseResult {
        ParseResult(events: [], newCheckpoint: .start)
    }
}
