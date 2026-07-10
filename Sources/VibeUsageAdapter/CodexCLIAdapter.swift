import Foundation
import VibeUsageCore
import VibeUsagePricing

public struct CodexCLIAdapter: UsageSourceAdapter {
    public let descriptor = AgentSourceDescriptor(
        id: .codexCLI,
        displayName: "Codex CLI",
        shortLabel: "Codex",
        iconSystemName: "terminal",
        tintColorHex: "#2D7D72",
        sortOrder: 1
    )

    public init() {}

    public func discoverRootDirectories() -> [URL] {
        let homes: [URL]
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            homes = env
                .split(separator: ",")
                .map { URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespacesAndNewlines).expandingTildeInPath, isDirectory: true) }
        } else {
            homes = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)]
        }
        return homes.filter(\.isDirectory)
    }

    public func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] {
        var discovered: [URL] = []
        var seenKeys = Set<String>()

        for home in roots {
            let sessions = home.appendingPathComponent("sessions", isDirectory: true)
            let archived = home.appendingPathComponent("archived_sessions", isDirectory: true)
            var foundSessionDirectory = false

            if sessions.isDirectory {
                foundSessionDirectory = true
                discovered.append(contentsOf: collectDedupedJSONLFiles(under: sessions, scope: home, seenKeys: &seenKeys))
            }
            if archived.isDirectory {
                foundSessionDirectory = true
                discovered.append(contentsOf: collectDedupedJSONLFiles(under: archived, scope: home, seenKeys: &seenKeys))
            }
            if !foundSessionDirectory {
                discovered.append(contentsOf: collectDedupedJSONLFiles(under: home, scope: home, seenKeys: &seenKeys))
            }
        }

        return discovered
            .sorted { $0.path < $1.path }
            .map { DiscoveredFile(path: $0.path, sourceID: descriptor.id) }
    }

    public func parseIncrementally(
        fileAt path: String,
        from checkpoint: ParseCheckpoint?,
        pricing: PricingProvider
    ) throws -> ParseResult {
        let start = max(0, Int(checkpoint?.byteOffset ?? 0))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard start <= data.count else {
            return ParseResult(events: [], newCheckpoint: .start)
        }

        var state = checkpoint?.adapterState.flatMap { try? JSONDecoder().decode(CodexParseState.self, from: $0) } ?? CodexParseState()
        var offset = start
        var lineIndex = checkpoint?.lineIndex ?? 0
        var events: [UsageEvent] = []
        let sessionID = Self.sessionID(from: path)
        let workspace = Self.workspace(from: path)

        while offset < data.count {
            let lineStart = offset
            let newline = data[lineStart...].firstIndex(of: 0x0A) ?? data.count
            let lineEnd = newline
            offset = newline < data.count ? newline + 1 : data.count
            defer { lineIndex += 1 }

            guard let object = try? JSONSerialization.jsonObject(with: data[lineStart..<lineEnd]) as? [String: Any] else {
                continue
            }

            if let model = Self.turnContextModel(from: object) {
                state.currentModel = model
                state.currentModelIsFallback = false
                continue
            }

            guard let parsed = Self.tokenUsageEvent(from: object, state: &state) else { continue }
            guard let timestamp = Date.vibeUsageParse(parsed.timestamp) else { continue }
            guard let rawModel = parsed.model.nonEmpty else { continue }

            let modelFamily = ModelAliasResolver.resolveFamily(fromRawModel: rawModel)
            let cachedInput = min(parsed.usage.cachedInputTokens, parsed.usage.inputTokens)
            let tokens = TokenCounts(
                input: max(0, parsed.usage.inputTokens - cachedInput),
                output: parsed.usage.outputTokens,
                cacheCreate: 0,
                cacheRead: cachedInput,
                reasoning: parsed.usage.reasoningOutputTokens
            )
            guard tokens.input + tokens.output + tokens.cacheRead + tokens.reasoning > 0 else { continue }

            let rate = pricing.rate(forModelFamily: modelFamily)
            let cost = rate.map { CostCalculator.cost(for: tokens, sourceID: descriptor.id, rate: $0) } ?? 0

            events.append(UsageEvent(
                sourceID: descriptor.id,
                timestamp: timestamp,
                sessionID: sessionID,
                projectOrWorkspace: workspace,
                requestID: nil,
                model: rawModel,
                modelFamily: modelFamily,
                tokens: tokens,
                costUSD: cost,
                costIsEstimated: parsed.isFallbackModel || rate == nil,
                dedupKey: Self.dedupKey(timestamp: parsed.timestamp, model: modelFamily, usage: parsed.usage),
                sourceFilePath: path,
                sourceFileLine: lineIndex + 1
            ))
        }

        let stateData = try? JSONEncoder().encode(state)
        return ParseResult(
            events: events,
            newCheckpoint: ParseCheckpoint(byteOffset: Int64(data.count), lineIndex: lineIndex, adapterState: stateData)
        )
    }

    private static func turnContextModel(from object: [String: Any]) -> String? {
        guard codexString(object["type"]) == "turn_context", let payload = object["payload"] as? [String: Any] else { return nil }
        return model(from: payload)
    }

    private static func tokenUsageEvent(from object: [String: Any], state: inout CodexParseState) -> ParsedCodexEvent? {
        if codexString(object["type"]) == "event_msg",
           let payload = object["payload"] as? [String: Any],
           codexString(payload["type"]) == "token_count" {
            return sessionTokenUsageEvent(from: object, payload: payload, state: &state)
        }
        return headlessTokenUsageEvent(from: object, state: &state)
    }

    private static func sessionTokenUsageEvent(
        from object: [String: Any],
        payload: [String: Any],
        state: inout CodexParseState
    ) -> ParsedCodexEvent? {
        guard let timestamp = codexString(object["timestamp"]) else { return nil }
        let info = payload["info"] as? [String: Any] ?? [:]
        let total = parseUsage(from: info["total_token_usage"])
        let rawUsage = parseUsage(from: info["last_token_usage"]) ?? total.map { totalUsage in
            totalUsage.subtracting(state.previousTotals)
        }
        if let total {
            state.previousTotals = total
        }
        guard let rawUsage else { return nil }

        let parsedModel = model(from: payload) ?? model(from: info)
        let resolved = resolveModel(parsedModel: parsedModel, timestamp: timestamp, state: &state)
        return ParsedCodexEvent(timestamp: timestamp, model: resolved.model, usage: rawUsage, isFallbackModel: resolved.isFallback)
    }

    private static func headlessTokenUsageEvent(from object: [String: Any], state: inout CodexParseState) -> ParsedCodexEvent? {
        let rawUsage = parseUsage(from: object["usage"])
            ?? dictionary(object["data"]).flatMap { parseUsage(from: $0["usage"]) }
            ?? dictionary(object["result"]).flatMap { parseUsage(from: $0["usage"]) }
            ?? dictionary(object["response"]).flatMap { parseUsage(from: $0["usage"]) }
        guard let rawUsage else { return nil }

        let timestamp = codexString(object["timestamp"])
            ?? codexString(object["created_at"])
            ?? codexString(object["createdAt"])
            ?? dictionary(object["data"]).flatMap(timestampString)
            ?? dictionary(object["result"]).flatMap(timestampString)
            ?? dictionary(object["response"]).flatMap(timestampString)
            ?? ISO8601DateFormatter.vibeUsageFractional.string(from: Date())
        let parsedModel = model(from: object)
            ?? dictionary(object["data"]).flatMap(model)
            ?? dictionary(object["result"]).flatMap(model)
            ?? dictionary(object["response"]).flatMap(model)
        let resolved = resolveModel(parsedModel: parsedModel, timestamp: timestamp, state: &state)
        return ParsedCodexEvent(timestamp: timestamp, model: resolved.model, usage: rawUsage, isFallbackModel: resolved.isFallback)
    }

    private static func resolveModel(parsedModel: String?, timestamp: String, state: inout CodexParseState) -> (model: String, isFallback: Bool) {
        if let parsedModel = parsedModel?.nonEmpty {
            state.currentModel = parsedModel
            state.currentModelIsFallback = false
        }
        var fallback = false
        var model = parsedModel?.nonEmpty ?? state.currentModel
        if model == nil {
            model = "gpt-5"
            state.currentModel = model
            state.currentModelIsFallback = true
            fallback = true
        } else if state.currentModelIsFallback, parsedModel == nil {
            fallback = true
        }
        if model == "codex-auto-review" {
            fallback = true
            model = autoReviewFallbackModel(for: timestamp)
            state.currentModel = model
        }
        return (model ?? "gpt-5", fallback)
    }

    private static func autoReviewFallbackModel(for timestamp: String) -> String {
        guard let date = timestamp.prefix(10).nonEmpty else { return "gpt-5" }
        if date >= "2026-02-01" { return "gpt-5.1-codex" }
        return "gpt-5"
    }

    private static func dedupKey(timestamp: String, model: String, usage: CodexRawUsage) -> String {
        [
            "codex-token",
            timestamp,
            model,
            "\(usage.inputTokens)",
            "\(usage.cachedInputTokens)",
            "\(usage.outputTokens)",
            "\(usage.reasoningOutputTokens)",
            "\(usage.totalTokens)"
        ].joined(separator: ":")
    }

    private static func sessionID(from path: String) -> String {
        let parts = URL(fileURLWithPath: path).pathComponents
        if let index = parts.lastIndex(where: { $0 == "sessions" || $0 == "archived_sessions" }) {
            let relative = parts.dropFirst(index + 1)
            return relative.joined(separator: "/").replacingOccurrences(of: ".jsonl", with: "").nonEmpty ?? "unknown"
        }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.nonEmpty ?? "unknown"
    }

    private static func workspace(from path: String) -> String? {
        let id = sessionID(from: path)
        let pieces = id.split(separator: "/").map(String.init)
        guard pieces.count > 1 else { return nil }
        return pieces.dropLast().joined(separator: "/")
    }
}

