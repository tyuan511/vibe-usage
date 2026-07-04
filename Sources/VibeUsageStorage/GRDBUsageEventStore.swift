import Foundation
import GRDB
import VibeUsageCore

/// GRDB-backed implementation of `UsageEventStore`, plus the raw aggregate
/// query methods that `VibeUsageAggregation` builds view-model DTOs on top of.
public final class GRDBUsageEventStore: UsageEventStore, Sendable {
    private let dbQueue: DatabaseQueue

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

    public func applyParseResult(
        _ result: ParseResult,
        file: DiscoveredFile,
        fileSize: Int64,
        fileModifiedAt: Date?
    ) throws {
        try dbQueue.write { db in
            for event in result.events {
                try Self.upsert(event: event, db: db)
            }
            try Self.upsertFileState(
                filePath: file.path,
                sourceID: file.sourceID,
                checkpoint: result.newCheckpoint,
                fileSize: fileSize,
                fileModifiedAt: fileModifiedAt,
                db: db
            )
        }
    }

    public func resetFile(_ path: String) throws {
        try dbQueue.write { db in
            try UsageEventRecord.filter(Column("source_file_path") == path).deleteAll(db)
            try FileParseStateRecord.filter(key: path).deleteAll(db)
        }
    }

    // MARK: - Upsert internals

    private static func upsert(event: UsageEvent, db: GRDB.Database) throws {
        let existing = try UsageEventRecord
            .filter(Column("source_id") == event.sourceID.rawValue)
            .filter(Column("dedup_key") == event.dedupKey)
            .fetchOne(db)

        guard let existing else {
            try UsageEventRecord(event: event).insert(db)
            return
        }
        guard DedupPolicy.shouldReplace(existing: existing.toUsageEvent(), candidate: event) else {
            return
        }
        var replacement = UsageEventRecord(event: event)
        replacement.id = existing.id
        try replacement.update(db)
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
        modelFamilyFilter: Set<String> = []
    ) throws -> [DailySourceUsage] {
        try dbQueue.read { db in
            let sql = Self.dailySummarySQL(sourceFilter: sourceFilter, modelFamilyFilter: modelFamilyFilter)
            let arguments = Self.rangeArguments(
                startDay: startDay,
                endDay: endDay,
                sourceFilter: sourceFilter,
                modelFamilyFilter: modelFamilyFilter
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
        modelFamilyFilter: Set<String> = []
    ) throws -> [ModelBreakdownRow] {
        try dbQueue.read { db in
            let sql = Self.modelBreakdownSQL(sourceFilter: sourceFilter, modelFamilyFilter: modelFamilyFilter)
            let arguments = Self.rangeArguments(
                startDay: startDay,
                endDay: endDay,
                sourceFilter: sourceFilter,
                modelFamilyFilter: modelFamilyFilter
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

    private static func rangeArguments(
        startDay: String,
        endDay: String,
        sourceFilter: Set<AgentSourceID>,
        modelFamilyFilter: Set<String>
    ) -> StatementArguments {
        var values: [DatabaseValueConvertible] = [startDay, endDay]
        values.append(contentsOf: sourceFilter.map(\.rawValue).sorted())
        values.append(contentsOf: modelFamilyFilter.sorted())
        return StatementArguments(values)
    }

    private static func dailySummarySQL(sourceFilter: Set<AgentSourceID>, modelFamilyFilter: Set<String>) -> String {
        """
        SELECT substr(timestamp_utc, 1, 10) AS day,
               source_id,
               SUM(input_tokens) AS input,
               SUM(output_tokens) AS output,
               SUM(cache_create_tokens) AS cacheCreate,
               SUM(cache_read_tokens) AS cacheRead,
               SUM(reasoning_tokens) AS reasoning,
               SUM(cost_usd) AS cost
        FROM usage_event
        WHERE substr(timestamp_utc, 1, 10) BETWEEN ? AND ?
        \(sourceFilterClause(sourceFilter))
        \(modelFilterClause(modelFamilyFilter))
        GROUP BY day, source_id
        ORDER BY day
        """
    }

    private static func modelBreakdownSQL(sourceFilter: Set<AgentSourceID>, modelFamilyFilter: Set<String>) -> String {
        """
        SELECT model_family,
               source_id,
               SUM(input_tokens) AS input,
               SUM(output_tokens) AS output,
               SUM(cache_create_tokens) AS cacheCreate,
               SUM(cache_read_tokens) AS cacheRead,
               SUM(reasoning_tokens) AS reasoning,
               SUM(cost_usd) AS cost,
               COUNT(*) AS eventCount,
               SUM(CASE WHEN cost_is_estimated = 1 THEN 1 ELSE 0 END) AS estimatedEvents
        FROM usage_event
        WHERE substr(timestamp_utc, 1, 10) BETWEEN ? AND ?
        \(sourceFilterClause(sourceFilter))
        \(modelFilterClause(modelFamilyFilter))
        GROUP BY model_family, source_id
        ORDER BY cost DESC
        """
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
