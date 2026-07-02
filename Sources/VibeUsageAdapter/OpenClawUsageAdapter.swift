import Foundation
import GRDB
import VibeUsageCore
import VibeUsagePricing

public struct OpenClawUsageAdapter: UsageSourceAdapter {
    public let descriptor = makeDescriptor("openclaw", "OpenClaw", "Claw", "curlybraces", "#94633E", 17)

    public init() {}

    public func discoverRootDirectories() -> [URL] {
        roots(envName: "OPENCLAW_DIR", defaults: [home(".openclaw"), home(".clawdbot"), home(".moltbot"), home(".moldbot")])
    }

    public func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] {
        discovered(roots.flatMap { collectFiles(under: $0, matching: isOpenClawSessionFile) }, sourceID: descriptor.id)
    }

    public func parseIncrementally(fileAt path: String, from checkpoint: ParseCheckpoint?, pricing: PricingProvider) throws -> ParseResult {
        var currentModel: String?
        var currentProvider: String?
        return try parseJSONLines(path: path, checkpoint: checkpoint) { object, line in
            if let next = openClawModel(from: object) {
                currentModel = next.model
                currentProvider = next.provider
                return nil
            }
            return openClawEvent(from: object, model: currentModel, provider: currentProvider, path: path, line: line, descriptor: descriptor, pricing: pricing)
        }
    }
}

private func openClawModel(from object: [String: Any]) -> (model: String, provider: String?)? {
    let type = string(object["type"])
    let custom = string(object["customType"])
    guard type == "model_change" || (type == "custom" && custom == "model-snapshot") else { return nil }
    if let data = object["data"] as? [String: Any] {
        return (firstString(in: data, keys: ["modelId", "model", "modelID"]) ?? "unknown", firstString(in: data, keys: ["provider"]))
    }
    return (firstString(in: object, keys: ["modelId", "model", "modelID"]) ?? "unknown", firstString(in: object, keys: ["provider"]))
}

private func openClawEvent(from object: [String: Any], model: String?, provider _: String?, path: String, line: Int, descriptor: AgentSourceDescriptor, pricing: PricingProvider) -> UsageEvent? {
    let message = object["message"] as? [String: Any]
    guard string(object["type"]) == "message",
          string(message?["role"]) == "assistant",
          let usage = message?["usage"] as? [String: Any] else { return nil }
    let counts = applyTotalFallback(TokenCounts(
        input: int(usage["input"]) ?? 0,
        output: int(usage["output"]) ?? 0,
        cacheCreate: int(usage["cacheWrite"]) ?? 0,
        cacheRead: int(usage["cacheRead"]) ?? 0
    ), total: int(usage["totalTokens"]) ?? 0)
    guard counts.total > 0 else { return nil }
    let timestamp = firstDate(in: message ?? [:], keys: ["timestamp"]) ?? firstDate(in: object, keys: ["timestamp"]) ?? fileModifiedDate(path) ?? Date.distantPast
    let resolvedModel = firstString(in: message ?? [:], keys: ["modelId", "model"]) ?? model ?? "unknown"
    let cost = (usage["cost"] as? [String: Any]).flatMap { decimal($0["total"]) }
    return makeEvent(sourceID: descriptor.id, timestamp: timestamp, sessionID: openClawSessionID(from: path), project: "OpenClaw", requestID: nil, model: "[openclaw] \(resolvedModel)", tokens: counts, displayCost: cost, pricing: pricing, dedupKey: "\(descriptor.id.rawValue):\(path):\(line)", path: path, line: line)
}

private func isOpenClawSessionFile(_ url: URL) -> Bool {
    guard let range = url.lastPathComponent.range(of: ".jsonl") else { return false }
    let suffix = url.lastPathComponent[range.lowerBound...]
    return suffix == ".jsonl" || suffix.hasPrefix(".jsonl.deleted.") || suffix.hasPrefix(".jsonl.reset.")
}

private func openClawSessionID(from path: String) -> String {
    let filename = URL(fileURLWithPath: path).lastPathComponent
    guard let range = filename.range(of: ".jsonl") else {
        return filename.nonEmpty ?? "unknown"
    }
    let stem = String(filename[..<range.lowerBound])
    return stem.nonEmpty ?? filename
}
