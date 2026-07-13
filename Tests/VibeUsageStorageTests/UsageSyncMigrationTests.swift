import Foundation
import GRDB
import XCTest
@testable import VibeUsageStorage

final class UsageSyncMigrationTests: XCTestCase {
    func testUpgradesLegacyV3DirtyDayTableWithRevisionColumn() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("usage.sqlite").path

        do {
            let legacyQueue = try DatabaseQueue(path: path)
            var legacyMigrator = DatabaseMigrator()
            legacyMigrator.registerMigration("v1_initial_schema") { db in
                try V1InitialSchema.migrate(db)
            }
            legacyMigrator.registerMigration("v2_reindex_codex_fork_replays") { db in
                try V2ReindexCodexForkReplays.migrate(db)
            }
            legacyMigrator.registerMigration("v3_usage_sync") { db in
                try V3UsageSync.migrate(db)
                try db.execute(sql: "ALTER TABLE sync_dirty_day DROP COLUMN revision")
            }
            try legacyMigrator.migrate(legacyQueue)
            try legacyQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO sync_dirty_day(day_utc) VALUES (?)",
                    arguments: ["2026-07-13"]
                )
            }
        }

        let upgraded = try UsageDatabase(path: path)
        let store = GRDBUsageEventStore(database: upgraded)
        XCTAssertEqual(
            try store.dirtySyncDaySnapshots(),
            [SyncDirtyDay(day: "2026-07-13", revision: 1)]
        )
    }
}
