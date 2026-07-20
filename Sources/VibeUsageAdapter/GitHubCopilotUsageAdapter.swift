import Foundation
import GRDB
import VibeUsageCore
import VibeUsagePricing
import YYJSON

public struct GitHubCopilotUsageAdapter: UsageSourceAdapter {
    public let descriptor = makeDescriptor("github-copilot-cli", "GitHub Copilot CLI", "Copilot", "person.crop.circle.badge.checkmark", "#207A3C", 21)

    public init() {}

    public func discoverRootDirectories() -> [URL] {
        roots(envName: "COPILOT_OTEL_FILE_EXPORTER_PATH", defaults: [home(".copilot/otel")])
    }

    public func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] {
        discovered(roots.flatMap { root in
            root.isRegularFile ? [root] : collectFiles(under: root) { $0.pathExtension.lowercased() == "jsonl" }
        }, sourceID: descriptor.id)
    }

    public func parseIncrementally(fileAt path: String, from checkpoint: ParseCheckpoint?, pricing: PricingProvider) throws -> ParseResult {
        try parseCopilotFile(path: path, descriptor: descriptor, pricing: pricing)
    }
}

private enum CopilotUsageSource {
    case chatSpan
    case inferenceLog
    case agentTurnLog
    case agentSummarySpan
}

private struct CopilotTraceContext {
    var model: String?
    var sessionID: String?
    var sessionPriority = 0
}

private struct CopilotCandidate {
    let source: CopilotUsageSource
    let traceID: String?
    let responseID: String?
    let event: UsageEvent
}

private func parseCopilotFile(path: String, descriptor: AgentSourceDescriptor, pricing: PricingProvider) throws -> ParseResult {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let objects = jsonLineObjects(data: data)
    let contexts = copilotTraceContexts(objects)
    let fallback = fileModifiedDate(path) ?? Date.distantPast
    let candidates = objects.enumerated().compactMap { index, object in
        copilotCandidate(from: object, index: index, fallback: fallback, contexts: contexts, path: path, descriptor: descriptor, pricing: pricing)
    }
    let emitted = candidates.filter { shouldEmitCopilotCandidate($0, in: candidates) }.map(\.event)
    return ParseResult(events: emitted, newCheckpoint: ParseCheckpoint(byteOffset: Int64(data.count), lineIndex: objects.count))
}

private func jsonLineObjects(data: Data) -> [YYJSONValue] {
    var objects: [YYJSONValue] = []
    var offset = 0
    while offset < data.count {
        let lineStart = offset
        let newline = data[lineStart...].firstIndex(of: 0x0A) ?? data.count
        offset = newline < data.count ? newline + 1 : data.count
        guard newline > lineStart,
              let object = try? parseJSONValue(data[lineStart..<newline]) else { continue }
        objects.append(object)
    }
    return objects
}

private func copilotTraceContexts(_ objects: [YYJSONValue]) -> [String: CopilotTraceContext] {
    var contexts: [String: CopilotTraceContext] = [:]
    for object in objects {
        guard let traceID = copilotTraceID(object),
              let attributes = object["attributes"] else { continue }
        var context = contexts[traceID] ?? CopilotTraceContext()
        if context.model == nil {
            context.model = firstString(in: attributes, keys: copilotModelAttributeKeys)
        }
        if let session = copilotBestSessionAttribute(attributes),
           session.priority > context.sessionPriority {
            context.sessionID = session.value
            context.sessionPriority = session.priority
        }
        contexts[traceID] = context
    }
    return contexts
}

private let copilotModelAttributeKeys = ["gen_ai.response.model", "gen_ai.request.model"]

