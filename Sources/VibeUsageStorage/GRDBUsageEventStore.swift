import Foundation
import GRDB
import VibeUsageCore

/// GRDB-backed implementation of `UsageEventStore`, plus the raw aggregate
/// query methods that `VibeUsageAggregation` builds view-model DTOs on top of.
public final class GRDBUsageEventStore: UsageEventStore, Sendable {
    let dbQueue: DatabaseQueue

    public init(database: UsageDatabase) {
        self.dbQueue = database.dbQueue
    }

    // MARK: - UsageEventStore

    public func ensureSourceRegistered(_ descriptor: AgentSourceDescriptor) throws {
        try dbQueue.write { db in
            if try AgentSourceRecord.filter(key: descriptor.id.rawValue).fetchOne(db) == nil {
                try AgentSourceRecord(
                    id: descriptor.id.rawValue,
                    displayName: descriptor.displayName,
                    firstSeenAt: Date()
                ).insert(db)
            }
        }
    }

    public func fileMetadata(forFile path: String) throws -> FileParseMetadata? {
        try dbQueue.read { db in
            try FileParseStateRecord.filter(key: path).fetchOne(db)?.toMetadata()
        }
    }

    public func fileMetadata(forFiles paths: [String]) throws -> [String: FileParseMetadata] {
        guard !paths.isEmpty else { return [:] }
        let uniquePaths = Array(Set(paths))
        return try dbQueue.read { db in
            let records = try FileParseStateRecord
                .filter(uniquePaths.contains(Column("file_path")))
                .fetchAll(db)
            var result: [String: FileParseMetadata] = [:]
            result.reserveCapacity(records.count)
            for record in records {
                result[record.filePath] = record.toMetadata()
            }
            return result
        }
    }

    public func applyParseResult(
        _ result: ParseResult,
        file: DiscoveredFile,
        fileSize: Int64,
        fileModifiedAt: Date?
    ) throws {
        try applyParseResults([
            FileParseApplication(
                result: result,
                file: file,
                fileSize: fileSize,
                fileModifiedAt: fileModifiedAt
            )
        ])
    }

    public func applyParseResults(_ applications: [FileParseApplication]) throws {
        guard !applications.isEmpty else { return }
        try dbQueue.write { db in
            let incomingEvents = Self.coalescedEvents(in: applications)
            let existingRecords = try Self.existingRecords(for: incomingEvents, db: db)
            var dirtyDayRevisions: [String: Int] = [:]

            for event in incomingEvents {
                let identity = UsageEventIdentity(event)
                if let existing = existingRecords[identity] {
                    guard DedupPolicy.shouldReplace(
                        existing: existing.toUsageEvent(),
                        candidate: event
                    ) else { continue }
                    var replacement = UsageEventRecord(event: event)
                    replacement.id = existing.id
                    try replacement.update(db)
                    dirtyDayRevisions[Self.utcDayString(existing.timestampUtc), default: 0] += 1
                    dirtyDayRevisions[Self.utcDayString(event.timestamp), default: 0] += 1
                } else {
                    try UsageEventRecord(event: event).insert(db)
                    dirtyDayRevisions[Self.utcDayString(event.timestamp), default: 0] += 1
                }
            }

            for (day, revisionIncrement) in dirtyDayRevisions {
                try Self.markSyncDayDirty(
                    dayUTC: day,
                    revisionIncrement: revisionIncrement,
                    db: db
                )
            }

            for application in applications {
                try Self.upsertFileState(
                    filePath: application.file.path,
                    sourceID: application.file.sourceID,
                    checkpoint: application.result.newCheckpoint,
                    fileSize: application.fileSize,
                    fileModifiedAt: application.fileModifiedAt,
                    db: db
                )
            }
        }
    }

    public func repriceEstimatedEvents(using pricing: any PricingProvider) throws -> Int {
        try dbQueue.write { db in
            let records = try UsageEventRecord
                .filter(Column("cost_is_estimated") == true)
                .fetchAll(db)
            var updatedCount = 0

            for var record in records {
                guard let rate = pricing.rate(forModelFamily: record.modelFamily, at: record.timestampUtc) else {
                    continue
                }
                let wasUnpriced = record.costUsd == 0
                let sourceID = AgentSourceID(rawValue: record.sourceId)
                let updatedCost = (CostCalculator.cost(for: record.tokens, sourceID: sourceID, rate: rate) as NSDecimalNumber).doubleValue
                let remainsEstimated = !wasUnpriced
                guard record.costUsd != updatedCost || record.costIsEstimated != remainsEstimated else {
                    continue
                }
                record.costUsd = updatedCost
                record.costIsEstimated = remainsEstimated
                try record.update(db)
                try Self.markSyncDayDirty(for: record.timestampUtc, db: db)
                updatedCount += 1
            }
            return updatedCount
        }
    }

