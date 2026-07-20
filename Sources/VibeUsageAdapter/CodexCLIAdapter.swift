import Foundation
import VibeUsageCore
import VibeUsagePricing
import YYJSON

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
        let slice = try loadJSONLBytes(path: path, from: checkpoint)
        if slice.endOffset == 0, (checkpoint?.byteOffset ?? 0) > 0 {
            return ParseResult(events: [], newCheckpoint: .start)
        }

        var state = checkpoint?.adapterState.flatMap { try? YYJSONDecoder().decode(CodexParseState.self, from: $0) } ?? CodexParseState()
        let replayMatch: ForkReplayMatch
        if state.forkReplayProcessed == true {
            replayMatch = .complete
        } else {
            // Fork replay matching needs the child file prefix (session_meta + early token events).
            let prefixData: Data
            if slice.baseOffset == 0 {
                prefixData = slice.data
            } else {
                prefixData = try loadJSONLBytes(path: path, from: nil).data
            }
            replayMatch = Self.forkReplayMatch(in: prefixData, fileAt: path)
            state.forkReplayProcessed = replayMatch.isComplete
        }
        var lineIndex = checkpoint?.lineIndex ?? 0
        var events: [UsageEvent] = []
        let sessionID = Self.sessionID(from: path)
        let workspace = Self.workspace(from: path)

        forEachJSONLLine(in: slice, startingLineIndex: lineIndex) { line, _, currentLineIndex in
            lineIndex = currentLineIndex + 1
            guard let object = try? YYJSONValue(data: line) else {
                return
            }

            if let model = Self.turnContextModel(from: object) {
                state.currentModel = model
                state.currentModelIsFallback = false
                return
            }

            guard let parsed = Self.tokenUsageEvent(from: object, state: &state) else { return }
            guard !replayMatch.lineIndexes.contains(currentLineIndex + 1) else { return }
            guard let timestamp = Date.vibeUsageParse(parsed.timestamp) else { return }
            guard let rawModel = parsed.model.nonEmpty else { return }

            let modelFamily = ModelAliasResolver.resolveFamily(fromRawModel: rawModel)
            let cachedInput = min(parsed.usage.cachedInputTokens, parsed.usage.inputTokens)
            let tokens = TokenCounts(
                input: max(0, parsed.usage.inputTokens - cachedInput),
                output: parsed.usage.outputTokens,
                cacheCreate: 0,
                cacheRead: cachedInput,
                reasoning: parsed.usage.reasoningOutputTokens
            )
            guard tokens.input + tokens.output + tokens.cacheRead + tokens.reasoning > 0 else { return }

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
                sourceFileLine: currentLineIndex + 1
            ))
        }

        let stateData = try? JSONEncoder().encode(state)
        return ParseResult(
            events: events,
            newCheckpoint: ParseCheckpoint(byteOffset: slice.endOffset, lineIndex: lineIndex, adapterState: stateData)
        )
    }

    private static func turnContextModel(from object: YYJSONValue) -> String? {
        guard codexString(object["type"]) == "turn_context", let payload = object["payload"] else { return nil }
        return model(from: payload)
    }

    private static func tokenUsageEvent(from object: YYJSONValue, state: inout CodexParseState) -> ParsedCodexEvent? {
        if codexString(object["type"]) == "event_msg",
           let payload = object["payload"],
           codexString(payload["type"]) == "token_count" {
            return sessionTokenUsageEvent(from: object, payload: payload, state: &state)
        }
        return headlessTokenUsageEvent(from: object, state: &state)
    }

    private static func sessionTokenUsageEvent(
        from object: YYJSONValue,
        payload: YYJSONValue,
        state: inout CodexParseState
    ) -> ParsedCodexEvent? {
        guard let timestamp = codexString(object["timestamp"]) else { return nil }
        let info = payload["info"]
        let total = parseUsage(from: info?["total_token_usage"])
        if let total, total == state.previousTotals {
            return nil
        }
        let rawUsage = parseUsage(from: info?["last_token_usage"]) ?? total.map { totalUsage in
            totalUsage.subtracting(state.previousTotals)
        }
        if let total {
            state.previousTotals = total
        }
        guard let rawUsage else { return nil }

        let parsedModel = model(from: payload) ?? info.flatMap(model)
        let resolved = resolveModel(parsedModel: parsedModel, timestamp: timestamp, state: &state)
        return ParsedCodexEvent(timestamp: timestamp, model: resolved.model, usage: rawUsage, isFallbackModel: resolved.isFallback)
    }

    private static func forkReplayMatch(in childData: Data, fileAt childPath: String) -> ForkReplayMatch {
        guard let first = firstJSONObject(in: childData),
              codexString(first["type"]) == "session_meta",
              let payload = first["payload"],
              let parentID = codexString(payload["forked_from_id"])?.nonEmpty,
              let forkTimestamp = codexString(first["timestamp"]),
              let forkDate = Date.vibeUsageParse(forkTimestamp) else {
            return .complete
        }
        guard let parentPath = parentSessionPath(parentID: parentID, childPath: childPath),
              let parentData = try? loadJSONLBytes(path: parentPath, from: nil).data else {
            return .pending
        }

        let childObjects = jsonObjectLines(in: childData)
        let parentSnapshots = jsonObjectLines(in: parentData).compactMap { line -> CodexUsageSnapshot? in
            let object = line.object
            guard let timestamp = codexString(object["timestamp"]),
                  let date = Date.vibeUsageParse(timestamp),
                  date <= forkDate else {
                return nil
            }
            return usageSnapshot(from: object)
        }
        guard !parentSnapshots.isEmpty else { return .complete }

        var replayLines = Set<Int>()
        var parentIndex = 0
        for line in childObjects {
            let object = line.object
            guard let snapshot = usageSnapshot(from: object) else { continue }
            guard parentIndex < parentSnapshots.count else {
                return ForkReplayMatch(lineIndexes: replayLines, isComplete: true)
            }
            guard snapshot == parentSnapshots[parentIndex] else {
                return ForkReplayMatch(lineIndexes: replayLines, isComplete: true)
            }
            replayLines.insert(line.number)
            parentIndex += 1
        }
        return ForkReplayMatch(
            lineIndexes: replayLines,
            isComplete: parentIndex == parentSnapshots.count
        )
    }

    private static func usageSnapshot(from object: YYJSONValue) -> CodexUsageSnapshot? {
        guard codexString(object["type"]) == "event_msg",
              let payload = object["payload"],
              codexString(payload["type"]) == "token_count",
              let info = payload["info"] else {
            return nil
        }
        let snapshot = CodexUsageSnapshot(
            total: parseUsage(from: info["total_token_usage"]),
            last: parseUsage(from: info["last_token_usage"])
        )
        return snapshot.total == nil && snapshot.last == nil ? nil : snapshot
    }

    private static func parentSessionPath(parentID: String, childPath: String) -> String? {
        var container = URL(fileURLWithPath: childPath).deletingLastPathComponent()
        while container.path != "/",
              container.lastPathComponent != "sessions",
              container.lastPathComponent != "archived_sessions" {
            container.deleteLastPathComponent()
        }
        guard container.path != "/" else { return nil }

        let home = container.deletingLastPathComponent()
        let expectedSuffix = "-\(parentID).jsonl"
        for directoryName in ["sessions", "archived_sessions"] {
            let directory = home.appendingPathComponent(directoryName, isDirectory: true)
            guard directory.isDirectory else { continue }
            if let match = collectJSONLFiles(under: directory)
                .first(where: { $0.lastPathComponent.hasSuffix(expectedSuffix) }) {
                return match.path
            }
        }
        return nil
    }

    private static func headlessTokenUsageEvent(from object: YYJSONValue, state: inout CodexParseState) -> ParsedCodexEvent? {
        let rawUsage = parseUsage(from: object["usage"])
            ?? object["data"].flatMap { parseUsage(from: $0["usage"]) }
            ?? object["result"].flatMap { parseUsage(from: $0["usage"]) }
            ?? object["response"].flatMap { parseUsage(from: $0["usage"]) }
        guard let rawUsage else { return nil }

        let timestamp = codexString(object["timestamp"])
            ?? codexString(object["created_at"])
            ?? codexString(object["createdAt"])
            ?? object["data"].flatMap(timestampString)
            ?? object["result"].flatMap(timestampString)
            ?? object["response"].flatMap(timestampString)
            ?? ISO8601DateFormatter.vibeUsageFractional.string(from: Date())
        let parsedModel = model(from: object)
            ?? object["data"].flatMap(model)
            ?? object["result"].flatMap(model)
            ?? object["response"].flatMap(model)
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
    var forkReplayProcessed: Bool?
}

