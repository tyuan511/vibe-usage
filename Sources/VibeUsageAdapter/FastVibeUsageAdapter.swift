import Foundation
import VibeUsageCore
import VibeUsagePricing
import YYJSON

/// Usage adapter for FastVibe, which embeds pi-coding-agent.
///
/// Transcripts use the same JSONL format as pi-agent — an assistant `message`
/// carrying a `usage` block — but FastVibe keeps them in its own data
/// directory (`~/Library/Application Support/FastVibe/runtime/engine/agent/sessions`)
/// instead of `~/.pi/agent/sessions`. Deleting a conversation unlinks its
/// transcript, so the append-only `usage-ledger.jsonl` beside it is read as
/// well. A turn that appears in both collapses to one event: the dedup key is
/// `sessionId` + entry id, and the transcript copy wins because it carries the
/// reasoning tokens the ledger omits.
public struct FastVibeUsageAdapter: UsageSourceAdapter {
    public let descriptor = makeDescriptor(
        "fastvibe",
        "FastVibe",
        "FastVibe",
        "sparkle",
        "#386DFB",
        24
    )

    public init() {}

    public func discoverRootDirectories() -> [URL] {
        fastVibeEngineRoots()
    }

    public func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] {
        let files = roots.flatMap { root in
            collectFiles(under: root) { url in
                guard url.pathExtension.lowercased() == "jsonl" else { return false }
                // The engine root also holds session transcripts (agent/sessions/**)
                // and the append-only ledger beside them; anything else is not usage.
                return url.path.contains("/sessions/") || url.lastPathComponent == "usage-ledger.jsonl"
            }
        }
        return discovered(files, sourceID: descriptor.id)
    }

    public func parseIncrementally(
        fileAt path: String,
        from checkpoint: ParseCheckpoint?,
        pricing: PricingProvider
    ) throws -> ParseResult {
        var sessionID = fastVibeSessionID(from: path)
        return try parseJSONLines(path: path, checkpoint: checkpoint) { object, line in
            if string(object["type"]) == "session",
               let id = string(object["id"])?.nonEmpty {
                sessionID = id
                return nil
            }
            if string(object["type"]) != nil {
                return fastVibeTranscriptEvent(
                    from: object,
                    sessionID: sessionID,
                    path: path,
                    line: line,
                    descriptor: descriptor,
                    pricing: pricing
                )
            }
            return fastVibeLedgerEvent(
                from: object,
                path: path,
                line: line,
                descriptor: descriptor,
                pricing: pricing
            )
        }
    }
}

