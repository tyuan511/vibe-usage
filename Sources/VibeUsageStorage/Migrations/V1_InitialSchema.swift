import GRDB

/// Initial schema: source lookup table, normalized usage events (deduplicated,
/// post-delta-computation), and per-file incremental-parse checkpoints.
/// See the architecture plan for the rationale behind each column.
enum V1InitialSchema {
    static func migrate(_ db: GRDB.Database) throws {
        try db.execute(sql: """
        CREATE TABLE agent_source (
            id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            first_seen_at TEXT NOT NULL
        );
        """)

        try db.execute(sql: """
        CREATE TABLE usage_event (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source_id TEXT NOT NULL REFERENCES agent_source(id),
            dedup_key TEXT NOT NULL,
            is_sidechain_replay INTEGER,
            timestamp_utc TEXT NOT NULL,
            session_id TEXT NOT NULL,
            project_or_workspace TEXT,
            request_id TEXT,
            model_raw TEXT NOT NULL,
            model_family TEXT NOT NULL,
            input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            cache_create_tokens INTEGER NOT NULL DEFAULT 0,
            cache_read_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_tokens INTEGER NOT NULL DEFAULT 0,
            cost_usd REAL NOT NULL,
            cost_is_estimated INTEGER NOT NULL DEFAULT 0,
            source_file_path TEXT NOT NULL,
            source_file_line INTEGER,
            created_at TEXT NOT NULL
        );
        """)
        try db.execute(sql: "CREATE UNIQUE INDEX idx_usage_event_dedup ON usage_event(source_id, dedup_key);")
        try db.execute(sql: "CREATE INDEX idx_usage_event_day ON usage_event(source_id, timestamp_utc);")
        try db.execute(sql: "CREATE INDEX idx_usage_event_model ON usage_event(model_family, timestamp_utc);")
        try db.execute(sql: "CREATE INDEX idx_usage_event_file ON usage_event(source_file_path);")

        try db.execute(sql: """
        CREATE TABLE file_parse_state (
            file_path TEXT PRIMARY KEY,
            source_id TEXT NOT NULL REFERENCES agent_source(id),
            byte_offset INTEGER NOT NULL DEFAULT 0,
            line_index INTEGER NOT NULL DEFAULT 0,
            file_size_at_parse INTEGER NOT NULL DEFAULT 0,
            file_mtime_at_parse TEXT,
            adapter_state_json TEXT,
            updated_at TEXT NOT NULL
        );
        """)
    }
}
