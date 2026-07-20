import Foundation
import GRDB
import VibeUsageCore
import VibeUsagePricing
import YYJSON

public struct GeminiUsageAdapter: UsageSourceAdapter {
    public let descriptor = makeDescriptor("gemini-cli", "Gemini CLI", "Gemini", "diamond", "#3E73B8", 22)

    public init() {}

    public func discoverRootDirectories() -> [URL] {
        roots(envName: "GEMINI_DATA_DIR", defaults: [home(".gemini/tmp")])
    }

    public func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] {
        discovered(roots.flatMap { collectFiles(under: $0) { ["json", "jsonl"].contains($0.pathExtension.lowercased()) } }, sourceID: descriptor.id)
    }

    public func parseIncrementally(fileAt path: String, from checkpoint: ParseCheckpoint?, pricing: PricingProvider) throws -> ParseResult {
        if path.hasSuffix(".jsonl") {
            var sessionID = sessionIDFromPath(path)
            var project = projectPath(from: path)
            return try parseJSONLines(path: path, checkpoint: checkpoint) { object, line in
                if let nextSession = firstString(in: object, keys: ["sessionId", "session_id"]) {
                    sessionID = nextSession
                    project = firstString(in: object, keys: ["projectHash", "project", "project_path"]) ?? project
                }
                return geminiEvent(from: object, sessionID: sessionID, project: project, path: path, line: line, descriptor: descriptor, pricing: pricing)
            }
        }
        guard let value = try jsonValueFile(path) else {
            return wholeFileResult([], path: path)
        }
        return wholeFileResult(geminiEvents(from: value, path: path, descriptor: descriptor, pricing: pricing), path: path)
    }
}

private func geminiEvent(from object: YYJSONValue, sessionID: String, project: String?, path: String, line: Int, descriptor: AgentSourceDescriptor, pricing: PricingProvider) -> UsageEvent? {
    guard string(object["type"]) == "gemini",
          let tokens = object["tokens"],
          let timestamp = firstDate(in: object, keys: ["timestamp"]) else { return nil }
    let cached = int(tokens["cached"]) ?? 0
    let input = int(tokens["input"]) ?? 0
    let tool = int(tokens["tool"]) ?? 0
    let counts = applyTotalFallback(TokenCounts(
        input: max(0, input - cached) + tool,
        output: int(tokens["output"]) ?? 0,
        cacheRead: cached,
        reasoning: int(tokens["thoughts"]) ?? 0
    ), total: int(tokens["total"]) ?? 0)
    guard counts.total > 0 else { return nil }
    let model = firstString(in: object, keys: ["model"]) ?? "gemini"
    return makeEvent(sourceID: descriptor.id, timestamp: timestamp, sessionID: sessionID, project: project ?? "Gemini CLI", requestID: firstString(in: object, keys: ["id"]), model: model, tokens: counts, displayCost: nil, pricing: pricing, pricingCandidates: geminiModelCandidates(model: model), dedupKey: "\(descriptor.id.rawValue):\(path):\(line)", path: path, line: line)
}

private func geminiEvents(from value: YYJSONValue, path: String, descriptor: AgentSourceDescriptor, pricing: PricingProvider) -> [UsageEvent] {
    if let array = value.array {
        return array.enumerated().compactMap { geminiEvent(from: $0.element, sessionID: sessionIDFromPath(path), project: projectPath(from: path), path: path, line: $0.offset + 1, descriptor: descriptor, pricing: pricing) }
    }
    if value.object != nil,
       let event = geminiEvent(from: value, sessionID: sessionIDFromPath(path), project: projectPath(from: path), path: path, line: 1, descriptor: descriptor, pricing: pricing) {
        return [event]
    }
    return []
}

private func geminiModelCandidates(model: String) -> [String] {
    ["google/\(model)", "gemini/\(model)", "vertex_ai/\(model)", "openrouter/google/\(model)", model]
}
