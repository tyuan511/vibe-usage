import Foundation
import GRDB
import VibeUsageCore

/// Owns the SQLite connection and schema migrations for VibeUsage's local
/// cache. Named `UsageDatabase` (rather than `Database`) to avoid shadowing
/// GRDB's own `Database` type, which every query closure receives.
public final class UsageDatabase: Sendable {
    public let dbQueue: DatabaseQueue

    /// Opens (creating if necessary) the database file at `path` and applies
    /// any pending migrations.
    public init(path: String) throws {
        do {
            var config = Configuration()
            config.foreignKeysEnabled = true
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            }
            dbQueue = try DatabaseQueue(path: path, configuration: config)
            try Self.migrator.migrate(dbQueue)
        } catch {
            throw VibeUsageError.databaseError(underlying: error.localizedDescription)
        }
    }

    /// In-memory database for tests and previews.
    public init() throws {
        do {
            var config = Configuration()
            config.foreignKeysEnabled = true
            dbQueue = try DatabaseQueue(configuration: config)
            try Self.migrator.migrate(dbQueue)
        } catch {
            throw VibeUsageError.databaseError(underlying: error.localizedDescription)
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial_schema") { db in
            try V1InitialSchema.migrate(db)
        }
        migrator.registerMigration("v2_reindex_codex_fork_replays") { db in
            try V2ReindexCodexForkReplays.migrate(db)
        }
        migrator.registerMigration("v3_usage_sync") { db in
            try V3UsageSync.migrate(db)
        }
        migrator.registerMigration("v4_sync_dirty_day_revision") { db in
            try V4SyncDirtyDayRevision.migrate(db)
        }
        return migrator
    }

    /// `~/Library/Application Support/VibeUsage/usage.sqlite`, created on demand.
    public static func defaultStorePath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("VibeUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage.sqlite").path
    }
}