private func copilotCandidate(
    from object: YYJSONValue,
    index: Int,
    fallback: Date,
    contexts: [String: CopilotTraceContext],
    path: String,
    descriptor: AgentSourceDescriptor,
    pricing: PricingProvider
) -> CopilotCandidate? {
    guard let attributes = object["attributes"] else { return nil }
    let source: CopilotUsageSource
    if isCopilotChatSpan(object, attributes: attributes) {
        source = .chatSpan
    } else if isCopilotInferenceLog(object, attributes: attributes) {
        source = .inferenceLog
    } else if isCopilotAgentTurnLog(object, attributes: attributes) {
        source = .agentTurnLog
    } else if isCopilotAgentSummarySpan(object, attributes: attributes) {
        source = .agentSummarySpan
    } else {
        return nil
    }

    let input = int(attributes["gen_ai.usage.input_tokens"]) ?? 0
    let cacheRead = int(attributes["gen_ai.usage.cache_read.input_tokens"]) ?? 0
    let counts = applyTotalFallback(TokenCounts(
        input: max(0, input - cacheRead),
        output: int(attributes["gen_ai.usage.output_tokens"]) ?? 0,
        cacheCreate: firstInt(in: attributes, keys: ["gen_ai.usage.cache_write.input_tokens", "gen_ai.usage.cache_creation.input_tokens"]) ?? 0,
        cacheRead: cacheRead,
        reasoning: firstInt(in: attributes, keys: ["gen_ai.usage.reasoning.output_tokens", "gen_ai.usage.reasoning_tokens"]) ?? 0
    ), total: firstInt(in: attributes, keys: ["gen_ai.usage.total_tokens", "gen_ai.usage.total.token_count"]) ?? 0)
    guard counts.total > 0 else { return nil }

    let traceID = copilotTraceID(object)
    let context = traceID.flatMap { contexts[$0] }
    let responseID = string(attributes["gen_ai.response.id"])?.nonEmpty
    let model = firstString(in: attributes, keys: copilotModelAttributeKeys) ?? context?.model ?? "unknown"
    let session = copilotBestSessionAttribute(attributes)?.value ?? context?.sessionID ?? traceID ?? "unknown-session"
    let timestamp = copilotTimestamp(object) ?? fallback
    let requestID = copilotDedupKey(source: source, object: object, attributes: attributes, traceID: traceID, sessionID: session, timestamp: timestamp, index: index)
    let event = makeEvent(sourceID: descriptor.id, timestamp: timestamp, sessionID: session, project: "GitHub Copilot CLI", requestID: requestID, model: model, tokens: counts, displayCost: nil, pricing: pricing, pricingCandidates: [model], dedupKey: "\(descriptor.id.rawValue):\(requestID)", path: path, line: index + 1)
    return CopilotCandidate(source: source, traceID: traceID, responseID: responseID, event: event)
}

private func shouldEmitCopilotCandidate(_ candidate: CopilotCandidate, in candidates: [CopilotCandidate]) -> Bool {
    func hasTrace(_ source: CopilotUsageSource) -> Bool {
        guard let traceID = candidate.traceID else { return false }
        return candidates.contains { $0.source == source && $0.traceID == traceID }
    }
    func hasResponse(_ source: CopilotUsageSource) -> Bool {
        guard let responseID = candidate.responseID else { return false }
        return candidates.contains { $0.source == source && $0.responseID == responseID }
    }
    switch candidate.source {
    case .chatSpan:
        return true
    case .inferenceLog:
        return !hasTrace(.chatSpan) && !hasResponse(.chatSpan)
    case .agentTurnLog:
        return !hasTrace(.chatSpan) && !hasTrace(.inferenceLog) && !hasResponse(.chatSpan) && !hasResponse(.inferenceLog)
    case .agentSummarySpan:
        return !hasTrace(.chatSpan) && !hasTrace(.inferenceLog) && !hasTrace(.agentTurnLog) && !hasResponse(.chatSpan) && !hasResponse(.inferenceLog) && !hasResponse(.agentTurnLog)
    }
}

private func isCopilotSpan(_ object: YYJSONValue) -> Bool {
    if string(object["type"]) == "span" { return true }
    return string(object["name"]) != nil
        && (string(object["spanId"]) != nil || string(object["traceId"]) != nil || object["startTime"] != nil || object["endTime"] != nil || object["duration"] != nil || object["kind"] != nil)
}

private func isCopilotChatSpan(_ object: YYJSONValue, attributes: YYJSONValue) -> Bool {
    isCopilotSpan(object)
        && (string(attributes["gen_ai.operation.name"]) == "chat" || string(object["name"])?.hasPrefix("chat ") == true)
}

private func isCopilotAgentSummarySpan(_ object: YYJSONValue, attributes: YYJSONValue) -> Bool {
    isCopilotSpan(object)
        && (string(attributes["gen_ai.operation.name"]) == "invoke_agent" || string(object["name"])?.hasPrefix("invoke_agent ") == true)
}