    public func resetFile(_ path: String) throws {
        try dbQueue.write { db in
            let dates = try Date.fetchAll(
                db,
                sql: "SELECT timestamp_utc FROM usage_event WHERE source_file_path = ?",
                arguments: [path]
            )
            try UsageEventRecord.filter(Column("source_file_path") == path).deleteAll(db)
            try FileParseStateRecord.filter(key: path).deleteAll(db)
            for date in dates {
                try Self.markSyncDayDirty(for: date, db: db)
            }
        }
    }

    // MARK: - Upsert internals

    private static func coalescedEvents(in applications: [FileParseApplication]) -> [UsageEvent] {
        var order: [UsageEventIdentity] = []
        var eventsByIdentity: [UsageEventIdentity: UsageEvent] = [:]
        for application in applications {
            for event in application.result.events {
                let identity = UsageEventIdentity(event)
                if let existing = eventsByIdentity[identity] {
                    if DedupPolicy.shouldReplace(existing: existing, candidate: event) {
                        eventsByIdentity[identity] = event
                    }
                } else {
                    order.append(identity)
                    eventsByIdentity[identity] = event
                }
            }
        }
        return order.compactMap { eventsByIdentity[$0] }
    }

    private static func existingRecords(
        for events: [UsageEvent],
        db: GRDB.Database
    ) throws -> [UsageEventIdentity: UsageEventRecord] {
        let keysBySource = Dictionary(grouping: events, by: { $0.sourceID.rawValue })
            .mapValues { Set($0.map(\.dedupKey)) }
        var recordsByIdentity: [UsageEventIdentity: UsageEventRecord] = [:]
        for (sourceID, keys) in keysBySource {
            let keys = Array(keys)
            for start in stride(from: 0, to: keys.count, by: 400) {
                let chunk = Array(keys[start..<min(start + 400, keys.count)])
                let records = try UsageEventRecord
                    .filter(Column("source_id") == sourceID)
                    .filter(chunk.contains(Column("dedup_key")))
                    .fetchAll(db)
                for record in records {
                    recordsByIdentity[UsageEventIdentity(record)] = record
                }
            }
        }
        return recordsByIdentity
    }

    private static func markSyncDayDirty(for date: Date, db: GRDB.Database) throws {
        try markSyncDayDirty(dayUTC: utcDayString(date), revisionIncrement: 1, db: db)
    }

