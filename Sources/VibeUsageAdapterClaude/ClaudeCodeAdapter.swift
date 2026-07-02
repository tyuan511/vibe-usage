import Foundation
import VibeUsageCore
import VibeUsagePricing

public struct ClaudeCodeAdapter: UsageSourceAdapter {
    public let descriptor = AgentSourceDescriptor(
        id: .claudeCode,
        displayName: "Claude Code",
        shortLabel: "Claude",
        iconSystemName: "sparkles",
        tintColorHex: "#C15F3C",
        sortOrder: 0
    )

    public init() {}

    public func discoverRootDirectories() -> [URL] {
        var roots: [URL] = []
        var seen = Set<String>()
        let candidates: [URL]

        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            candidates = env
                .split(separator: ",")
                .map { normalizeClaudeConfigPath(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map(URL.init(fileURLWithPath:))
                ?? home.appendingPathComponent(".config", isDirectory: true)
            candidates = [
                xdg.appendingPathComponent("claude", isDirectory: true),
                home.appendingPathComponent(".claude", isDirectory: true)
            ]
        }

        for candidate in candidates where candidate.appendingPathComponent("projects", isDirectory: true).isDirectory {
            let path = candidate.standardizedFileURL.path
            if seen.insert(path).inserted {
                roots.append(candidate)
            }
        }
        return roots
    }

    public func discoverFiles(in roots: [URL]) throws -> [DiscoveredFile] {
        roots
            .flatMap { collectJSONLFiles(under: $0.appendingPathComponent("projects", isDirectory: true)) }
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

        var events: [UsageEvent] = []
        var offset = start
        var lineIndex = checkpoint?.lineIndex ?? 0
        let project = Self.projectPath(from: path)
        let fileSessionID = Self.sessionID(from: path)

        while offset < data.count {
            let lineStart = offset
            let newline = data[lineStart...].firstIndex(of: 0x0A) ?? data.count
            let lineEnd = newline
            offset = newline < data.count ? newline + 1 : data.count
            defer { lineIndex += 1 }

            let line = data[lineStart..<lineEnd]
            guard line.contains(#""usage""#.data(using: .utf8)!) else { continue }
            guard let entry = try? JSONDecoder.vibeUsage.decode(ClaudeUsageEntry.self, from: line) else { continue }
            guard entry.isValid, let timestamp = Date.vibeUsageParse(entry.timestamp) else { continue }
            guard let rawModel = entry.message.model?.nonEmpty, rawModel != "<synthetic>" else { continue }

            let tokens = TokenCounts(
                input: entry.message.usage.inputTokens,
                output: entry.message.usage.outputTokens,
                cacheCreate: entry.message.usage.cacheCreationTokenCount,
                cacheRead: entry.message.usage.cacheReadInputTokens,
                reasoning: 0
            )
            guard tokens.input + tokens.output + tokens.cacheCreate + tokens.cacheRead > 0 else { continue }

            let modelFamily = ModelAliasResolver.resolveFamily(fromRawModel: rawModel)
            let priced = Self.cost(
                reportedCost: entry.costUSD,
                tokens: tokens,
                modelFamily: modelFamily,
                pricing: pricing
            )
            let messageID = entry.message.id?.nonEmpty
            let requestID = entry.requestID?.nonEmpty

            events.append(UsageEvent(
                sourceID: descriptor.id,
                timestamp: timestamp,
                sessionID: entry.sessionID?.nonEmpty ?? fileSessionID,
                projectOrWorkspace: project,
                requestID: requestID,
                model: rawModel,
                modelFamily: modelFamily,
                tokens: tokens,
                costUSD: priced.cost,
                costIsEstimated: priced.estimated,
                dedupKey: Self.dedupKey(messageID: messageID, requestID: requestID, fallbackPath: path, line: lineIndex),
                isSidechainReplay: entry.isSidechain == true,
                sourceFilePath: path,
                sourceFileLine: lineIndex + 1
            ))
        }

        return ParseResult(
            events: events,
            newCheckpoint: ParseCheckpoint(byteOffset: Int64(data.count), lineIndex: lineIndex)
        )
    }

    private static func cost(
        reportedCost: Decimal?,
        tokens: TokenCounts,
        modelFamily: String,
        pricing: PricingProvider
    ) -> (cost: Decimal, estimated: Bool) {
        if let reportedCost {
            return (reportedCost, false)
        }
        guard let rate = pricing.rate(forModelFamily: modelFamily) else {
            return (0, true)
        }
        return (CostCalculator.cost(for: tokens, rate: rate), false)
    }

    private static func dedupKey(messageID: String?, requestID _: String?, fallbackPath: String, line: Int) -> String {
        if let messageID {
            return "claude-message:\(messageID)"
        }
        return "claude-line:\(fallbackPath):\(line)"
    }

    private static func projectPath(from path: String) -> String? {
        let parts = URL(fileURLWithPath: path).pathComponents
        guard let projectsIndex = parts.firstIndex(of: "projects") else { return nil }
        let relative = Array(parts.dropFirst(projectsIndex + 1))
        guard relative.count > 1 else { return "Unknown Project" }
        if relative.count == 2 {
            return relative[0]
        }
        if relative.count >= 4, relative[relative.count - 2] == "subagents" {
            return relative.dropLast(3).joined(separator: "/").nonEmpty ?? "Unknown Project"
        }
        return relative.dropLast(2).joined(separator: "/").nonEmpty ?? "Unknown Project"
    }

    private static func sessionID(from path: String) -> String {
        let parts = URL(fileURLWithPath: path).pathComponents
        guard let projectsIndex = parts.firstIndex(of: "projects") else {
            return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.nonEmpty ?? "unknown"
        }
        let relative = Array(parts.dropFirst(projectsIndex + 1))
        if relative.count == 2 {
            return URL(fileURLWithPath: relative.last ?? "unknown").deletingPathExtension().lastPathComponent.nonEmpty ?? "unknown"
        }
        if relative.count >= 4, relative[relative.count - 2] == "subagents" {
            return relative[relative.count - 3]
        }
        return relative.dropLast().last ?? "unknown"
    }
}

private struct ClaudeUsageEntry: Decodable {
    let sessionID: String?
    let timestamp: String
    let version: String?
    let message: ClaudeUsageMessage
    let costUSD: Decimal?
    let requestID: String?
    let isSidechain: Bool?

    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case timestamp
        case version
        case message
        case costUSD
        case requestID = "requestId"
        case isSidechain
    }

    var isValid: Bool {
        if let version, !version.isEmpty, !version.isSemverLike { return false }
        if sessionID?.isEmpty == true { return false }
        if requestID?.isEmpty == true { return false }
        if message.id?.isEmpty == true { return false }
        if message.model?.isEmpty == true { return false }
        return true
    }
}

private struct ClaudeUsageMessage: Decodable {
    let usage: ClaudeTokenUsage
    let model: String?
    let id: String?
}

private struct ClaudeTokenUsage: Decodable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int
    let cacheCreation: CacheCreation?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreation = "cache_creation"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        cacheCreationInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0
        cacheReadInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens) ?? 0
        cacheCreation = try container.decodeIfPresent(CacheCreation.self, forKey: .cacheCreation)
    }

    var cacheCreationTokenCount: Int {
        if let cacheCreation {
            return cacheCreation.ephemeral5mInputTokens + cacheCreation.ephemeral1hInputTokens
        }
        return cacheCreationInputTokens
    }
}

