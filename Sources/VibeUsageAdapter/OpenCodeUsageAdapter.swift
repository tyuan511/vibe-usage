import Foundation
import GRDB
import VibeUsageCore
import VibeUsagePricing
import YYJSON

public struct OpenCodeUsageAdapter: UsageSourceAdapter {
    public let descriptor = makeDescriptor("opencode", "OpenCode", "OpenCode", "chevron.left.forwardslash.chevron.right", "#5E8C31", 10)

    public init() {}

    public func discoverRootDirectories() -> [URL] {
        roots(envName: "OPENCODE_DATA_DIR", defaults: [home(".local/share/opencode")])
    }

    public func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] {
        let files = roots.flatMap { root in
            collectFiles(under: root) { url in
                if isOpenCodeDatabase(url) { return true }
                return url.path.contains("/storage/message/") && url.pathExtension.lowercased() == "json"
            }
        }
        return discovered(files, sourceID: descriptor.id)
    }

    public func parseIncrementally(fileAt path: String, from checkpoint: ParseCheckpoint?, pricing: PricingProvider) throws -> ParseResult {
        if path.hasSuffix(".db") {
            return try parseOpenCodeDatabase(path: path, checkpoint: checkpoint, descriptor: descriptor, pricing: pricing)
        }
        let object = try jsonValueFile(path)
        let event = object.flatMap { openCodeEvent(from: $0, path: path, descriptor: descriptor, pricing: pricing) }
        return wholeFileResult([event].compactMap(\.self), path: path)
    }
}

private func openCodeEvent(
    from object: YYJSONValue,
    path: String,
    descriptor: AgentSourceDescriptor,
    pricing: PricingProvider,
    rowID: String? = nil,
    rowSessionID: String? = nil
) -> UsageEvent? {
    guard let tokens = object["tokens"],
          let provider = firstString(in: object, keys: ["providerID", "providerId"]),
          let model = firstString(in: object, keys: ["modelID", "modelId", "model"]) else { return nil }
    let cache = tokens["cache"]
    let counts = applyTotalFallback(
        TokenCounts(
            input: int(tokens["input"]) ?? 0,
            output: int(tokens["output"]) ?? 0,
            cacheCreate: int(cache?["write"]) ?? 0,
            cacheRead: int(cache?["read"]) ?? 0
        ),
        total: int(tokens["total"]) ?? 0
    )
    guard counts.total > 0 else { return nil }
    let timestamp = millisecondsDate(nestedInt(in: object, path: ["time", "created"])) ?? Date.distantPast
    let messageID = rowID ?? firstString(in: object, keys: ["id"])
    let sessionID = rowSessionID ?? firstString(in: object, keys: ["sessionID", "sessionId"]) ?? sessionIDFromPath(path)
    return makeEvent(sourceID: descriptor.id, timestamp: timestamp, sessionID: sessionID, project: "OpenCode", requestID: messageID, model: model, tokens: counts, displayCost: decimal(object["cost"]), pricing: pricing, pricingCandidates: openCodeModelCandidates(model: model, provider: provider), dedupKey: "\(descriptor.id.rawValue):\(messageID ?? path)", path: path, line: nil)
}

private func parseOpenCodeDatabase(
    path: String,
    checkpoint: ParseCheckpoint?,
    descriptor: AgentSourceDescriptor,
    pricing: PricingProvider
) throws -> ParseResult {
    let db = try DatabaseQueue(path: path)
    var events: [UsageEvent] = []
    var watermark = decodeAdapterState(SQLiteRowWatermark.self, from: checkpoint) ?? SQLiteRowWatermark(lastRowID: 0)
    var maxRowID = watermark.lastRowID
    try db.read { database in
        guard try tableExists("message", in: database) else { return }
        let currentMax = try Int64.fetchOne(database, sql: "SELECT IFNULL(MAX(rowid), 0) FROM message") ?? 0
        if currentMax < watermark.lastRowID {
            watermark.lastRowID = 0
            maxRowID = 0
        }
        let rows = try Row.fetchAll(
            database,
            sql: "SELECT rowid, id, session_id, data FROM message WHERE rowid > ? ORDER BY rowid",
            arguments: [watermark.lastRowID]
        )
        for row in rows {
            let rowid = Int64.fromDatabaseValue(row["rowid"]) ?? 0
            maxRowID = max(maxRowID, rowid)
            guard let data = String.fromDatabaseValue(row["data"]),
                  let object = jsonValue(from: data) else { continue }
            let rowID = String.fromDatabaseValue(row["id"])
            let rowSessionID = String.fromDatabaseValue(row["session_id"])
            if let event = openCodeEvent(from: object, path: path, descriptor: descriptor, pricing: pricing, rowID: rowID, rowSessionID: rowSessionID) {
                events.append(event)
            }
        }
    }
    return wholeFileResult(
        events,
        path: path,
        adapterState: encodeAdapterState(SQLiteRowWatermark(lastRowID: maxRowID))
    )
}

private func isOpenCodeDatabase(_ url: URL) -> Bool {
    guard url.pathExtension.lowercased() == "db" else { return false }
    let name = url.lastPathComponent
    return name == "opencode.db" || (name.hasPrefix("opencode-") && name.hasSuffix(".db"))
}

private func openCodeModelCandidates(model: String, provider: String) -> [String] {
    let resolved = resolveOpenCodeModelName(model)
    let normalized = ModelAliasResolver.normalizeClaudeVersion(from: resolved)
    var base = [resolved]
    if normalized != resolved {
        base.append(normalized)
    }
    var candidates = base
    if provider != "unknown" {
        let normalizedProvider = provider.replacingOccurrences(of: "-", with: "_")
        candidates.append(contentsOf: base.map { "\(normalizedProvider)/\($0)" })
    }
    return dedup(candidates)
}

private func resolveOpenCodeModelName(_ model: String) -> String {
    switch model {
    case "gemini-3-pro-high":
        return "gemini-3-pro-preview"
    case "k2p6":
        return "kimi-k2.6"
    default:
        return model
    }
}
