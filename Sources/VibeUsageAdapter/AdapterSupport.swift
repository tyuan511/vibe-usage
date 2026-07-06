import Foundation
import GRDB
import VibeUsageCore
import VibeUsagePricing

func parseJSONLines(path: String, checkpoint: ParseCheckpoint?, transform: ([String: Any], Int) -> UsageEvent?) throws -> ParseResult {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let start = max(0, Int(checkpoint?.byteOffset ?? 0))
    guard start <= data.count else {
        return ParseResult(events: [], newCheckpoint: .start)
    }
    var offset = start
    var lineIndex = checkpoint?.lineIndex ?? 0
    var events: [UsageEvent] = []
    while offset < data.count {
        let lineStart = offset
        let newline = data[lineStart...].firstIndex(of: 0x0A) ?? data.count
        let lineEnd = newline
        offset = newline < data.count ? newline + 1 : data.count
        defer { lineIndex += 1 }
        guard lineEnd > lineStart,
              let object = try? JSONSerialization.jsonObject(with: data[lineStart..<lineEnd]) as? [String: Any],
              let event = transform(object, lineIndex + 1) else { continue }
        events.append(event)
    }
    return ParseResult(events: events, newCheckpoint: ParseCheckpoint(byteOffset: Int64(data.count), lineIndex: lineIndex))
}

func makeEvent(
    sourceID: AgentSourceID,
    timestamp: Date,
    sessionID: String,
    project: String?,
    requestID: String?,
    model: String,
    tokens: TokenCounts,
    displayCost: Decimal?,
    pricing: PricingProvider,
    pricingCandidates: [String]? = nil,
    dedupKey: String,
    path: String,
    line: Int?
) -> UsageEvent {
    let family = ModelAliasResolver.resolveFamily(fromRawModel: model)
    let costTokens = TokenCounts(
        input: tokens.input,
        output: tokens.output + tokens.reasoning,
        cacheCreate: tokens.cacheCreate,
        cacheRead: tokens.cacheRead
    )
    let rate = firstPricingRate(for: pricingCandidates ?? [model], pricing: pricing)
    let cost = displayCost ?? rate.map { CostCalculator.cost(for: costTokens, rate: $0) } ?? 0
    return UsageEvent(
        sourceID: sourceID,
        timestamp: timestamp,
        sessionID: sessionID,
        projectOrWorkspace: project,
        requestID: requestID?.nonEmpty,
        model: model,
        modelFamily: family,
        tokens: tokens,
        costUSD: cost,
        costIsEstimated: displayCost == nil,
        dedupKey: dedupKey,
        sourceFilePath: path,
        sourceFileLine: line
    )
}

func firstPricingRate(for candidates: [String], pricing: PricingProvider) -> ModelPricingRate? {
    for candidate in dedup(candidates.map(ModelAliasResolver.resolveFamily)) {
        if let rate = pricing.rate(forModelFamily: candidate) {
            return rate
        }
    }
    return nil
}

func dedup(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
}

func roots(envName: String?, defaults: [URL]) -> [URL] {
    let candidates: [URL]
    if let envName,
       let value = ProcessInfo.processInfo.environment[envName],
       !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        candidates = value
            .split(separator: ",")
            .map { URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespacesAndNewlines).expandingTildeInPath) }
    } else {
        candidates = defaults
    }
    return dedup(candidates.filter { $0.isDirectory || $0.isRegularFile })
}

func discovered(_ urls: [URL], sourceID: AgentSourceID) -> [DiscoveredFile] {
    dedup(urls).sorted { $0.path < $1.path }.map { DiscoveredFile(path: $0.path, sourceID: sourceID) }
}

func wholeFileResult(_ events: [UsageEvent], path: String) -> ParseResult {
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
    return ParseResult(events: events, newCheckpoint: ParseCheckpoint(byteOffset: size, lineIndex: 0))
}

func makeDescriptor(_ id: String, _ displayName: String, _ shortLabel: String, _ icon: String, _ tint: String, _ order: Int) -> AgentSourceDescriptor {
    AgentSourceDescriptor(id: AgentSourceID(rawValue: id), displayName: displayName, shortLabel: shortLabel, iconSystemName: icon, tintColorHex: tint, sortOrder: order)
}

func home(_ relative: String) -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relative)
}

func collectFiles(under directory: URL, matching predicate: (URL) -> Bool) -> [URL] {
    guard directory.isDirectory,
          let enumerator = FileManager.default.enumerator(
              at: directory,
              includingPropertiesForKeys: [.isRegularFileKey],
              options: [.skipsHiddenFiles]
          ) else { return [] }
    return enumerator.compactMap { item in
        guard let url = item as? URL, url.isRegularFile, predicate(url) else { return nil }
        return url
    }
}

func dedup(_ urls: [URL]) -> [URL] {
    var seen = Set<String>()
    return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
}