/// `FASTVIBE_USER_DATA` overrides the data root (comma-separated for several
/// installs); each root holds the engine runtime one level below it.
private func fastVibeEngineRoots() -> [URL] {
    let environment = ProcessInfo.processInfo.environment
    let userDataRoots: [String]
    if let raw = environment["FASTVIBE_USER_DATA"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmpty
    {
        userDataRoots = raw.split(separator: ",").compactMap { part in
            let trimmed = String(part)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .expandingTildeInPath
            return trimmed.nonEmpty
        }
    } else {
        userDataRoots = [home("Library/Application Support/FastVibe").path]
    }

    let engines = userDataRoots.map {
        URL(fileURLWithPath: $0).appendingPathComponent("runtime/engine")
    }
    return dedup(engines.filter(\.isDirectory))
}

private func fastVibeTranscriptEvent(
    from object: YYJSONValue,
    sessionID: String,
    path: String,
    line: Int,
    descriptor: AgentSourceDescriptor,
    pricing: PricingProvider
) -> UsageEvent? {
    guard string(object["type"]) == "message",
          let message = object["message"],
          string(message["role"]) == "assistant",
          let usage = message["usage"],
          let timestamp = firstDate(in: object, keys: ["timestamp"])
            ?? firstDate(in: message, keys: ["timestamp"])
    else {
        return nil
    }

    let counts = applyTotalFallback(
        TokenCounts(
            input: int(usage["input"]) ?? 0,
            output: int(usage["output"]) ?? 0,
            cacheCreate: int(usage["cacheWrite"]) ?? 0,
            cacheRead: int(usage["cacheRead"]) ?? 0,
            reasoning: int(usage["reasoningTokens"]) ?? int(usage["reasoning"]) ?? 0
        ),
        total: int(usage["totalTokens"]) ?? 0
    )
    guard counts.total > 0 else { return nil }

    let bareModel = firstString(in: message, keys: ["model", "modelId"]) ?? "unknown"
    let entryID = string(object["id"])?.nonEmpty
    return makeEvent(
        sourceID: descriptor.id,
        timestamp: timestamp,
        sessionID: sessionID,
        project: fastVibeProject(from: path),
        requestID: entryID,
        model: "[fastvibe] \(bareModel)",
        tokens: counts,
        displayCost: usage["cost"].flatMap { decimal($0["total"]) },
        pricing: pricing,
        pricingCandidates: [bareModel],
        dedupKey: fastVibeDedupKey(sessionID: sessionID, entryID: entryID, path: path, line: line),
        path: path,
        line: line
    )
}

/// One finalized turn from `usage-ledger.jsonl`, kept so a deleted session's
/// usage survives its transcript. The cost is whatever the provider reported;
/// when it reported nothing the pricing table fills it in.
private func fastVibeLedgerEvent(
    from object: YYJSONValue,
    path: String,
    line: Int,
    descriptor: AgentSourceDescriptor,
    pricing: PricingProvider
) -> UsageEvent? {
    guard let sessionID = string(object["sessionId"])?.nonEmpty,
          let entryID = string(object["entryId"])?.nonEmpty,
          let timestamp = firstDate(in: object, keys: ["at"])
    else {
        return nil
    }

    let counts = applyTotalFallback(
        TokenCounts(
            input: int(object["input"]) ?? 0,
            output: int(object["output"]) ?? 0,
            cacheCreate: int(object["cacheWrite"]) ?? 0,
            cacheRead: int(object["cacheRead"]) ?? 0
        ),
        total: int(object["tokens"]) ?? 0
    )
    guard counts.total > 0 else { return nil }

    let bareModel = string(object["model"])?.nonEmpty ?? "unknown"
    let reportedCost = decimal(object["cost"])
    let displayCost = (reportedCost ?? 0) > 0 ? reportedCost : nil
    return makeEvent(
        sourceID: descriptor.id,
        timestamp: timestamp,
        sessionID: sessionID,
        project: "unknown",
        requestID: entryID,
        model: "[fastvibe] \(bareModel)",
        tokens: counts,
        displayCost: displayCost,
        pricing: pricing,
        pricingCandidates: [bareModel],
        dedupKey: fastVibeDedupKey(sessionID: sessionID, entryID: entryID, path: path, line: line),
        path: path,
        line: line
    )
}

/// Shared with the ledger so the two copies of one turn collapse to a single
/// event. Falls back to the file location when a row has no entry id.
private func fastVibeDedupKey(sessionID: String, entryID: String?, path: String, line: Int) -> String {
    if let entryID, !sessionID.isEmpty {
        return "fastvibe:\(sessionID):\(entryID)"
    }
    return "fastvibe:\(path):\(line)"
}

/// Parent transcripts are `<timestamp>_<sessionId>.jsonl`; a nested subagent
/// file inherits the id encoded in its parent directory name.
private func fastVibeSessionID(from path: String) -> String {
    let url = URL(fileURLWithPath: path)
    let stem = url.deletingPathExtension().lastPathComponent
    if let id = fastVibeIDAfterTimestamp(stem) {
        return id
    }
    let parentStem = url.deletingLastPathComponent().lastPathComponent
    if let id = fastVibeIDAfterTimestamp(parentStem) {
        return id
    }
    return stem.nonEmpty ?? "unknown"
}

private func fastVibeIDAfterTimestamp(_ stem: String) -> String? {
    guard let underscore = stem.firstIndex(of: "_") else { return nil }
    let prefix = stem[..<underscore]
    guard prefix.contains("T"), prefix.count >= 16 else { return nil }
    let id = String(stem[stem.index(after: underscore)...])
    return id.nonEmpty
}

/// pi-coding-agent names the session directory
/// `--<cwd without its leading separator, separators turned into '-'>--`.
/// Re-prefixing a single `-` reproduces the Claude-style munged path that
/// `ProjectNameHumanizer` already resolves, so the same directory reported by
/// FastVibe and another source merges into one project.
private func fastVibeProject(from path: String) -> String {
    var previousWasSessions = false
    var component: String?
    for part in URL(fileURLWithPath: path).pathComponents {
        if previousWasSessions {
            component = part
            break
        }
        previousWasSessions = part == "sessions"
    }
    guard let component else { return "unknown" }
    if component.hasPrefix("--"), component.hasSuffix("--"), component.count > 4 {
        return "-" + component.dropFirst(2).dropLast(2)
    }
    return component
}
