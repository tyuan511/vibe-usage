import Foundation
import VibeUsageCore
import XCTest
@testable import VibeUsageSync

final class SyncDocumentsTests: XCTestCase {
    func testDayDocumentRoundTripsExactUsageValues() throws {
        let document = SyncDayDocument(
            deviceID: "device-a",
            day: "2026-07-13",
            generatedAt: Date(timeIntervalSince1970: 1_768_176_000),
            buckets: [
                SyncUsageBucket(
                    hourUTC: "2026-07-13T08:00:00Z",
                    sourceID: .claudeCode,
                    modelFamily: "claude-sonnet-4",
                    tokens: TokenCounts(input: 120, output: 30, cacheCreate: 4, cacheRead: 90, reasoning: 2),
                    costUSD: Decimal(string: "0.012345")!,
                    eventCount: 3,
                    estimatedEventCount: 1
                )
            ]
        )

        let encoded = try SyncDocumentCodec.encode(document)
        let decoded = try SyncDocumentCodec.decodeDay(encoded)

        XCTAssertEqual(decoded, document)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let buckets = try XCTUnwrap(object["buckets"] as? [[String: Any]])
        XCTAssertEqual(buckets[0]["costUSD"] as? String, "0.012345")
    }

    func testRejectsUnsupportedSchemaVersion() throws {
        let data = Data(#"{"schemaVersion":99,"deviceID":"d","day":"2026-07-13","generatedAt":"2026-07-13T00:00:00Z","buckets":[]}"#.utf8)

        XCTAssertThrowsError(try SyncDocumentCodec.decodeDay(data)) { error in
            XCTAssertEqual(error as? SyncDocumentError, .unsupportedSchemaVersion(99))
        }
    }

    func testNamespaceBuildsStableDailyKeys() {
        XCTAssertEqual(SyncNamespace.root, "vibeusage/sync/v1")
        XCTAssertEqual(SyncNamespace.profileKey(deviceID: "device-a"), "vibeusage/sync/v1/devices/device-a/profile.json")
        XCTAssertEqual(SyncNamespace.indexKey(deviceID: "device-a"), "vibeusage/sync/v1/devices/device-a/index.json")
        XCTAssertEqual(SyncNamespace.dayKey(deviceID: "device-a", day: "2026-07-13"), "vibeusage/sync/v1/devices/device-a/days/2026-07-13.json")
    }

    func testRejectsHourBucketOutsideDocumentDay() throws {
        let data = try SyncDocumentCodec.encode(SyncDayDocument(
            deviceID: "device-a",
            day: "2026-07-13",
            generatedAt: Date(timeIntervalSince1970: 1_768_176_000),
            buckets: [SyncUsageBucket(
                hourUTC: "2026-07-14T00:00:00Z",
                sourceID: .claudeCode,
                modelFamily: "claude-sonnet-4",
                tokens: TokenCounts(input: 1),
                costUSD: 0,
                eventCount: 1,
                estimatedEventCount: 0
            )]
        ))

        XCTAssertThrowsError(try SyncDocumentCodec.decodeDay(data))
    }
}
