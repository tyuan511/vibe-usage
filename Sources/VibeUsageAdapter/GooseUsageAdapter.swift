import Foundation
import GRDB
import VibeUsageCore
import VibeUsagePricing

public struct GooseUsageAdapter: UsageSourceAdapter {
    public let descriptor = makeDescriptor("goose", "Goose", "Goose", "paperplane", "#5D7991", 16)

    public init() {}

    public func discoverRootDirectories() -> [URL] {
        roots(envName: "GOOSE_PATH_ROOT", defaults: [
            home(".local/share/goose/sessions"),
            home("Library/Application Support/goose/sessions"),
            home(".local/share/Block/goose/sessions")
        ])
    }

    public func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] {
        let files = roots.flatMap { root -> [URL] in
            if root.isRegularFile { return [root] }
            return [
                root.appendingPathComponent("sessions.db"),
                root.appendingPathComponent("data/sessions/sessions.db")
            ].filter(\.isRegularFile)
        }
        return discovered(files, sourceID: descriptor.id)
    }

    public func parseIncrementally(fileAt path: String, from checkpoint: ParseCheckpoint?, pricing: PricingProvider) throws -> ParseResult {
        try parseGooseDatabase(path: path, checkpoint: checkpoint, descriptor: descriptor, pricing: pricing)
    }
}

private func parseGooseDatabase(
    path: String,
    checkpoint: ParseCheckpoint?,
    descriptor: AgentSourceDescriptor,
    pricing: PricingProvider
) throws -> ParseResult {
    let db = try DatabaseQueue(path: path)
    var events: [UsageEvent] = []
    var fingerprints = decodeAdapterState(SQLiteSessionFingerprints.self, from: checkpoint)?.sessions ?? [:]
    try db.read { database in
        guard try tableExists("sessions", in: database) else { return }
        for row in try Row.fetchAll(database, sql: "SELECT * FROM sessions") {
            let object = dictionary(from: row)
            guard let sessionID = firstString(in: object, keys: ["id", "session_id", "sessionId"]),
                  let timestamp = gooseTimestamp(from: object["created_at"] ?? object["createdAt"]) else { continue }
            let model = firstString(in: object, keys: ["model", "model_name", "modelName"]) ?? modelFromConfig(firstString(in: object, keys: ["model_config_json", "modelConfigJson"])) ?? "unknown"
            let input = firstInt(in: object, keys: ["accumulated_input_tokens", "input_token_count", "input_tokens", "inputTokens"]) ?? 0
            let output = firstInt(in: object, keys: ["accumulated_output_tokens", "output_token_count", "output_tokens", "outputTokens"]) ?? 0
            let total = firstInt(in: object, keys: ["accumulated_total_tokens", "total_token_count", "total_tokens", "totalTokens"]) ?? 0
            let counts = applyTotalFallback(
                TokenCounts(input: input, output: output, reasoning: max(0, total - input - output)),
                total: total
            )
            guard counts.total > 0 else { continue }
            let fingerprint = sessionFingerprint(model: model, tokens: counts, cost: nil)
            if fingerprints[sessionID] == fingerprint {
                continue
            }
            fingerprints[sessionID] = fingerprint
            let provider = normalizeGooseProvider(firstString(in: object, keys: ["provider_name", "providerName"]), model: model)
            events.append(
                makeEvent(
                    sourceID: descriptor.id,
                    timestamp: timestamp,
                    sessionID: sessionID,
                    project: "Goose",
                    requestID: sessionID,
                    model: model,
                    tokens: counts,
                    displayCost: nil,
                    pricing: pricing,
                    pricingCandidates: gooseModelCandidates(model: model, provider: provider),
                    dedupKey: "\(descriptor.id.rawValue):\(sessionID)",
                    path: path,
                    line: nil
                )
            )
        }
    }
    return wholeFileResult(
        events,
        path: path,
        adapterState: encodeAdapterState(SQLiteSessionFingerprints(sessions: fingerprints))
    )
}

private func modelFromConfig(_ value: String?) -> String? {
    guard let value,
          let data = value.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return firstString(in: object, keys: ["model_name", "modelName", "model"])
}

private func normalizeGooseProvider(_ value: String?, model: String) -> String {
    if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
        return value.replacingOccurrences(of: "-", with: "_")
    }
    if model.hasPrefix("claude-") {
        return "anthropic"
    }
    if model.hasPrefix("gpt-") || model.hasPrefix("chatgpt-") || model.hasPrefix("o") {
        return "openai"
    }
    if model.hasPrefix("gemini-") {
        return "google"
    }
    if model.lowercased().hasPrefix("qwen") {
        return "openrouter"
    }
    return "goose"
}

private func gooseModelCandidates(model: String, provider: String) -> [String] {
    provider == "goose" ? [model] : dedup([model, "\(provider)/\(model)"])
}

private func gooseTimestamp(from value: Any?) -> Date? {
    if let date = string(value).flatMap(Date.vibeUsageParse) {
        return date
    }
    if let number = double(value) {
        return Date.vibeUsageParse(number)
    }
    guard let text = string(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty else { return nil }
    if text.count == 19,
       text[text.index(text.startIndex, offsetBy: 4)] == "-",
       text[text.index(text.startIndex, offsetBy: 7)] == "-",
       [" ", "T"].contains(String(text[text.index(text.startIndex, offsetBy: 10)])) {
        let datePart = text.prefix(10)
        let timePart = text.suffix(8)
        return Date.vibeUsageParse("\(datePart)T\(timePart)Z")
    }
    if text.count == 10,
       text[text.index(text.startIndex, offsetBy: 4)] == "-",
       text[text.index(text.startIndex, offsetBy: 7)] == "-" {
        return Date.vibeUsageParse("\(text)T00:00:00Z")
    }
    return nil
}