private struct ParsedCodexEvent {
    let timestamp: String
    let model: String
    let usage: CodexRawUsage
    let isFallbackModel: Bool
}

private struct CodexParseState: Codable {
    var previousTotals: CodexRawUsage?
    var currentModel: String?
    var currentModelIsFallback: Bool = false
}

private struct CodexRawUsage: Codable, Equatable {
    var inputTokens: Int = 0
    var cachedInputTokens: Int = 0
    var outputTokens: Int = 0
    var reasoningOutputTokens: Int = 0
    var totalTokens: Int = 0

    func subtracting(_ previous: CodexRawUsage?) -> CodexRawUsage {
        guard let previous else { return self }
        return CodexRawUsage(
            inputTokens: max(0, inputTokens - previous.inputTokens),
            cachedInputTokens: max(0, cachedInputTokens - previous.cachedInputTokens),
            outputTokens: max(0, outputTokens - previous.outputTokens),
            reasoningOutputTokens: max(0, reasoningOutputTokens - previous.reasoningOutputTokens),
            totalTokens: max(0, totalTokens - previous.totalTokens)
        )
    }
}

private func collectDedupedJSONLFiles(under directory: URL, scope: URL, seenKeys: inout Set<String>) -> [URL] {
    var files: [URL] = []
    for url in collectJSONLFiles(under: directory) {
        let relative = url.path.replacingOccurrences(of: directory.path + "/", with: "")
        let key = scope.standardizedFileURL.path + "::" + relative
        if seenKeys.insert(key).inserted {
            files.append(url)
        }
    }
    return files
}

