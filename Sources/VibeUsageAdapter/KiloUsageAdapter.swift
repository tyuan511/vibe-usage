import Foundation
import GRDB
import VibeUsageCore
import VibeUsagePricing

public struct KiloUsageAdapter: UsageSourceAdapter {
    public let descriptor = makeDescriptor("kilo", "Kilo", "Kilo", "k.circle", "#8A6D3B", 18)

    public init() {}

    public func discoverRootDirectories() -> [URL] {
        roots(envName: "KILO_DATA_DIR", defaults: [home(".local/share/kilo")])
    }

    public func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] {
        discovered(roots.map { $0.appendingPathComponent("kilo.db") }.filter(\.isRegularFile), sourceID: descriptor.id)
    }

    public func parseIncrementally(fileAt path: String, from _: ParseCheckpoint?, pricing: PricingProvider) throws -> ParseResult {
        try wholeFileResult(parseKiloDatabase(path: path, descriptor: descriptor, pricing: pricing), path: path)
    }
}

private func parseKiloDatabase(path: String, descriptor: AgentSourceDescriptor, pricing: PricingProvider) throws -> [UsageEvent] {
    let db = try DatabaseQueue(path: path)
    return try db.read { database in
        var events: [UsageEvent] = []
        guard try tableExists("message", in: database) else { return events }
        let rows = try Row.fetchAll(database, sql: "SELECT id, session_id, data FROM message")
        for row in rows {
            guard let data = String.fromDatabaseValue(row["data"]),
                  let object = jsonObject(from: data) else { continue }
            let rowID = String.fromDatabaseValue(row["id"]) ?? "\(path):message"
            let rowSession = String.fromDatabaseValue(row["session_id"]) ?? sessionIDFromPath(path)
            if let event = kiloEvent(from: object, rowID: rowID, rowSessionID: rowSession, path: path, descriptor: descriptor, pricing: pricing) {
                events.append(event)
            }
        }
        return events
    }
}

private func kiloEvent(from object: [String: Any], rowID: String, rowSessionID: String, path: String, descriptor: AgentSourceDescriptor, pricing: PricingProvider) -> UsageEvent? {
    guard string(object["role"]) == "assistant",
          let tokens = object["tokens"] as? [String: Any],
          let model = firstString(in: object, keys: ["modelID", "modelId", "model"]),
          let timestamp = (object["time"] as? [String: Any]).flatMap({ kiloTimestampDate(int($0["created"])) }) else { return nil }
    let cache = tokens["cache"] as? [String: Any]
    let counts = applyTotalFallback(TokenCounts(
        input: int(tokens["input"]) ?? 0,
        output: int(tokens["output"]) ?? 0,
        cacheCreate: int(cache?["write"]) ?? 0,
        cacheRead: int(cache?["read"]) ?? 0,
        reasoning: int(tokens["reasoning"]) ?? 0
    ), total: int(tokens["total"]) ?? 0)
    guard counts.total > 0 else { return nil }
    let session = firstString(in: object, keys: ["sessionID", "sessionId"]) ?? rowSessionID
    let messageID = firstString(in: object, keys: ["id"]) ?? rowID
    let provider = firstString(in: object, keys: ["providerID", "providerId"])
    return makeEvent(sourceID: descriptor.id, timestamp: timestamp, sessionID: session, project: "Kilo", requestID: messageID, model: model, tokens: counts, displayCost: decimal(object["cost"]), pricing: pricing, pricingCandidates: kiloModelCandidates(model: model, provider: provider), dedupKey: "\(descriptor.id.rawValue):\(session):\(messageID)", path: path, line: nil)
}

private func kiloTimestampDate(_ value: Int?) -> Date? {
    guard let value, value > 0 else { return nil }
    let seconds = value < 1_000_000_000_000 ? Double(value) : Double(value) / 1_000
    return Date(timeIntervalSince1970: seconds)
}

private func kiloModelCandidates(model: String, provider: String?) -> [String] {
    var candidates: [String] = []
    if let provider = provider?.replacingOccurrences(of: "-", with: "_"),
       !provider.isEmpty,
       provider != "unknown",
       provider != "kilo" {
        candidates.append("\(provider)/\(model)")
    }
    candidates.append(model)
    return dedup(candidates)
}
