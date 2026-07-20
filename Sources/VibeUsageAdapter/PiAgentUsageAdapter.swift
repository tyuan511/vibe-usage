import Foundation
import GRDB
import VibeUsageCore
import VibeUsagePricing
import YYJSON

public struct PiAgentUsageAdapter: UsageSourceAdapter {
    public let descriptor = makeDescriptor("pi-agent", "pi-agent", "pi", "smallcircle.filled.circle", "#9A6A2F", 15)

    public init() {}

    public func discoverRootDirectories() -> [URL] {
        roots(envName: "PI_AGENT_DIR", defaults: [home(".pi/agent/sessions")])
    }

    public func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] {
        discovered(roots.flatMap { collectFiles(under: $0) { ["json", "jsonl"].contains($0.pathExtension.lowercased()) } }, sourceID: descriptor.id)
    }

    public func parseIncrementally(fileAt path: String, from checkpoint: ParseCheckpoint?, pricing: PricingProvider) throws -> ParseResult {
        try parseJSONLines(path: path, checkpoint: checkpoint) { object, line in
            piEvent(from: object, path: path, line: line, descriptor: descriptor, pricing: pricing)
        }
    }
}

private func piEvent(from object: YYJSONValue, path: String, line: Int, descriptor: AgentSourceDescriptor, pricing: PricingProvider) -> UsageEvent? {
    if let type = string(object["type"]), type != "message" {
        return nil
    }
    guard let message = object["message"],
          string(message["role"]) == "assistant",
          let usage = message["usage"],
          let timestamp = firstDate(in: object, keys: ["timestamp"]) else { return nil }
    let counts = applyTotalFallback(TokenCounts(
        input: int(usage["input"]) ?? 0,
        output: int(usage["output"]) ?? 0,
        cacheCreate: int(usage["cacheWrite"]) ?? 0,
        cacheRead: int(usage["cacheRead"]) ?? 0
    ), total: int(usage["totalTokens"]) ?? 0)
    guard counts.total > 0 else { return nil }
    let model = string(message["model"]).map { "[pi] \($0)" } ?? "[pi] unknown"
    let cost = usage["cost"].flatMap { decimal($0["total"]) }
    return makeEvent(sourceID: descriptor.id, timestamp: timestamp, sessionID: piSessionID(from: path), project: piProject(from: path), requestID: nil, model: model, tokens: counts, displayCost: cost, pricing: pricing, dedupKey: "\(descriptor.id.rawValue):\(path):\(line)", path: path, line: line)
}

private func piSessionID(from path: String) -> String {
    let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    return stem.split(separator: "_", maxSplits: 1).dropFirst().first.map(String.init) ?? stem
}

private func piProject(from path: String) -> String {
    var previousWasSessions = false
    for component in URL(fileURLWithPath: path).pathComponents {
        if previousWasSessions {
            return component
        }
        previousWasSessions = component == "sessions"
    }
    return "unknown"
}