private struct CodexUsageSnapshot: Equatable {
    let total: CodexRawUsage?
    let last: CodexRawUsage?
}

private struct ForkReplayMatch {
    let lineIndexes: Set<Int>
    let isComplete: Bool

    static let complete = ForkReplayMatch(lineIndexes: [], isComplete: true)
    static let pending = ForkReplayMatch(lineIndexes: [], isComplete: false)
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

private func firstJSONObject(in data: Data) -> YYJSONValue? {
    var offset = 0
    while offset < data.count {
        let newline = data[offset...].firstIndex(of: 0x0A) ?? data.endIndex
        if let object = try? YYJSONValue(data: data[offset..<newline]) {
            return object
        }
        offset = newline < data.endIndex ? newline + 1 : data.endIndex
    }
    return nil
}

private func jsonObjectLines(in data: Data) -> [(number: Int, object: YYJSONValue)] {
    var objects: [(number: Int, object: YYJSONValue)] = []
    var offset = 0
    var lineNumber = 1
    while offset < data.count {
        let newline = data[offset...].firstIndex(of: 0x0A) ?? data.count
        if let object = try? YYJSONValue(data: data[offset..<newline]) {
            objects.append((number: lineNumber, object: object))
        }
        offset = newline < data.count ? newline + 1 : data.count
        lineNumber += 1
    }
    return objects
}

private func parseUsage(from value: YYJSONValue?) -> CodexRawUsage? {
    guard let value, value.object != nil else { return nil }
    let input = codexInt(value["input_tokens"]) ?? codexInt(value["prompt_tokens"]) ?? codexInt(value["input"]) ?? 0
    let output = codexInt(value["output_tokens"]) ?? codexInt(value["completion_tokens"]) ?? codexInt(value["output"]) ?? 0
    let reasoning = codexInt(value["reasoning_output_tokens"]) ?? codexInt(value["reasoning_tokens"]) ?? 0
    let cached = codexInt(value["cached_input_tokens"]) ?? codexInt(value["cache_read_input_tokens"]) ?? codexInt(value["cached_tokens"]) ?? 0
    let total = codexInt(value["total_tokens"]).flatMap { $0 > 0 || input + output + reasoning == 0 ? $0 : nil } ?? (input + output + reasoning)
    return CodexRawUsage(
        inputTokens: input,
        cachedInputTokens: cached,
        outputTokens: output,
        reasoningOutputTokens: reasoning,
        totalTokens: total
    )
}

private func model(from value: YYJSONValue) -> String? {
    codexString(value["model"])?.nonEmpty
        ?? codexString(value["model_name"])?.nonEmpty
        ?? value["metadata"].flatMap { codexString($0["model"])?.nonEmpty }
}

private func timestampString(from value: YYJSONValue) -> String? {
    codexString(value["timestamp"]) ?? codexString(value["created_at"]) ?? codexString(value["createdAt"])
}

private func codexString(_ value: YYJSONValue?) -> String? {
    guard let value else { return nil }
    if let value = value.string {
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return value.number.map { Date(timeIntervalSince1970: $0 / 1000).vibeUsageISOString }
}

private func codexInt(_ value: YYJSONValue?) -> Int? {
    guard let value else { return nil }
    if let number = value.number {
        guard number.isFinite,
              number >= Double(Int.min),
              number <= Double(Int.max) else { return nil }
        return Int(number)
    }
    return value.string.flatMap(Int.init)
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