private func collectJSONLFiles(under directory: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    return enumerator.compactMap { item in
        guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
        return url
    }
}

private func parseUsage(from value: Any?) -> CodexRawUsage? {
    guard let dictionary = value as? [String: Any] else { return nil }
    let input = codexInt(dictionary["input_tokens"]) ?? codexInt(dictionary["prompt_tokens"]) ?? codexInt(dictionary["input"]) ?? 0
    let output = codexInt(dictionary["output_tokens"]) ?? codexInt(dictionary["completion_tokens"]) ?? codexInt(dictionary["output"]) ?? 0
    let reasoning = codexInt(dictionary["reasoning_output_tokens"]) ?? codexInt(dictionary["reasoning_tokens"]) ?? 0
    let cached = codexInt(dictionary["cached_input_tokens"]) ?? codexInt(dictionary["cache_read_input_tokens"]) ?? codexInt(dictionary["cached_tokens"]) ?? 0
    let total = codexInt(dictionary["total_tokens"]).flatMap { $0 > 0 || input + output + reasoning == 0 ? $0 : nil } ?? (input + output + reasoning)
    return CodexRawUsage(
        inputTokens: input,
        cachedInputTokens: cached,
        outputTokens: output,
        reasoningOutputTokens: reasoning,
        totalTokens: total
    )
}

private func model(from dictionary: [String: Any]) -> String? {
    codexString(dictionary["model"])?.nonEmpty
        ?? codexString(dictionary["model_name"])?.nonEmpty
        ?? (dictionary["metadata"] as? [String: Any]).flatMap { codexString($0["model"])?.nonEmpty }
}

private func timestampString(from dictionary: [String: Any]) -> String? {
    codexString(dictionary["timestamp"]) ?? codexString(dictionary["created_at"]) ?? codexString(dictionary["createdAt"])
}

private func dictionary(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

private func codexString(_ value: Any?) -> String? {
    switch value {
    case let value as String:
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    case let value as NSNumber:
        return Date(timeIntervalSince1970: value.doubleValue / 1000).vibeUsageISOString
    default:
        return nil
    }
}

private func codexInt(_ value: Any?) -> Int? {
    switch value {
    case let value as Int:
        return value
    case let value as NSNumber:
        return value.intValue
    case let value as String:
        return Int(value)
    default:
        return nil
    }
}

private extension Substring {
    var nonEmpty: String? {
        isEmpty ? nil : String(self)
    }
}

private extension Date {
    var vibeUsageISOString: String {
        ISO8601DateFormatter.vibeUsageFractional.string(from: self)
    }
}
