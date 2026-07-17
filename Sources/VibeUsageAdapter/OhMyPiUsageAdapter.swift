import Foundation
import GRDB
import VibeUsageCore
import VibeUsagePricing

/// Usage adapter for [oh-my-pi](https://github.com/can1357/oh-my-pi) (`omp`).
///
/// Primary token ledger is JSONL under `~/.omp/agent/sessions` (Pi-compatible
/// assistant `message.usage` rows, plus `reasoningTokens` and nested subagent files).
public struct OhMyPiUsageAdapter: UsageSourceAdapter {
    public let descriptor = makeDescriptor(
        "oh-my-pi",
        "oh-my-pi",
        "omp",
        "circle.hexagongrid.fill",
        "#6B4EFF",
        23
    )

    public init() {}

    public func discoverRootDirectories() -> [URL] {
        ohMyPiSessionRoots()
    }

    public func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] {
        discovered(
            roots.flatMap {
                collectFiles(under: $0) { $0.pathExtension.lowercased() == "jsonl" }
            },
            sourceID: descriptor.id
        )
    }

    public func parseIncrementally(
        fileAt path: String,
        from checkpoint: ParseCheckpoint?,
        pricing: PricingProvider
    ) throws -> ParseResult {
        var sessionID = ohMyPiSessionID(from: path)
        return try parseJSONLines(path: path, checkpoint: checkpoint) { object, line in
            if string(object["type"]) == "session",
               let id = string(object["id"])?.nonEmpty {
                sessionID = id
                return nil
            }
            return ohMyPiEvent(
                from: object,
                sessionID: sessionID,
                path: path,
                line: line,
                descriptor: descriptor,
                pricing: pricing
            )
        }
    }
}

private func ohMyPiSessionRoots() -> [URL] {
    var candidates: [URL] = []
    let environment = ProcessInfo.processInfo.environment

    if let codingAgentDir = environment["PI_CODING_AGENT_DIR"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmpty
    {
        for part in codingAgentDir.split(separator: ",") {
            let trimmed = String(part)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .expandingTildeInPath
            guard !trimmed.isEmpty else { continue }
            let agent = URL(fileURLWithPath: trimmed)
            candidates.append(agent.appendingPathComponent("sessions"))
            if agent.lastPathComponent == "sessions" {
                candidates.append(agent)
            }
        }
    } else {
        let configRoot = ohMyPiConfigRoot(from: environment)
        candidates.append(configRoot.appendingPathComponent("agent/sessions"))

        let profilesRoot = configRoot.appendingPathComponent("profiles")
        if profilesRoot.isDirectory,
           let profiles = try? FileManager.default.contentsOfDirectory(
               at: profilesRoot,
               includingPropertiesForKeys: [.isDirectoryKey],
               options: [.skipsHiddenFiles]
           )
        {
            for profile in profiles where profile.isDirectory {
                candidates.append(profile.appendingPathComponent("agent/sessions"))
            }
        }
    }

    if let xdgData = environment["XDG_DATA_HOME"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmpty
    {
        let xdgRoot = URL(fileURLWithPath: xdgData.expandingTildeInPath)
        candidates.append(xdgRoot.appendingPathComponent("omp/sessions"))
        candidates.append(xdgRoot.appendingPathComponent("omp/agent/sessions"))
    } else {
        candidates.append(home(".local/share/omp/sessions"))
    }

    return dedup(candidates.filter(\.isDirectory))
}

private func ohMyPiConfigRoot(from environment: [String: String]) -> URL {
    let configDir = environment["PI_CONFIG_DIR"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmpty ?? ".omp"
    if configDir.hasPrefix("/") || configDir == "~" || configDir.hasPrefix("~/") {
        return URL(fileURLWithPath: configDir.expandingTildeInPath)
    }
    return home(configDir)
}

private func ohMyPiEvent(
    from object: [String: Any],
    sessionID: String,
    path: String,
    line: Int,
    descriptor: AgentSourceDescriptor,
    pricing: PricingProvider
) -> UsageEvent? {
    if let type = string(object["type"]), type != "message" {
        return nil
    }
    guard let message = object["message"] as? [String: Any],
          string(message["role"]) == "assistant",
          let usage = message["usage"] as? [String: Any],
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

    let modelName = firstString(in: message, keys: ["model", "modelId"]) ?? "unknown"
    let model = "[omp] \(modelName)"
    let cost = (usage["cost"] as? [String: Any]).flatMap { decimal($0["total"]) }
    let requestID = string(object["id"])?.nonEmpty ?? string(message["id"])?.nonEmpty
    let dedupKey: String
    if let requestID {
        dedupKey = "\(descriptor.id.rawValue):msg:\(requestID)"
    } else {
        dedupKey = "\(descriptor.id.rawValue):\(path):\(line)"
    }

    return makeEvent(
        sourceID: descriptor.id,
        timestamp: timestamp,
        sessionID: sessionID,
        project: ohMyPiProject(from: path),
        requestID: requestID,
        model: model,
        tokens: counts,
        displayCost: cost,
        pricing: pricing,
        dedupKey: dedupKey,
        path: path,
        line: line
    )
}

/// Parent session files: `<ISO8601>_<uuid>.jsonl` → uuid.
/// Nested subagent files fall back to the parent directory stem after `_`, else filename stem.
private func ohMyPiSessionID(from path: String) -> String {
    let url = URL(fileURLWithPath: path)
    let stem = url.deletingPathExtension().lastPathComponent
    if let id = sessionIDAfterTimestampPrefix(stem) {
        return id
    }

    let parentStem = url.deletingLastPathComponent().lastPathComponent
    if let id = sessionIDAfterTimestampPrefix(parentStem) {
        return id
    }

    return stem.nonEmpty ?? "unknown"
}

private func sessionIDAfterTimestampPrefix(_ stem: String) -> String? {
    // omp parent transcripts: 2026-07-16T08-34-09-037Z_<uuid>
    guard let underscore = stem.firstIndex(of: "_") else { return nil }
    let prefix = stem[..<underscore]
    guard prefix.contains("T"), prefix.count >= 16 else { return nil }
    let id = String(stem[stem.index(after: underscore)...])
    return id.nonEmpty
}

private func ohMyPiProject(from path: String) -> String {
    var previousWasSessions = false
    for component in URL(fileURLWithPath: path).pathComponents {
        if previousWasSessions {
            return component
        }
        previousWasSessions = component == "sessions"
    }
    return "unknown"
}
