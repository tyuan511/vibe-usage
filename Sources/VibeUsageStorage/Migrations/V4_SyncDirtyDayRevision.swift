import GRDB

enum V4SyncDirtyDayRevision {
    static func migrate(_ db: GRDB.Database) throws {
        let hasRevision = try db.columns(in: "sync_dirty_day").contains { column in
            column.name == "revision"
        }
        guard !hasRevision else { return }

        try db.alter(table: "sync_dirty_day") { table in
            table.add(column: "revision", .integer).notNull().defaults(to: 1)
        }
    }
}
