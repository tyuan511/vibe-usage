import Foundation
import GRDB
import VibeUsageCore
import VibeUsagePricing
import YYJSON

public struct DroidUsageAdapter: UsageSourceAdapter {
    public let descriptor = makeDescriptor("droid", "Droid", "Droid", "cpu", "#4B8F5A", 12)

    public init() {}

    public func discoverRootDirectories() -> [URL] {
        roots(envName: "DROID_SESSIONS_DIR", defaults: [home(".factory/sessions")])
    }

    public func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] {
        discovered(roots.flatMap { collectFiles(under: $0) { $0.lastPathComponent.hasSuffix(".settings.json") } }, sourceID: descriptor.id)
    }

    public func parseIncrementally(fileAt path: String, from _: ParseCheckpoint?, pricing: PricingProvider) throws -> ParseResult {
        guard let object = try jsonValueFile(path),
              let event = droidEvent(from: object, path: path, descriptor: descriptor, pricing: pricing) else {
            return wholeFileResult([], path: path)
        }
        return wholeFileResult([event], path: path)
    }
}

private func droidEvent(from object: YYJSONValue, path: String, descriptor: AgentSourceDescriptor, pricing: PricingProvider) -> UsageEvent? {
    guard let usage = object["tokenUsage"] else { return nil }
    let counts = applyTotalFallback(TokenCounts(
        input: int(usage["inputTokens"]) ?? 0,
        output: int(usage["outputTokens"]) ?? 0,
        cacheCreate: int(usage["cacheCreationTokens"]) ?? 0,
        cacheRead: int(usage["cacheReadTokens"]) ?? 0,
        reasoning: int(usage["thinkingTokens"]) ?? 0
    ), total: int(usage["totalTokens"]) ?? 0)
    guard counts.total > 0 else { return nil }
    let provider = normalizeDroidProvider(firstString(in: object, keys: ["providerLock"]))
    let model = normalizeDroidModel(
        firstString(in: object, keys: ["model"])
            ?? droidSidecarModel(settingsPath: path)
            ?? defaultDroidModel(provider: provider)
    )
    let timestamp = firstDate(in: object, keys: ["providerLockTimestamp"]) ?? fileModifiedDate(path) ?? Date.distantPast
    let sessionID = URL(fileURLWithPath: path).lastPathComponent.replacingOccurrences(of: ".settings.json", with: "")
    let resolvedProvider = provider == "unknown" ? inferDroidProvider(fromModel: model) : provider
    return makeEvent(sourceID: descriptor.id, timestamp: timestamp, sessionID: sessionID, project: "Droid", requestID: "droid:\(sessionID)", model: model, tokens: counts, displayCost: nil, pricing: pricing, pricingCandidates: droidModelCandidates(model: model, provider: resolvedProvider), dedupKey: "\(descriptor.id.rawValue):\(sessionID)", path: path, line: nil)
}

private func droidModelCandidates(model: String, provider: String) -> [String] {
    var candidates = [model]
    for prefix in droidProviderPrefixes(provider) {
        candidates.append("\(prefix)\(model)")
    }
    return dedup(candidates)
}

private func droidProviderPrefixes(_ provider: String) -> [String] {
    switch provider {
    case "anthropic":
        return ["anthropic/", "openrouter/anthropic/"]
    case "openai":
        return ["openai/", "openrouter/openai/"]
    case "google":
        return ["google/", "vertex_ai/", "openrouter/google/"]
    case "xai":
        return ["xai/", "openrouter/x-ai/"]
    case "unknown":
        return []
    default:
        return ["\(provider)/", "openrouter/\(provider)/"]
    }
}

private func inferDroidProvider(fromModel model: String) -> String {
    if model.contains("claude") || model.contains("opus") || model.contains("sonnet") || model.contains("haiku") {
        return "anthropic"
    }
    if model.hasPrefix("gpt-") || model.contains("-gpt-") || model.contains("chatgpt") || (model.hasPrefix("o") && model.dropFirst().first?.isNumber == true) {
        return "openai"
    }
    if model.contains("gemini") {
        return "google"
    }
    if model.contains("grok") {
        return "xai"
    }
    return "unknown"
}

private func normalizeDroidModel(_ value: String) -> String {
    var output = ""
    var depth = 0
    let raw = value.hasPrefix("custom:") ? String(value.dropFirst("custom:".count)) : value
    for character in raw {
        if character == "[" {
            depth += 1
        } else if character == "]" {
            depth = max(0, depth - 1)
        } else if depth == 0 {
            output.append(character)
        }
    }
    let collapsed = output
        .lowercased()
        .replacingOccurrences(of: ".", with: "-")
        .replacingOccurrences(of: " ", with: "-")
    return collapsed.split(separator: "-").joined(separator: "-")
}

private func defaultDroidModel(provider: String?) -> String {
    switch provider {
    case "anthropic":
        return "claude-unknown"
    case "openai":
        return "gpt-unknown"
    case "google":
        return "gemini-unknown"
    case "xai":
        return "grok-unknown"
    default:
        return "unknown"
    }
}

private func normalizeDroidProvider(_ value: String?) -> String {
    switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "-", with: "_") {
    case "claude", "anthropic":
        return "anthropic"
    case "openai":
        return "openai"
    case "google", "google_ai", "gemini", "vertex", "vertex_ai":
        return "google"
    case "xai", "x_ai", "grok":
        return "xai"
    case let value? where !value.isEmpty:
        return value
    default:
        return "unknown"
    }
}

private func droidSidecarModel(settingsPath: String) -> String? {
    let settingsURL = URL(fileURLWithPath: settingsPath)
    let fileName = settingsURL.lastPathComponent
    guard fileName.hasSuffix(".settings.json") else { return nil }
    let prefix = String(fileName.dropLast(".settings.json".count))
    let sidecar = settingsURL.deletingLastPathComponent().appendingPathComponent("\(prefix).jsonl")
    guard let content = try? String(contentsOf: sidecar, encoding: .utf8) else { return nil }
    for line in content.split(separator: "\n", maxSplits: 500, omittingEmptySubsequences: true) {
        guard let range = line.range(of: "Model:") else { continue }
        let tail = line[range.upperBound...]
        let raw = tail.split(whereSeparator: { $0 == "\"" || $0 == "\\" || $0 == "[" }).first.map(String.init) ?? ""
        let model = normalizeDroidModel(raw)
        if !model.isEmpty {
            return model
        }
    }
    return nil
}
