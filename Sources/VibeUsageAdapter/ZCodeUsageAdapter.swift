import Foundation
import GRDB
import VibeUsageCore
import VibeUsagePricing

/// Usage adapter for ZCode, which records every model request in a SQLite
/// database at `~/.zcode/cli/db/db.sqlite` (shared by the CLI and the desktop
/// app; both CLI and desktop sessions land in the same file).
///
/// The `model_usage` table holds one row per model request — including subagent
/// calls and background work like session titling — with OpenAI-style token
/// accounting: `input_tokens` is the full prompt size *including* cached and
/// cache-written tokens, and `reasoning_tokens` is a subset of `output_tokens`
/// (see ``CostCalculator``). Rows are inserted when a request starts and
/// updated in place as it streams and completes, so parsing re-reads every row
/// whose `COALESCE(completed_at, started_at)` is newer than the activity
/// watermark; completed re-reads collapse onto the same dedup key.
public struct ZCodeUsageAdapter: UsageSourceAdapter {
    public let descriptor = makeDescriptor("zcode", "ZCode", "ZCode", "z.circle", "#6E56CF", 25)

    public init() {}

    public func discoverRootDirectories() -> [URL] {
        roots(envName: "ZCODE_DATA_DIR", defaults: [home(".zcode/cli/db")])
    }

    public func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] {
        discovered(roots.map { $0.appendingPathComponent("db.sqlite") }.filter(\.isRegularFile), sourceID: descriptor.id)
    }

    public func parseIncrementally(fileAt path: String, from checkpoint: ParseCheckpoint?, pricing: PricingProvider) throws -> ParseResult {
        try parseZCodeDatabase(path: path, checkpoint: checkpoint, descriptor: descriptor, pricing: pricing)
    }
}

/// Dual watermark over the rowid frontier (fast bulk catch-up) and the newest
/// observed activity timestamp (recaptures rows that were updated in place
/// after their initial insert).
private struct ZCodeUsageWatermark: Codable, Sendable, Equatable {
    var lastRowID: Int64
    var lastActivityAt: Int64
}

private func parseZCodeDatabase(
    path: String,
    checkpoint: ParseCheckpoint?,
    descriptor: AgentSourceDescriptor,
    pricing: PricingProvider
) throws -> ParseResult {
    let db = try DatabaseQueue(path: path)
    var events: [UsageEvent] = []
    var watermark = decodeAdapterState(ZCodeUsageWatermark.self, from: checkpoint)
        ?? ZCodeUsageWatermark(lastRowID: 0, lastActivityAt: 0)
    var maxRowID = watermark.lastRowID
    var maxActivityAt = watermark.lastActivityAt
    try db.read { database in
        guard try tableExists("model_usage", in: database) else { return }
        let currentMax = try Int64.fetchOne(database, sql: "SELECT IFNULL(MAX(rowid), 0) FROM model_usage") ?? 0
        if currentMax < watermark.lastRowID {
            // The database was rebuilt or replaced; re-read everything.
            watermark = ZCodeUsageWatermark(lastRowID: 0, lastActivityAt: 0)
            maxRowID = 0
            maxActivityAt = 0
        }
        let joinSession = try tableExists("session", in: database)
        let rows = try Row.fetchAll(
            database,
            sql: """
            SELECT m.rowid AS row_id, m.id, m.session_id, m.model_id, m.started_at, m.completed_at,
                   m.input_tokens, m.output_tokens, m.reasoning_tokens,
                   m.cache_creation_input_tokens, m.cache_read_input_tokens
                   \(joinSession ? ", s.directory AS project_directory" : ", NULL AS project_directory")
            FROM model_usage m
            \(joinSession ? "LEFT JOIN session s ON s.id = m.session_id" : "")
            WHERE m.rowid > ? OR COALESCE(m.completed_at, m.started_at) > ?
            ORDER BY m.rowid
            """,
            arguments: [watermark.lastRowID, watermark.lastActivityAt]
        )
        for row in rows {
            let rowID = Int64.fromDatabaseValue(row["row_id"]) ?? 0
            maxRowID = max(maxRowID, rowID)
            if let startedAt = Int64.fromDatabaseValue(row["started_at"]) {
                maxActivityAt = max(maxActivityAt, startedAt)
            }
            if let completedAt = Int64.fromDatabaseValue(row["completed_at"]) {
                maxActivityAt = max(maxActivityAt, completedAt)
            }
            if let event = zCodeEvent(from: row, path: path, descriptor: descriptor, pricing: pricing) {
                events.append(event)
            }
        }
    }
    return wholeFileResult(
        events,
        path: path,
        adapterState: encodeAdapterState(ZCodeUsageWatermark(lastRowID: maxRowID, lastActivityAt: maxActivityAt))
    )
}

private func zCodeEvent(
    from row: Row,
    path: String,
    descriptor: AgentSourceDescriptor,
    pricing: PricingProvider
) -> UsageEvent? {
    guard let modelID = String.fromDatabaseValue(row["model_id"])?.nonEmpty,
          let startedAt = Int64.fromDatabaseValue(row["started_at"]), startedAt > 0
    else { return nil }

    // OpenAI-style accounting: the prompt size already covers cached and
    // cache-written input, so those are split out to match TokenCounts, where
    // the components are disjoint.
    let promptTokens = Int(Int64.fromDatabaseValue(row["input_tokens"]) ?? 0)
    let cacheCreate = Int(Int64.fromDatabaseValue(row["cache_creation_input_tokens"]) ?? 0)
    let cacheRead = Int(Int64.fromDatabaseValue(row["cache_read_input_tokens"]) ?? 0)
    let counts = TokenCounts(
        input: max(0, promptTokens - cacheCreate - cacheRead),
        output: Int(Int64.fromDatabaseValue(row["output_tokens"]) ?? 0),
        cacheCreate: cacheCreate,
        cacheRead: cacheRead,
        reasoning: Int(Int64.fromDatabaseValue(row["reasoning_tokens"]) ?? 0)
    )
    guard counts.total > 0 else { return nil }

    // `codex/gpt-6.1-sol`-style ids carry the backend router as a prefix;
    // dropping it keeps the same model reported through different routers
    // (and priced) as one family.
    let bareModel = modelID.split(separator: "/").last.map(String.init) ?? modelID
    let rowID = String.fromDatabaseValue(row["id"])
        ?? "row:\(Int64.fromDatabaseValue(row["row_id"]) ?? 0)"
    return makeEvent(
        sourceID: descriptor.id,
        timestamp: Date(timeIntervalSince1970: Double(startedAt) / 1_000),
        sessionID: String.fromDatabaseValue(row["session_id"]) ?? "unknown",
        project: String.fromDatabaseValue(row["project_directory"])?.nonEmpty,
        requestID: rowID,
        model: bareModel,
        tokens: counts,
        displayCost: nil,
        pricing: pricing,
        pricingCandidates: [bareModel],
        dedupKey: "zcode:\(rowID)",
        path: path,
        line: nil
    )
}
