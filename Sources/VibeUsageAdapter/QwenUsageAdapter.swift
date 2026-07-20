import Foundation
import GRDB
import VibeUsageCore
import VibeUsagePricing
import YYJSON

public struct QwenUsageAdapter: UsageSourceAdapter {
    public let descriptor = makeDescriptor("qwen", "Qwen", "Qwen", "q.circle", "#8A6BBE", 20)

    public init() {}

    public func discoverRootDirectories() -> [URL] {
        roots(envName: "QWEN_DATA_DIR", defaults: [home(".qwen/projects")])
    }

    public func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] {
        discovered(roots.flatMap { collectFiles(under: $0) { $0.pathExtension.lowercased() == "jsonl" } }, sourceID: descriptor.id)
    }

    public func parseIncrementally(fileAt path: String, from checkpoint: ParseCheckpoint?, pricing: PricingProvider) throws -> ParseResult {
        try parseJSONLines(path: path, checkpoint: checkpoint) { object, line in
            qwenEvent(from: object, path: path, line: line, descriptor: descriptor, pricing: pricing)
        }
    }
}

private func qwenEvent(from object: YYJSONValue, path: String, line: Int, descriptor: AgentSourceDescriptor, pricing: PricingProvider) -> UsageEvent? {
    guard string(object["type"]) == "assistant",
          let usage = object["usageMetadata"] ?? object["usage_metadata"] else { return nil }
    let counts = applyTotalFallback(TokenCounts(
        input: firstInt(in: usage, keys: ["promptTokenCount", "prompt_token_count"]) ?? 0,
        output: firstInt(in: usage, keys: ["candidatesTokenCount", "candidates_token_count"]) ?? 0,
        cacheRead: firstInt(in: usage, keys: ["cachedContentTokenCount", "cached_content_token_count"]) ?? 0,
        reasoning: firstInt(in: usage, keys: ["thoughtsTokenCount", "thoughts_token_count"]) ?? 0
    ), total: firstInt(in: usage, keys: ["totalTokenCount", "total_token_count"]) ?? 0)
    guard counts.total > 0 else { return nil }
    let timestamp = firstDate(in: object, keys: ["timestamp"]) ?? fileModifiedDate(path) ?? Date.distantPast
    let session = firstString(in: object, keys: ["sessionId", "session_id"]) ?? "\(projectPath(from: path) ?? "qwen")-\(sessionIDFromPath(path))"
    let model = firstString(in: object, keys: ["model"]) ?? "unknown"
    return makeEvent(sourceID: descriptor.id, timestamp: timestamp, sessionID: session, project: projectPath(from: path) ?? "Qwen", requestID: nil, model: model, tokens: counts, displayCost: nil, pricing: pricing, pricingCandidates: qwenModelCandidates(model: model), dedupKey: "\(descriptor.id.rawValue):\(path):\(line)", path: path, line: line)
}

private func qwenModelCandidates(model: String) -> [String] {
    [model, "qwen/\(model)", "alibaba/\(model)"]
}