private func isCopilotInferenceLog(_ object: YYJSONValue, attributes: YYJSONValue) -> Bool {
    !isCopilotSpan(object)
        && (string(attributes["event.name"]) == "gen_ai.client.inference.operation.details" || copilotRecordBody(object)?.hasPrefix("GenAI inference:") == true)
}

private func isCopilotAgentTurnLog(_ object: YYJSONValue, attributes: YYJSONValue) -> Bool {
    !isCopilotSpan(object)
        && (string(attributes["event.name"]) == "copilot_chat.agent.turn" || copilotRecordBody(object)?.hasPrefix("copilot_chat.agent.turn") == true)
}

private func copilotRecordBody(_ object: YYJSONValue) -> String? {
    string(object["body"]) ?? string(object["_body"])
}

private func copilotBestSessionAttribute(_ attributes: YYJSONValue) -> (value: String, priority: Int)? {
    [
        ("gen_ai.conversation.id", 3),
        ("copilot_chat.session_id", 3),
        ("copilot_chat.chat_session_id", 3),
        ("session.id", 3),
        ("github.copilot.interaction_id", 2),
        ("gen_ai.response.id", 1)
    ]
    .compactMap { key, priority in string(attributes[key])?.nonEmpty.map { ($0, priority) } }
    .max { $0.priority < $1.priority }
}

private func copilotTraceID(_ object: YYJSONValue) -> String? {
    string(object["traceId"])?.nonEmpty ?? object["spanContext"].flatMap { string($0["traceId"])?.nonEmpty }
}

private func copilotSpanID(_ object: YYJSONValue) -> String? {
    string(object["spanId"])?.nonEmpty ?? object["spanContext"].flatMap { string($0["spanId"])?.nonEmpty }
}

private func copilotDedupKey(source: CopilotUsageSource, object: YYJSONValue, attributes: YYJSONValue, traceID: String?, sessionID: String, timestamp: Date, index: Int) -> String {
    let millis = Int(timestamp.timeIntervalSince1970 * 1_000)
    let spanID = copilotSpanID(object)
    switch source {
    case .chatSpan, .agentSummarySpan:
        if let traceID, let spanID { return "\(traceID):\(spanID)" }
        return "span:\(sessionID):\(millis):\(index)"
    case .inferenceLog:
        if let traceID, let spanID { return "log:\(traceID):\(spanID)" }
        return "log:\(sessionID):\(millis):\(index)"
    case .agentTurnLog:
        let turn = firstInt(in: attributes, keys: ["turn.index", "copilot_chat.turn.index"]).map(String.init) ?? "idx-\(index)"
        return traceID.map { "agent-turn:\($0):\(turn)" } ?? "agent-turn:\(sessionID):\(turn):\(index)"
    }
}

private func copilotTimestamp(_ object: YYJSONValue) -> Date? {
    copilotTimestampFromParts(object["endTime"])
        ?? copilotTimestampFromParts(object["startTime"])
        ?? copilotTimestampFromParts(object["hrTime"])
        ?? copilotTimestampFromParts(object["_hrTime"])
        ?? copilotTimestampFromParts(object["time"])
        ?? copilotTimestampFromScalar(object["timestamp"])
        ?? copilotTimestampFromScalar(object["observedTimestamp"])
        ?? copilotTimestampFromUnixNanos(object["timeUnixNano"])
}

private func copilotTimestampFromParts(_ value: YYJSONValue?) -> Date? {
    guard let array = value?.array,
          let seconds = double(array[0]),
          let nanos = double(array[1]) else { return nil }
    return Date(timeIntervalSince1970: seconds + nanos / 1_000_000_000)
}

private func copilotTimestampFromScalar(_ value: YYJSONValue?) -> Date? {
    guard let raw = double(value), raw > 0 else { return nil }
    let seconds: Double
    if raw >= 100_000_000_000_000_000 {
        seconds = raw / 1_000_000_000
    } else if raw >= 100_000_000_000_000 {
        seconds = raw / 1_000_000
    } else if raw >= 100_000_000_000 {
        seconds = raw / 1_000
    } else {
        seconds = raw
    }
    return Date(timeIntervalSince1970: seconds)
}

private func copilotTimestampFromUnixNanos(_ value: YYJSONValue?) -> Date? {
    guard let raw = double(value), raw > 0 else { return nil }
    return Date(timeIntervalSince1970: raw / 1_000_000_000)
}
