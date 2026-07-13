import GRDB

enum V3UsageSync {
    static func migrate(_ db: GRDB.Database) throws {
        try db.execute(sql: """
            CREATE TABLE local_device (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                id TEXT NOT NULL UNIQUE,
                display_name TEXT NOT NULL,
                created_at TEXT NOT NULL,
                last_synced_at TEXT
            );

            CREATE TABLE synced_device (
                id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                last_synced_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE synced_usage_bucket (
                device_id TEXT NOT NULL REFERENCES synced_device(id) ON DELETE CASCADE,
                hour_utc TEXT NOT NULL,
                source_id TEXT NOT NULL,
                model_family TEXT NOT NULL,
                input_tokens INTEGER NOT NULL DEFAULT 0,
                output_tokens INTEGER NOT NULL DEFAULT 0,
                cache_create_tokens INTEGER NOT NULL DEFAULT 0,
                cache_read_tokens INTEGER NOT NULL DEFAULT 0,
                reasoning_tokens INTEGER NOT NULL DEFAULT 0,
                cost_usd REAL NOT NULL DEFAULT 0,
                event_count INTEGER NOT NULL DEFAULT 0,
                estimated_event_count INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (device_id, hour_utc, source_id, model_family)
            );

            CREATE INDEX idx_synced_usage_bucket_range
                ON synced_usage_bucket(hour_utc, device_id, source_id);

            CREATE TABLE sync_dirty_day (
                day_utc TEXT PRIMARY KEY,
                revision INTEGER NOT NULL DEFAULT 1
            );

            CREATE TABLE sync_published_day (
                day_utc TEXT PRIMARY KEY,
                checksum TEXT NOT NULL
            );

            CREATE TABLE sync_remote_day (
                device_id TEXT NOT NULL REFERENCES synced_device(id) ON DELETE CASCADE,
                day_utc TEXT NOT NULL,
                checksum TEXT NOT NULL,
                PRIMARY KEY (device_id, day_utc)
            );

            INSERT OR IGNORE INTO sync_dirty_day(day_utc)
            SELECT DISTINCT substr(timestamp_utc, 1, 10)
            FROM usage_event;
            """)
    }
}