    private static func markSyncDayDirty(
        dayUTC: String,
        revisionIncrement: Int,
        db: GRDB.Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO sync_dirty_day(day_utc, revision) VALUES (?, ?)
                ON CONFLICT(day_utc) DO UPDATE SET revision = revision + excluded.revision
                """,
            arguments: [dayUTC, revisionIncrement]
        )
    }

    private static func utcDayString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func upsertFileState(
        filePath: String,
        sourceID: AgentSourceID,
        checkpoint: ParseCheckpoint,
        fileSize: Int64,
        fileModifiedAt: Date?,
        db: GRDB.Database
    ) throws {
        let record = FileParseStateRecord(
            filePath: filePath,
            sourceID: sourceID,
            checkpoint: checkpoint,
            fileSizeAtParse: fileSize,
            fileMtimeAtParse: fileModifiedAt
        )
        if try FileParseStateRecord.filter(key: filePath).fetchOne(db) != nil {
            try record.update(db)
        } else {
            try record.insert(db)
        }
    }

    // MARK: - Aggregate queries

    /// Daily token/cost totals, one row per (day, source) pair within
    /// `[startDay, endDay]` (inclusive, both "yyyy-MM-dd"). Empty
    /// `sourceFilter` means "all sources".
    public func dailySummaries(
        sourceFilter: Set<AgentSourceID>,
        startDay: String,
        endDay: String,
        modelFamilyFilter: Set<String> = [],
        deviceFilter: Set<String> = []
    ) throws -> [DailySourceUsage] {
        try dbQueue.read { db in
            let sql = Self.dailySummarySQL(
                sourceFilter: sourceFilter,
                modelFamilyFilter: modelFamilyFilter,
                deviceFilter: deviceFilter
            )
            let arguments = Self.rangeArguments(
                startDay: startDay,
                endDay: endDay,
                sourceFilter: sourceFilter,
                modelFamilyFilter: modelFamilyFilter,
                deviceFilter: deviceFilter
            )
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return rows.map { row in
                DailySourceUsage(
                    day: row["day"],
                    sourceID: AgentSourceID(rawValue: row["source_id"]),
                    tokens: TokenCounts(
                        input: row["input"],
                        output: row["output"],
                        cacheCreate: row["cacheCreate"],
                        cacheRead: row["cacheRead"],
                        reasoning: row["reasoning"]
                    ),
                    costUSD: Decimal(row["cost"] as Double)
                )
            }
        }
    }

    /// Per-model totals across `[startDay, endDay]`, one row per (modelFamily,
    /// source) pair, ordered by cost descending. Empty `sourceFilter` means
    /// "all sources".
    public func modelBreakdown(
        sourceFilter: Set<AgentSourceID>,
        startDay: String,
        endDay: String,
        modelFamilyFilter: Set<String> = [],
        deviceFilter: Set<String> = []
    ) throws -> [ModelBreakdownRow] {
        try dbQueue.read { db in
            let sql = Self.modelBreakdownSQL(
                sourceFilter: sourceFilter,
                modelFamilyFilter: modelFamilyFilter,
                deviceFilter: deviceFilter
            )
            let arguments = Self.rangeArguments(
                startDay: startDay,
                endDay: endDay,
                sourceFilter: sourceFilter,
                modelFamilyFilter: modelFamilyFilter,
                deviceFilter: deviceFilter
            )
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return rows.map { row in
                ModelBreakdownRow(
                    modelFamily: row["model_family"],
                    sourceID: AgentSourceID(rawValue: row["source_id"]),
                    tokens: TokenCounts(
                        input: row["input"],
                        output: row["output"],
                        cacheCreate: row["cacheCreate"],
                        cacheRead: row["cacheRead"],
                        reasoning: row["reasoning"]
                    ),
                    costUSD: Decimal(row["cost"] as Double),
                    eventCount: row["eventCount"],
                    estimatedEventCount: row["estimatedEvents"]
                )
            }
        }
    }

    /// Per-project totals across `[startDay, endDay]`, one row per (project,
    /// source) pair, ordered by cost descending. `NULL`/absent
    /// `project_or_workspace` is grouped under the empty string. Empty
    /// `sourceFilter` means "all sources".
    public func projectBreakdown(
        sourceFilter: Set<AgentSourceID>,
        startDay: String,
        endDay: String,
        modelFamilyFilter: Set<String> = []
    ) throws -> [ProjectBreakdownRow] {
        try dbQueue.read { db in
            let sql = Self.projectBreakdownSQL(sourceFilter: sourceFilter, modelFamilyFilter: modelFamilyFilter)
            let arguments = Self.rangeArguments(
                startDay: startDay,
                endDay: endDay,
                sourceFilter: sourceFilter,
                modelFamilyFilter: modelFamilyFilter
            )
            let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
            return rows.map { row in
                ProjectBreakdownRow(
                    project: row["project"],
                    sourceID: AgentSourceID(rawValue: row["source_id"]),
                    tokens: TokenCounts(
                        input: row["input"],
                        output: row["output"],
                        cacheCreate: row["cacheCreate"],
                        cacheRead: row["cacheRead"],
                        reasoning: row["reasoning"]
                    ),
                    costUSD: Decimal(row["cost"] as Double),
                    eventCount: row["eventCount"],
                    sessionCount: row["sessionCount"]
                )
            }
        }
    }

    public func deviceBreakdown(
        deviceFilter: Set<String>,
        sourceFilter: Set<AgentSourceID>,
        startDay: String,
        endDay: String,
        modelFamilyFilter: Set<String> = []
    ) throws -> [DeviceBreakdownRow] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: Self.deviceBreakdownSQL(
                    sourceFilter: sourceFilter,
                    modelFamilyFilter: modelFamilyFilter,
                    deviceFilter: deviceFilter
                ),
                arguments: Self.rangeArguments(
                    startDay: startDay,
                    endDay: endDay,
                    sourceFilter: sourceFilter,
                    modelFamilyFilter: modelFamilyFilter,
                    deviceFilter: deviceFilter
                )
            )
            return rows.map { row in
                let device = SyncedUsageDevice(
                    id: row["device_id"],
                    name: row["display_name"],
                    lastSyncedAt: row["last_synced_at"],
                    isLocal: row["is_local"]
                )
                return DeviceBreakdownRow(
                    device: device,
                    tokens: TokenCounts(
                        input: row["input"],
                        output: row["output"],
                        cacheCreate: row["cacheCreate"],
                        cacheRead: row["cacheRead"],
                        reasoning: row["reasoning"]
                    ),
                    costUSD: Decimal(row["cost"] as Double),
                    eventCount: row["eventCount"],
                    estimatedEventCount: row["estimatedEvents"]
                )
            }
        }
    }

    private static func sourceFilterClause(_ sourceFilter: Set<AgentSourceID>) -> String {
        guard !sourceFilter.isEmpty else { return "" }
        let placeholders = sourceFilter.map { _ in "?" }.joined(separator: ", ")
        return "AND source_id IN (\(placeholders))"
    }

    private static func modelFilterClause(_ modelFamilyFilter: Set<String>) -> String {
        guard !modelFamilyFilter.isEmpty else { return "" }
        let placeholders = modelFamilyFilter.map { _ in "?" }.joined(separator: ", ")
        return "AND model_family IN (\(placeholders))"
    }

    private static func deviceFilterClause(_ deviceFilter: Set<String>) -> String {
        guard !deviceFilter.isEmpty else { return "" }
        let placeholders = deviceFilter.map { _ in "?" }.joined(separator: ", ")
        return "AND device_id IN (\(placeholders))"
    }

    private static func rangeArguments(
        startDay: String,
        endDay: String,
        sourceFilter: Set<AgentSourceID>,
        modelFamilyFilter: Set<String>,
        deviceFilter: Set<String> = []
    ) -> StatementArguments {
        var values: [DatabaseValueConvertible] = [startDay, endDay]
        values.append(contentsOf: sourceFilter.map(\.rawValue).sorted())
        values.append(contentsOf: modelFamilyFilter.sorted())
        values.append(contentsOf: deviceFilter.sorted())
        return StatementArguments(values)
    }

    private static func allUsageCTE() -> String {
        """
        WITH all_usage AS (
            SELECT (SELECT id FROM local_device WHERE singleton = 1) AS device_id,
                   timestamp_utc AS hour_utc,
                   source_id,
                   model_family,
                   input_tokens,
                   output_tokens,
                   cache_create_tokens,
                   cache_read_tokens,
                   reasoning_tokens,
                   cost_usd,
                   1 AS event_count,
                   CASE WHEN cost_is_estimated = 1 THEN 1 ELSE 0 END AS estimated_event_count
            FROM usage_event
            UNION ALL
            SELECT device_id,
                   hour_utc,
                   source_id,
                   model_family,
                   input_tokens,
                   output_tokens,
                   cache_create_tokens,
                   cache_read_tokens,
                   reasoning_tokens,
                   cost_usd,
                   event_count,
                   estimated_event_count
            FROM synced_usage_bucket
        ), dated_usage AS (
            SELECT *, strftime('%Y-%m-%d', hour_utc, 'localtime') AS local_day
            FROM all_usage
        )
        """
    }

    private static func dailySummarySQL(
        sourceFilter: Set<AgentSourceID>,
        modelFamilyFilter: Set<String>,
        deviceFilter: Set<String>
    ) -> String {
        """
        \(allUsageCTE())
        SELECT local_day AS day,
               source_id,
               SUM(input_tokens) AS input,
               SUM(output_tokens) AS output,
               SUM(cache_create_tokens) AS cacheCreate,
               SUM(cache_read_tokens) AS cacheRead,
               SUM(reasoning_tokens) AS reasoning,
               SUM(cost_usd) AS cost
        FROM dated_usage
        WHERE local_day BETWEEN ? AND ?
        \(sourceFilterClause(sourceFilter))
        \(modelFilterClause(modelFamilyFilter))
        \(deviceFilterClause(deviceFilter))
        GROUP BY day, source_id
        ORDER BY day
        """
    }

    private static func modelBreakdownSQL(
        sourceFilter: Set<AgentSourceID>,
        modelFamilyFilter: Set<String>,
        deviceFilter: Set<String>
    ) -> String {
        """
        \(allUsageCTE())
        SELECT model_family,
               source_id,
               SUM(input_tokens) AS input,
               SUM(output_tokens) AS output,
               SUM(cache_create_tokens) AS cacheCreate,
               SUM(cache_read_tokens) AS cacheRead,
               SUM(reasoning_tokens) AS reasoning,
               SUM(cost_usd) AS cost,
               SUM(event_count) AS eventCount,
               SUM(estimated_event_count) AS estimatedEvents
        FROM dated_usage
        WHERE local_day BETWEEN ? AND ?
        \(sourceFilterClause(sourceFilter))
        \(modelFilterClause(modelFamilyFilter))
        \(deviceFilterClause(deviceFilter))
        GROUP BY model_family, source_id
        ORDER BY cost DESC
        """
    }

    private static func deviceBreakdownSQL(
        sourceFilter: Set<AgentSourceID>,
        modelFamilyFilter: Set<String>,
        deviceFilter: Set<String>
    ) -> String {
        """
        \(allUsageCTE()), all_devices AS (
            SELECT id, display_name, last_synced_at, 1 AS is_local
            FROM local_device
            UNION ALL
            SELECT id, display_name, last_synced_at, 0 AS is_local
            FROM synced_device
        )
        SELECT usage.device_id,
               devices.display_name,
               devices.last_synced_at,
               devices.is_local,
               SUM(input_tokens) AS input,
               SUM(output_tokens) AS output,
               SUM(cache_create_tokens) AS cacheCreate,
               SUM(cache_read_tokens) AS cacheRead,
               SUM(reasoning_tokens) AS reasoning,
               SUM(cost_usd) AS cost,
               SUM(event_count) AS eventCount,
               SUM(estimated_event_count) AS estimatedEvents
        FROM dated_usage usage
        JOIN all_devices devices ON devices.id = usage.device_id
        WHERE local_day BETWEEN ? AND ?
        \(sourceFilterClause(sourceFilter))
        \(modelFilterClause(modelFamilyFilter))
        \(deviceFilterClause(deviceFilter))
        GROUP BY usage.device_id, devices.display_name, devices.last_synced_at, devices.is_local
        ORDER BY devices.display_name COLLATE NOCASE
        """
    }

    private static func projectBreakdownSQL(sourceFilter: Set<AgentSourceID>, modelFamilyFilter: Set<String>) -> String {
        """
        SELECT COALESCE(project_or_workspace, '') AS project,
               source_id,
               SUM(input_tokens) AS input,
               SUM(output_tokens) AS output,
               SUM(cache_create_tokens) AS cacheCreate,
               SUM(cache_read_tokens) AS cacheRead,
               SUM(reasoning_tokens) AS reasoning,
               SUM(cost_usd) AS cost,
               COUNT(*) AS eventCount,
               COUNT(DISTINCT session_id) AS sessionCount
        FROM usage_event
        WHERE substr(timestamp_utc, 1, 10) BETWEEN ? AND ?
        \(sourceFilterClause(sourceFilter))
        \(modelFilterClause(modelFamilyFilter))
        GROUP BY project, source_id
        ORDER BY cost DESC
        """
    }

}

private struct UsageEventIdentity: Hashable {
    let sourceID: String
    let dedupKey: String

    init(_ event: UsageEvent) {
        sourceID = event.sourceID.rawValue
        dedupKey = event.dedupKey
    }

    init(_ record: UsageEventRecord) {
        sourceID = record.sourceId
        dedupKey = record.dedupKey
    }
}

public struct DailySourceUsage: Sendable, Equatable {
    public let day: String
    public let sourceID: AgentSourceID
    public let tokens: TokenCounts
    public let costUSD: Decimal
}

public struct ModelBreakdownRow: Sendable, Equatable {
    public let modelFamily: String
    public let sourceID: AgentSourceID
    public let tokens: TokenCounts
    public let costUSD: Decimal
    public let eventCount: Int
    public let estimatedEventCount: Int
}

public struct ProjectBreakdownRow: Sendable, Equatable {
    public let project: String
    public let sourceID: AgentSourceID
    public let tokens: TokenCounts
    public let costUSD: Decimal
    public let eventCount: Int
    public let sessionCount: Int
}
