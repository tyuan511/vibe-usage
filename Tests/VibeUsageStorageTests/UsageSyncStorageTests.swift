import Foundation
import VibeUsageCore
import XCTest
@testable import VibeUsageStorage

final class UsageSyncStorageTests: XCTestCase {
    func testLocalEventsBecomeDirtyHourlyBucketsAndMergeWithRemoteDevices() throws {
        let store = GRDBUsageEventStore(database: try UsageDatabase())
        try store.ensureSourceRegistered(AgentSourceDescriptor(
            id: .claudeCode,
            displayName: "Claude Code",
            shortLabel: "Claude",
            iconSystemName: "circle",
            tintColorHex: "#000000",
            sortOrder: 0
        ))
        let localDevice = try store.localDevice(defaultName: "Work Mac")
        XCTAssertEqual(try store.localDevice(defaultName: "Ignored").id, localDevice.id)
        XCTAssertEqual(localDevice.name, "Work Mac")

        let timestamp = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-13T08:15:00Z"))
        let event = UsageEvent(
            sourceID: .claudeCode,
            timestamp: timestamp,
            sessionID: "session",
            projectOrWorkspace: nil,
            requestID: nil,
            model: "claude-sonnet-4",
            modelFamily: "claude-sonnet-4",
            tokens: TokenCounts(input: 100, output: 25, cacheRead: 50),
            costUSD: Decimal(string: "0.25")!,
            costIsEstimated: true,
            dedupKey: "sync-event",
            sourceFilePath: "/tmp/sync.jsonl",
            sourceFileLine: 1
        )
        try store.applyParseResult(
            ParseResult(events: [event], newCheckpoint: .start),
            file: DiscoveredFile(path: event.sourceFilePath, sourceID: event.sourceID),
            fileSize: 1,
            fileModifiedAt: nil
        )

        XCTAssertEqual(try store.dirtySyncDays(), ["2026-07-13"])
        let localBuckets = try store.localHourlyBuckets(utcDay: "2026-07-13")
        XCTAssertEqual(localBuckets.count, 1)
        XCTAssertEqual(localBuckets[0].hourUTC, "2026-07-13T08:00:00Z")
        XCTAssertEqual(localBuckets[0].tokens, event.tokens)
        XCTAssertEqual(localBuckets[0].eventCount, 1)
        XCTAssertEqual(localBuckets[0].estimatedEventCount, 1)
        try store.markSyncDayPublished("2026-07-13", checksum: "old-target")
        XCTAssertTrue(try store.dirtySyncDays().isEmpty)
        try store.resetPublishedSyncState()
        XCTAssertEqual(try store.dirtySyncDays(), ["2026-07-13"])
        let inFlight = try XCTUnwrap(try store.dirtySyncDaySnapshots().first)
        let concurrentEvent = UsageEvent(
            sourceID: .claudeCode,
            timestamp: timestamp,
            sessionID: "concurrent",
            projectOrWorkspace: nil,
            requestID: nil,
            model: "claude-sonnet-4",
            modelFamily: "claude-sonnet-4",
            tokens: TokenCounts(input: 1),
            costUSD: 0,
            costIsEstimated: false,
            dedupKey: "concurrent-event",
            sourceFilePath: "/tmp/concurrent.jsonl",
            sourceFileLine: 1
        )
        try store.applyParseResult(
            ParseResult(events: [concurrentEvent], newCheckpoint: .start),
            file: DiscoveredFile(path: concurrentEvent.sourceFilePath, sourceID: concurrentEvent.sourceID),
            fileSize: 1,
            fileModifiedAt: nil
        )
        try store.markSyncDayPublished(
            inFlight.day,
            checksum: "stale-snapshot",
            expectedRevision: inFlight.revision
        )
        XCTAssertEqual(try store.dirtySyncDays(), ["2026-07-13"])

        let remote = SyncedUsageDevice(
            id: "device-b",
            name: "Home Mac",
            lastSyncedAt: timestamp,
            isLocal: false
        )
        try store.replaceRemoteDay(
            device: remote,
            utcDay: "2026-07-13",
            checksum: "checksum-b",
            buckets: [
                SyncedUsageBucket(
                    deviceID: remote.id,
                    hourUTC: "2026-07-13T09:00:00Z",
                    sourceID: .claudeCode,
                    modelFamily: "claude-sonnet-4",
                    tokens: TokenCounts(input: 200, output: 50),
                    costUSD: Decimal(string: "0.50")!,
                    eventCount: 2,
                    estimatedEventCount: 0
                )
            ]
        )

        let daily = try store.dailySummaries(
            sourceFilter: [.claudeCode],
            startDay: "2026-07-13",
            endDay: "2026-07-13"
        )
        XCTAssertEqual(daily.count, 1)
        XCTAssertEqual(daily[0].tokens.input, 301)
        XCTAssertEqual(daily[0].costUSD, Decimal(string: "0.75"))

        let devices = try store.deviceBreakdown(
            deviceFilter: [],
            sourceFilter: [.claudeCode],
            startDay: "2026-07-13",
            endDay: "2026-07-13"
        )
        XCTAssertEqual(devices.map(\.name), ["Home Mac", "Work Mac"])
        XCTAssertEqual(devices.first { $0.device.id == remote.id }?.tokens.input, 200)
        XCTAssertEqual(devices.first { $0.device.id == localDevice.id }?.tokens.input, 101)
    }
}
