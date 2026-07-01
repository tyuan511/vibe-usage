import Foundation
import GRDB

/// Owns the SQLite connection and schema migrations for VibeUsage's local
/// cache. Named `UsageDatabase` (rather than `Database`) to avoid shadowing
/// GRDB's own `Database` type, which every query closure receives.
public final class UsageDatabase: Sendable {
    public let dbQueue: DatabaseQueue

    /// Opens (creating if necessary) the database file at `path` and applies
    /// any pending migrations.
    public init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        dbQueue = try DatabaseQueue(path: path, configuration: config)
        try Self.migrator.migrate(dbQueue)
    }

    /// In-memory database for tests and previews.
    public init() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(configuration: config)
        try Self.migrator.migrate(dbQueue)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial_schema") { db in
            try V1InitialSchema.migrate(db)
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
