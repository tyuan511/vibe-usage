import Foundation
import GRDB
import VibeUsageCore

extension GRDBUsageEventStore {
    public func localDevice(defaultName: String) throws -> SyncedUsageDevice {
        try dbQueue.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT id, display_name, last_synced_at FROM local_device WHERE singleton = 1") {
                return SyncedUsageDevice(
                    id: row["id"],
                    name: row["display_name"],
                    lastSyncedAt: row["last_synced_at"],
                    isLocal: true
                )
            }
            let id = UUID().uuidString.lowercased()
            try db.execute(
                sql: "INSERT INTO local_device(singleton, id, display_name, created_at) VALUES (1, ?, ?, ?)",
                arguments: [id, defaultName, Date()]
            )
            return SyncedUsageDevice(id: id, name: defaultName, lastSyncedAt: nil, isLocal: true)
        }
    }

    public func renameLocalDevice(_ name: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE local_device SET display_name = ? WHERE singleton = 1", arguments: [name])
        }
    }

    public func markLocalDeviceSynced(at date: Date) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE local_device SET last_synced_at = ? WHERE singleton = 1", arguments: [date])
        }
    }

    public func allUsageDevices() throws -> [SyncedUsageDevice] {
        try dbQueue.read { db in
            var devices: [SyncedUsageDevice] = []
            if let row = try Row.fetchOne(db, sql: "SELECT id, display_name, last_synced_at FROM local_device WHERE singleton = 1") {
                devices.append(SyncedUsageDevice(
                    id: row["id"],
                    name: row["display_name"],
                    lastSyncedAt: row["last_synced_at"],
                    isLocal: true
                ))
            }
            let remoteRows = try Row.fetchAll(
                db,
                sql: "SELECT id, display_name, last_synced_at FROM synced_device ORDER BY display_name COLLATE NOCASE"
            )
            devices.append(contentsOf: remoteRows.map {
                SyncedUsageDevice(
                    id: $0["id"],
                    name: $0["display_name"],
                    lastSyncedAt: $0["last_synced_at"],
                    isLocal: false
                )
            })
            return devices
        }
    }

    public func dirtySyncDays() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT day_utc FROM sync_dirty_day ORDER BY day_utc")
        }
    }

    public func dirtySyncDaySnapshots() throws -> [SyncDirtyDay] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT day_utc, revision FROM sync_dirty_day ORDER BY day_utc"
            ).map { SyncDirtyDay(day: $0["day_utc"], revision: $0["revision"]) }
        }
    }

    public func localHourlyBuckets(utcDay: String) throws -> [SyncedUsageBucket] {
        try dbQueue.read { db in
            guard let deviceID = try String.fetchOne(db, sql: "SELECT id FROM local_device WHERE singleton = 1") else {
                return []
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT strftime('%Y-%m-%dT%H:00:00Z', timestamp_utc) AS hour_utc,
                       source_id,
                       model_family,
                       SUM(input_tokens) AS input,
                       SUM(output_tokens) AS output,
                       SUM(cache_create_tokens) AS cache_create,
                       SUM(cache_read_tokens) AS cache_read,
                       SUM(reasoning_tokens) AS reasoning,
                       SUM(cost_usd) AS cost,
                       COUNT(*) AS event_count,
                       SUM(CASE WHEN cost_is_estimated = 1 THEN 1 ELSE 0 END) AS estimated_event_count
                FROM usage_event
                WHERE substr(timestamp_utc, 1, 10) = ?
                GROUP BY hour_utc, source_id, model_family
                ORDER BY hour_utc, source_id, model_family
                """, arguments: [utcDay])
            return rows.map { row in
                SyncedUsageBucket(
                    deviceID: deviceID,
                    hourUTC: row["hour_utc"],
                    sourceID: AgentSourceID(rawValue: row["source_id"]),
                    modelFamily: row["model_family"],
                    tokens: TokenCounts(
                        input: row["input"],
                        output: row["output"],
                        cacheCreate: row["cache_create"],
                        cacheRead: row["cache_read"],
                        reasoning: row["reasoning"]
                    ),
                    costUSD: Decimal(row["cost"] as Double),
                    eventCount: row["event_count"],
                    estimatedEventCount: row["estimated_event_count"]
                )
            }
        }
    }

    public func publishedDayChecksums() throws -> [String: String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT day_utc, checksum FROM sync_published_day")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["day_utc"] as String, $0["checksum"] as String) })
        }
    }

    public func markSyncDayPublished(_ day: String, checksum: String, expectedRevision: Int? = nil) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sync_published_day(day_utc, checksum) VALUES (?, ?)
                ON CONFLICT(day_utc) DO UPDATE SET checksum = excluded.checksum
                """, arguments: [day, checksum])
            if let expectedRevision {
                try db.execute(
                    sql: "DELETE FROM sync_dirty_day WHERE day_utc = ? AND revision = ?",
                    arguments: [day, expectedRevision]
                )
            } else {
                try db.execute(sql: "DELETE FROM sync_dirty_day WHERE day_utc = ?", arguments: [day])
            }
        }
    }

    public func removePublishedDay(_ day: String, expectedRevision: Int? = nil) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM sync_published_day WHERE day_utc = ?", arguments: [day])
            if let expectedRevision {
                try db.execute(
                    sql: "DELETE FROM sync_dirty_day WHERE day_utc = ? AND revision = ?",
                    arguments: [day, expectedRevision]
                )
            } else {
                try db.execute(sql: "DELETE FROM sync_dirty_day WHERE day_utc = ?", arguments: [day])
            }
        }
    }

    public func replaceRemoteDay(
        device: SyncedUsageDevice,
        utcDay: String,
        checksum: String,
        buckets: [SyncedUsageBucket]
    ) throws {
        try dbQueue.write { db in
            try upsertRemoteDevice(device, db: db)
            try db.execute(
                sql: "DELETE FROM synced_usage_bucket WHERE device_id = ? AND substr(hour_utc, 1, 10) = ?",
                arguments: [device.id, utcDay]
            )
            for bucket in buckets {
                try db.execute(sql: """
                    INSERT INTO synced_usage_bucket(
                        device_id, hour_utc, source_id, model_family,
                        input_tokens, output_tokens, cache_create_tokens, cache_read_tokens,
                        reasoning_tokens, cost_usd, event_count, estimated_event_count
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        device.id, bucket.hourUTC, bucket.sourceID.rawValue, bucket.modelFamily,
                        bucket.tokens.input, bucket.tokens.output, bucket.tokens.cacheCreate,
                        bucket.tokens.cacheRead, bucket.tokens.reasoning,
                        (bucket.costUSD as NSDecimalNumber).doubleValue,
                        bucket.eventCount, bucket.estimatedEventCount
                    ])
            }
            try db.execute(sql: """
                INSERT INTO sync_remote_day(device_id, day_utc, checksum) VALUES (?, ?, ?)
                ON CONFLICT(device_id, day_utc) DO UPDATE SET checksum = excluded.checksum
                """, arguments: [device.id, utcDay, checksum])
        }
    }

    public func updateRemoteDevice(_ device: SyncedUsageDevice) throws {
        try dbQueue.write { db in
            try upsertRemoteDevice(device, db: db)
        }
    }

    public func resetPublishedSyncState() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM sync_published_day")
            try db.execute(sql: """
                INSERT INTO sync_dirty_day(day_utc, revision)
                SELECT DISTINCT substr(timestamp_utc, 1, 10), 1
                FROM usage_event
                WHERE true
                ON CONFLICT(day_utc) DO UPDATE SET revision = revision + 1
                """)
        }
    }

    public func remoteDayChecksums(deviceID: String) throws -> [String: String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT day_utc, checksum FROM sync_remote_day WHERE device_id = ?",
                arguments: [deviceID]
            )
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["day_utc"] as String, $0["checksum"] as String) })
        }
    }

    public func removeRemoteDays(deviceID: String, notIn days: Set<String>) throws {
        try dbQueue.write { db in
            let existing = try String.fetchAll(
                db,
                sql: "SELECT day_utc FROM sync_remote_day WHERE device_id = ?",
                arguments: [deviceID]
            )
            for day in existing where !days.contains(day) {
                try db.execute(
                    sql: "DELETE FROM synced_usage_bucket WHERE device_id = ? AND substr(hour_utc, 1, 10) = ?",
                    arguments: [deviceID, day]
                )
                try db.execute(
                    sql: "DELETE FROM sync_remote_day WHERE device_id = ? AND day_utc = ?",
                    arguments: [deviceID, day]
                )
            }
        }
    }

    public func deleteRemoteDevice(_ deviceID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM synced_device WHERE id = ?", arguments: [deviceID])
        }
    }

    public func clearRemoteUsageCache() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM synced_device")
        }
    }

    public func knownUsageSourceIDs() throws -> Set<AgentSourceID> {
        try dbQueue.read { db in
            let values = try String.fetchAll(db, sql: """
                SELECT source_id FROM usage_event
                UNION
                SELECT source_id FROM synced_usage_bucket
                """)
            return Set(values.map { AgentSourceID(rawValue: $0) })
        }
    }

    private func upsertRemoteDevice(_ device: SyncedUsageDevice, db: GRDB.Database) throws {
        try db.execute(sql: """
            INSERT INTO synced_device(id, display_name, last_synced_at, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name,
                last_synced_at = excluded.last_synced_at,
                updated_at = excluded.updated_at
            """, arguments: [device.id, device.name, device.lastSyncedAt ?? Date(), Date()])
    }
}