private struct CacheCreation: Decodable {
    let ephemeral5mInputTokens: Int
    let ephemeral1hInputTokens: Int

    enum CodingKeys: String, CodingKey {
        case ephemeral5mInputTokens = "ephemeral_5m_input_tokens"
        case ephemeral1hInputTokens = "ephemeral_1h_input_tokens"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ephemeral5mInputTokens = try container.decodeIfPresent(Int.self, forKey: .ephemeral5mInputTokens) ?? 0
        ephemeral1hInputTokens = try container.decodeIfPresent(Int.self, forKey: .ephemeral1hInputTokens) ?? 0
    }
}

private func normalizeClaudeConfigPath(_ raw: String) -> URL {
    var url = URL(fileURLWithPath: raw.expandingTildeInPath, isDirectory: true)
    if url.lastPathComponent == "projects", url.isDirectory {
        url.deleteLastPathComponent()
    }
    return url
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

private extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }

    var expandingTildeInPath: String {
        guard self == "~" || hasPrefix("~/") else { return self }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if self == "~" { return home }
        return home + String(dropFirst())
    }

    var isSemverLike: Bool {
        range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) != nil
    }
}

private extension Data {
    func contains(_ needle: Data) -> Bool {
        range(of: needle) != nil
    }
}

private extension JSONDecoder {
    static var vibeUsage: JSONDecoder {
        JSONDecoder()
    }
}

private extension Date {
    static func vibeUsageParse(_ value: String) -> Date? {
        ISO8601DateFormatter.vibeUsageFractional.date(from: value)
            ?? ISO8601DateFormatter.vibeUsagePlain.date(from: value)
    }
}

private extension ISO8601DateFormatter {
    static let vibeUsageFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let vibeUsagePlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
