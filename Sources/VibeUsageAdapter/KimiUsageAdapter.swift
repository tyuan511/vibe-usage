import Foundation
import GRDB
import VibeUsageCore
import VibeUsagePricing

public struct KimiUsageAdapter: UsageSourceAdapter {
    public let descriptor = makeDescriptor("kimi", "Kimi", "Kimi", "moon", "#2F7DA8", 19)

    public init() {}

    public func discoverRootDirectories() -> [URL] {
        roots(envName: "KIMI_DATA_DIR", defaults: [home(".kimi")])
    }

    public func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] {
        discovered(roots.flatMap { collectFiles(under: $0.appendingPathComponent("sessions")) { $0.lastPathComponent == "wire.jsonl" } }, sourceID: descriptor.id)
    }

    public func parseIncrementally(fileAt path: String, from checkpoint: ParseCheckpoint?, pricing: PricingProvider) throws -> ParseResult {
        let model = kimiModel(forWireFile: path) ?? "kimi-for-coding"
        return try parseJSONLines(path: path, checkpoint: checkpoint) { object, line in
            kimiEvent(from: object, model: model, path: path, line: line, descriptor: descriptor, pricing: pricing)
        }
    }
}

private func kimiEvent(from object: [String: Any], model: String, path: String, line: Int, descriptor: AgentSourceDescriptor, pricing: PricingProvider) -> UsageEvent? {
    guard let message = object["message"] as? [String: Any],
          string(message["type"]) == "StatusUpdate",
          let payload = message["payload"] as? [String: Any],
          let usage = payload["token_usage"] as? [String: Any],
          let timestamp = firstDate(in: object, keys: ["timestamp"]) else { return nil }
    let counts = TokenCounts(
        input: int(usage["input_other"]) ?? 0,
        output: int(usage["output"]) ?? 0,
        cacheCreate: int(usage["input_cache_creation"]) ?? 0,
        cacheRead: int(usage["input_cache_read"]) ?? 0
    )
    guard counts.total > 0 else { return nil }
    return makeEvent(sourceID: descriptor.id, timestamp: timestamp, sessionID: kimiSessionID(from: path), project: "Kimi", requestID: firstString(in: payload, keys: ["message_id"]), model: model, tokens: counts, displayCost: nil, pricing: pricing, pricingCandidates: kimiModelCandidates(model: model, timestamp: timestamp), dedupKey: "\(descriptor.id.rawValue):\(path):\(line)", path: path, line: line)
}

private func kimiModel(forWireFile path: String) -> String? {
    let url = URL(fileURLWithPath: path)
    var root = url
    for _ in 0..<4 {
        root.deleteLastPathComponent()
    }
    let config = root.appendingPathComponent("config.json")
    guard let object = try? jsonObjectFile(config.path) as? [String: Any] else { return nil }
    return firstString(in: object, keys: ["model"])
}

private func kimiSessionID(from path: String) -> String {
    URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent.nonEmpty ?? "unknown"
}

private func kimiModelCandidates(model: String, timestamp: Date) -> [String] {
    var candidates: [String] = []
    if model == "kimi-for-coding" {
        candidates.append(timestamp.timeIntervalSince1970 * 1_000 < 1_776_698_890_072 ? "moonshot/kimi-k2.5" : "moonshot/kimi-k2.6")
    }
    candidates.append(contentsOf: ["moonshot/\(model)", "kimi/\(model)", model])
    return dedup(candidates)
}
