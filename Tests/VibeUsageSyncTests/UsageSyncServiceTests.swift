import Foundation
import VibeUsageCore
import VibeUsageStorage
import XCTest
@testable import VibeUsageSync

final class UsageSyncServiceTests: XCTestCase {
    func testSyncPublishesLocalDirtyDaysAndImportsRemoteDevice() async throws {
        let usageStore = GRDBUsageEventStore(database: try UsageDatabase())
        try usageStore.ensureSourceRegistered(AgentSourceDescriptor(
            id: .claudeCode,
            displayName: "Claude Code",
            shortLabel: "Claude",
            iconSystemName: "circle",
            tintColorHex: "#000000",
            sortOrder: 0
        ))
        let local = try usageStore.localDevice(defaultName: "Work Mac")
        let timestamp = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-13T08:15:00Z"))
        let event = UsageEvent(
            sourceID: .claudeCode,
            timestamp: timestamp,
            sessionID: "session",
            projectOrWorkspace: nil,
            requestID: nil,
            model: "claude-sonnet-4",
            modelFamily: "claude-sonnet-4",
            tokens: TokenCounts(input: 100, output: 20),
            costUSD: Decimal(string: "0.2")!,
            costIsEstimated: false,
            dedupKey: "event",
            sourceFilePath: "/tmp/sync-service.jsonl",
            sourceFileLine: 1
        )
        try usageStore.applyParseResult(
            ParseResult(events: [event], newCheckpoint: .start),
            file: DiscoveredFile(path: event.sourceFilePath, sourceID: event.sourceID),
            fileSize: 1,
            fileModifiedAt: nil
        )

        let objectStore = MemoryObjectStore()
        let remoteDay = SyncDayDocument(
            deviceID: "remote-device",
            day: "2026-07-13",
            generatedAt: timestamp,
            buckets: [
                SyncUsageBucket(
                    hourUTC: "2026-07-13T09:00:00Z",
                    sourceID: .claudeCode,
                    modelFamily: "claude-sonnet-4",
                    tokens: TokenCounts(input: 300, output: 60),
                    costUSD: Decimal(string: "0.6")!,
                    eventCount: 2,
                    estimatedEventCount: 0
                )
            ]
        )
        let remoteDayData = try SyncDocumentCodec.encode(remoteDay)
        let remoteChecksum = SyncDocumentCodec.checksum(remoteDayData)
        try await objectStore.write(
            key: SyncNamespace.profileKey(deviceID: "remote-device"),
            data: try SyncDocumentCodec.encode(SyncProfileDocument(
                deviceID: "remote-device",
                name: "Home Mac",
                lastSyncedAt: timestamp
            ))
        )
        try await objectStore.write(
            key: SyncNamespace.indexKey(deviceID: "remote-device"),
            data: try SyncDocumentCodec.encode(SyncIndexDocument(
                deviceID: "remote-device",
                updatedAt: timestamp,
                days: [SyncDayReference(day: "2026-07-13", checksum: remoteChecksum)]
            ))
        )
        try await objectStore.write(
            key: SyncNamespace.dayKey(deviceID: "remote-device", day: "2026-07-13"),
            data: remoteDayData
        )

        let service = UsageSyncService(usageStore: usageStore, now: { timestamp })
        let result = try await service.synchronize(with: objectStore, defaultDeviceName: "Ignored")

        XCTAssertEqual(result.uploadedDays, 1)
        XCTAssertEqual(result.downloadedDays, 1)
        XCTAssertTrue(try usageStore.dirtySyncDays().isEmpty)
        XCTAssertTrue(objectStore.contains(SyncNamespace.dayKey(deviceID: local.id, day: "2026-07-13")))
        let localIndex = try SyncDocumentCodec.decodeIndex(
            try await objectStore.read(key: SyncNamespace.indexKey(deviceID: local.id)).data
        )
        XCTAssertEqual(localIndex.days.map(\.day), ["2026-07-13"])

        let merged = try usageStore.dailySummaries(
            sourceFilter: [.claudeCode],
            startDay: "2026-07-13",
            endDay: "2026-07-13"
        )
        XCTAssertEqual(merged[0].tokens.input, 400)
        XCTAssertEqual(try usageStore.allUsageDevices().map(\.name).sorted(), ["Home Mac", "Work Mac"])

        try await objectStore.write(
            key: SyncNamespace.profileKey(deviceID: "remote-device"),
            data: try SyncDocumentCodec.encode(SyncProfileDocument(
                deviceID: "remote-device",
                name: "Renamed Home Mac",
                lastSyncedAt: timestamp
            ))
        )
        let renameOnlyResult = try await service.synchronize(with: objectStore, defaultDeviceName: "Ignored")
        XCTAssertEqual(renameOnlyResult.downloadedDays, 0)
        XCTAssertTrue(try usageStore.allUsageDevices().contains { $0.name == "Renamed Home Mac" })
    }
}

private final class MemoryObjectStore: SyncObjectStore, @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [String: Data] = [:]

    func validateAccess() async throws {}

    func list(prefix: String) async throws -> [SyncObjectMetadata] {
        lock.withLock {
            objects.keys.filter { $0.hasPrefix(prefix) }.sorted().map { SyncObjectMetadata(key: $0) }
        }
    }

    func read(key: String) async throws -> SyncObject {
        try lock.withLock {
            guard let data = objects[key] else { throw SyncObjectStoreError.notFound(key) }
            return SyncObject(data: data, etag: nil)
        }
    }

    func write(key: String, data: Data) async throws {
        lock.withLock { objects[key] = data }
    }

    func delete(key: String) async throws {
        lock.withLock { _ = objects.removeValue(forKey: key) }
    }

    func contains(_ key: String) -> Bool {
        lock.withLock { objects[key] != nil }
    }
}