func jsonObjectFile(_ path: String) throws -> Any? {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard !data.isEmpty else { return nil }
    return try JSONSerialization.jsonObject(with: data)
}

func tableExists(_ name: String, in db: Database) throws -> Bool {
    try String.fetchOne(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", arguments: [name]) != nil
}

func columnExists(_ column: String, in table: String, database: Database) throws -> Bool {
    try Row.fetchAll(database, sql: "PRAGMA table_info(\(table))")
        .contains { row in
            String.fromDatabaseValue(row["name"])?.caseInsensitiveCompare(column) == .orderedSame
        }
}

func jsonObject(from text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

func dictionary(from row: Row) -> [String: Any] {
    var object: [String: Any] = [:]
    for (column, value) in zip(row.columnNames, row.databaseValues) {
        if let int = Int64.fromDatabaseValue(value) {
            object[column] = int
        } else if let double = Double.fromDatabaseValue(value) {
            object[column] = double
        } else if let string = String.fromDatabaseValue(value) {
            object[column] = string
        }
    }
    return object
}

func applyTotalFallback(_ tokens: TokenCounts, total: Int) -> TokenCounts {
    guard tokens.total == 0, total > 0 else { return tokens }
    return TokenCounts(output: total)
}

func firstString(in object: [String: Any], keys: [String]) -> String? {
    keys.lazy.compactMap { string(object[$0])?.nonEmpty }.first
}

func firstInt(in object: [String: Any], keys: [String]) -> Int? {
    keys.lazy.compactMap { int(object[$0]) }.first
}

func firstNumber(in object: [String: Any], keys: [String]) -> Double? {
    keys.lazy.compactMap { double(object[$0]) }.first
}

func firstDecimal(in object: [String: Any], keys: [String]) -> Decimal? {
    keys.lazy.compactMap { decimal(object[$0]) }.first
}

func firstDate(in object: [String: Any], keys: [String]) -> Date? {
    for key in keys {
        if let value = string(object[key]), let date = Date.vibeUsageParse(value) {
            return date
        }
        if let value = double(object[key]) {
            return Date.vibeUsageParse(value)
        }
    }
    return nil
}

func nestedInt(in object: [String: Any], path: [String]) -> Int? {
    var current: Any? = object
    for part in path {
        current = (current as? [String: Any])?[part]
    }
    return int(current)
}

func string(_ value: Any?) -> String? {
    switch value {
    case let value as String:
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    case let value as NSNumber:
        return value.stringValue
    case let value as Int:
        return String(value)
    case let value as Int64:
        return String(value)
    case let value as Double:
        return String(value)
    default:
        return nil
    }
}

func int(_ value: Any?) -> Int? {
    switch value {
    case let value as Int:
        return value
    case let value as Int64:
        return Int(value)
    case let value as NSNumber:
        return value.intValue
    case let value as String:
        return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    default:
        return nil
    }
}

func double(_ value: Any?) -> Double? {
    switch value {
    case let value as Double:
        return value
    case let value as Int:
        return Double(value)
    case let value as Int64:
        return Double(value)
    case let value as NSNumber:
        return value.doubleValue
    case let value as String:
        return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
    default:
        return nil
    }
}

func decimal(_ value: Any?) -> Decimal? {
    switch value {
    case let value as Decimal:
        return value
    case let value as NSNumber:
        return value.decimalValue
    case let value as Int:
        return Decimal(value)
    case let value as Int64:
        return Decimal(value)
    case let value as Double:
        return Decimal(value)
    case let value as String:
        return Decimal(string: value.trimmingCharacters(in: .whitespacesAndNewlines), locale: Locale(identifier: "en_US_POSIX"))
    default:
        return nil
    }
}

func millisecondsDate(_ value: Int?) -> Date? {
    guard let value, value > 0 else { return nil }
    return Date(timeIntervalSince1970: Double(value) / 1_000)
}

func fileModifiedDate(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
}

func sessionIDFromPath(_ path: String) -> String {
    URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.nonEmpty ?? "unknown"
}

func projectPath(from path: String) -> String? {
    let url = URL(fileURLWithPath: path)
    return url.deletingLastPathComponent().lastPathComponent.nonEmpty
}

extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    var isRegularFile: Bool {
        (try? resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}

extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }

    var expandingTildeInPath: String {
        guard self == "~" || hasPrefix("~/") else { return self }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if self == "~" { return home }
        return home + String(dropFirst())
    }
}

extension Date {
    static func vibeUsageParse(_ value: String) -> Date? {
        ISO8601DateFormatter.vibeUsageFractional.date(from: value)
            ?? ISO8601DateFormatter.vibeUsagePlain.date(from: value)
    }

    static func vibeUsageParse(_ value: Double) -> Date {
        let seconds = value > 10_000_000_000 ? value / 1_000 : value
        return Date(timeIntervalSince1970: seconds)
    }
}

extension ISO8601DateFormatter {
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
