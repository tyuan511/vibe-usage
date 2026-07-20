import Foundation
import GRDB
import VibeUsageCore
import VibeUsagePricing
import YYJSON

public struct AmpUsageAdapter: UsageSourceAdapter {
    public let descriptor = makeDescriptor("amp", "Amp", "Amp", "bolt", "#B45F06", 11)

    public init() {}

    public func discoverRootDirectories() -> [URL] {
        roots(envName: "AMP_DATA_DIR", defaults: [home(".local/share/amp")])
    }

    public func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] {
        discovered(roots.flatMap { collectFiles(under: $0.appendingPathComponent("threads")) { $0.pathExtension.lowercased() == "json" } }, sourceID: descriptor.id)
    }

    public func parseIncrementally(fileAt path: String, from _: ParseCheckpoint?, pricing: PricingProvider) throws -> ParseResult {
        guard let object = try jsonValueFile(path) else {
            return wholeFileResult([], path: path)
        }
        return wholeFileResult(ampEvents(from: object, path: path, descriptor: descriptor, pricing: pricing), path: path)
    }
}

private func ampEvents(from object: YYJSONValue, path: String, descriptor: AgentSourceDescriptor, pricing: PricingProvider) -> [UsageEvent] {
    guard let threadID = firstString(in: object, keys: ["id"]) else { return [] }
    let messages = object["messages"]?.array.map(Array.init) ?? []
    if let ledger = object["usageLedger"],
       let events = ledger["events"]?.array {
        let cacheByMessageID = ampCacheTokensByMessageID(messages)
        return events.enumerated().compactMap { index, event in
            guard let timestamp = firstDate(in: event, keys: ["timestamp"]),
                  let model = firstString(in: event, keys: ["model"]),
                  let tokenObject = event["tokens"] else { return nil }
            let cache = int(event["toMessageId"]).flatMap { cacheByMessageID[$0] } ?? TokenCounts.zero
            let counts = applyTotalFallback(
                TokenCounts(
                    input: int(tokenObject["input"]) ?? 0,
                    output: int(tokenObject["output"]) ?? 0,
                    cacheCreate: cache.cacheCreate,
                    cacheRead: cache.cacheRead
                ),
                total: int(tokenObject["total"]) ?? 0
            )
            guard counts.total > 0 else { return nil }
            return makeEvent(sourceID: descriptor.id, timestamp: timestamp, sessionID: threadID, project: "Amp", requestID: string(event["id"]), model: model, tokens: counts, displayCost: decimal(event["credits"]), pricing: pricing, dedupKey: "\(descriptor.id.rawValue):ledger:\(threadID):\(string(event["id"]) ?? String(index))", path: path, line: nil)
        }
    }
    return messages.enumerated().compactMap { index, message in
        guard string(message["role"]) == "assistant",
              let usage = message["usage"],
              let timestamp = firstDate(in: usage, keys: ["timestamp"]) ?? firstDate(in: message, keys: ["timestamp"]),
              let model = firstString(in: usage, keys: ["model"]) ?? firstString(in: message, keys: ["model"]) else { return nil }
        let counts = applyTotalFallback(TokenCounts(
            input: int(usage["inputTokens"]) ?? 0,
            output: int(usage["outputTokens"]) ?? 0,
            cacheCreate: int(usage["cacheCreationInputTokens"]) ?? 0,
            cacheRead: int(usage["cacheReadInputTokens"]) ?? 0
        ), total: int(usage["totalTokens"]) ?? 0)
        guard counts.total > 0 else { return nil }
        return makeEvent(sourceID: descriptor.id, timestamp: timestamp, sessionID: threadID, project: "Amp", requestID: string(message["messageId"]), model: model, tokens: counts, displayCost: nil, pricing: pricing, dedupKey: "\(descriptor.id.rawValue):message:\(threadID):\(string(message["messageId"]) ?? String(index))", path: path, line: nil)
    }
}

private func ampCacheTokensByMessageID(_ messages: [YYJSONValue]) -> [Int: TokenCounts] {
    var cacheByID: [Int: TokenCounts] = [:]
    for message in messages {
        guard string(message["role"]) == "assistant",
              let id = int(message["messageId"]),
              let usage = message["usage"] else { continue }
        cacheByID[id] = TokenCounts(
            cacheCreate: int(usage["cacheCreationInputTokens"]) ?? 0,
            cacheRead: int(usage["cacheReadInputTokens"]) ?? 0
        )
    }
    return cacheByID
}
