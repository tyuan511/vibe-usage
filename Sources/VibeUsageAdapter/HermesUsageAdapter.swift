import Foundation
import GRDB
import VibeUsageCore
import VibeUsagePricing

public struct HermesUsageAdapter: UsageSourceAdapter {
    public let descriptor = makeDescriptor("hermes-agent", "Hermes Agent", "Hermes", "shippingbox", "#7A6A3B", 14)

    public init() {}

    public func discoverRootDirectories() -> [URL] {
        roots(envName: "HERMES_HOME", defaults: [home(".hermes")])
    }

    public func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] {
        discovered(roots.map { $0.appendingPathComponent("state.db") }.filter(\.isRegularFile), sourceID: descriptor.id)
    }

    public func parseIncrementally(fileAt path: String, from _: ParseCheckpoint?, pricing: PricingProvider) throws -> ParseResult {
        try wholeFileResult(parseHermesDatabase(path: path, descriptor: descriptor, pricing: pricing), path: path)
    }
}

private func parseHermesDatabase(path: String, descriptor: AgentSourceDescriptor, pricing: PricingProvider) throws -> [UsageEvent] {
    let db = try DatabaseQueue(path: path)
    return try db.read { database in
        guard try tableExists("sessions", in: database) else { return [] }
        let hasActualCost = try columnExists("actual_cost", in: "sessions", database: database)
        let hasEstimatedCost = try columnExists("estimated_cost", in: "sessions", database: database)
        let costExpression: String
        switch (hasActualCost, hasEstimatedCost) {
        case (true, true):
            costExpression = "CAST(COALESCE(actual_cost, estimated_cost) AS TEXT)"
        case (true, false):
            costExpression = "CAST(actual_cost AS TEXT)"
        case (false, true):
            costExpression = "CAST(estimated_cost AS TEXT)"
        case (false, false):
            costExpression = "NULL"
        }
        return try Row.fetchAll(database, sql: "SELECT *, \(costExpression) AS vibe_cost FROM sessions").compactMap { row in
            let object = dictionary(from: row)
            guard let sessionID = firstString(in: object, keys: ["id", "session_id", "sessionId"]),
                  let model = firstString(in: object, keys: ["model", "model_id", "modelId"]),
                  let timestamp = firstDate(in: object, keys: ["started_at", "startedAt", "created_at", "createdAt"]) ?? firstNumber(in: object, keys: ["started_at", "startedAt"]).map(Date.vibeUsageParse) else { return nil }
            let counts = TokenCounts(
                input: firstInt(in: object, keys: ["input_tokens", "inputTokens"]) ?? 0,
                output: firstInt(in: object, keys: ["output_tokens", "outputTokens"]) ?? 0,
                cacheCreate: firstInt(in: object, keys: ["cache_creation_tokens", "cacheCreationTokens"]) ?? 0,
                cacheRead: firstInt(in: object, keys: ["cache_read_tokens", "cacheReadTokens"]) ?? 0,
                reasoning: firstInt(in: object, keys: ["reasoning_tokens", "reasoningTokens"]) ?? 0
            )
            guard counts.total > 0 || firstDecimal(in: object, keys: ["actual_cost", "estimated_cost"]) != nil else { return nil }
            let provider = normalizeHermesProvider(firstString(in: object, keys: ["provider"]), model: model)
            return makeEvent(sourceID: descriptor.id, timestamp: timestamp, sessionID: sessionID, project: "Hermes Agent", requestID: sessionID, model: model, tokens: counts, displayCost: firstDecimal(in: object, keys: ["vibe_cost", "actual_cost", "estimated_cost"]), pricing: pricing, pricingCandidates: hermesModelCandidates(model: model, provider: provider), dedupKey: "\(descriptor.id.rawValue):\(sessionID)", path: path, line: nil)
        }
    }
}

private func normalizeHermesProvider(_ value: String?, model: String) -> String {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return inferHermesProvider(fromModel: model)
    }
    switch value.lowercased().replacingOccurrences(of: "-", with: "_") {
    case "anthropic", "claude":
        return "anthropic"
    case "openai", "openai_codex":
        return "openai"
    case "google", "google_ai", "gemini", "vertex", "vertex_ai":
        return "google"
    case "openrouter":
        return "openrouter"
    case "xai":
        return "xai"
    case "groq":
        return "groq"
    default:
        return value.lowercased().replacingOccurrences(of: "-", with: "_")
    }
}

private func inferHermesProvider(fromModel model: String) -> String {
    let lower = model.lowercased()
    if lower.hasPrefix("claude-") || lower.hasPrefix("claude/") {
        return "anthropic"
    }
    if lower.hasPrefix("gpt") || lower.hasPrefix("chatgpt") || (lower.hasPrefix("o") && lower.dropFirst().first?.isNumber == true) {
        return "openai"
    }
    if lower.hasPrefix("gemini-") || lower.hasPrefix("gemini/") {
        return "google"
    }
    return "hermes"
}

private func hermesModelCandidates(model: String, provider: String) -> [String] {
    var candidates: [String] = []
    if provider != "hermes" {
        candidates.append("\(provider)/\(model)")
    }
    candidates.append(model)
    return dedup(candidates)
}
