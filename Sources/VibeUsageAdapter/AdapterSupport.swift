import Darwin
import Foundation
import GRDB
import VibeUsageCore
import VibeUsagePricing
import YYJSON

/// Contiguous JSONL bytes plus absolute file offsets for checkpointing.
struct JSONLByteSlice: Sendable {
    /// Absolute file offset of `data.startIndex` (usually 0 for full reads, or checkpoint for tails).
    let baseOffset: Int64
    let data: Data
    /// Absolute end offset after this slice (for the next checkpoint).
    let endOffset: Int64

    var isEmpty: Bool { data.isEmpty }
}

func parseJSONValue(_ data: Data) throws -> YYJSONValue {
    try YYJSONValue(data: data, options: .numberAsRaw)
}

/// Loads JSONL bytes efficiently:
/// - full reads use `mappedIfSafe` when possible to avoid copying large files into heap
/// - incremental reads only load the tail after `checkpoint.byteOffset`
func loadJSONLBytes(path: String, from checkpoint: ParseCheckpoint?) throws -> JSONLByteSlice {
    let url = URL(fileURLWithPath: path)
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let start = max(0, checkpoint?.byteOffset ?? 0)

    guard start <= fileSize else {
        return JSONLByteSlice(baseOffset: 0, data: Data(), endOffset: 0)
    }
    guard start < fileSize else {
        return JSONLByteSlice(baseOffset: start, data: Data(), endOffset: fileSize)
    }

    if start == 0 {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return JSONLByteSlice(baseOffset: 0, data: data, endOffset: Int64(data.count))
    }

    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(start))
    let data = try handle.readToEnd() ?? Data()
    return JSONLByteSlice(baseOffset: start, data: data, endOffset: start + Int64(data.count))
}

func forEachJSONLLine(
    in slice: JSONLByteSlice,
    startingLineIndex: Int,
    body: (_ line: Data, _ absoluteLineStart: Int64, _ lineIndex: Int) throws -> Void
) rethrows {
    var lineIndex = startingLineIndex
    let data = slice.data
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var relativeOffset = 0
        while relativeOffset < rawBuffer.count {
            let lineStart = baseAddress.advanced(by: relativeOffset)
            let remaining = rawBuffer.count - relativeOffset
            let newline = memchr(lineStart, Int32(0x0A), remaining)
            let lineLength = newline.map {
                lineStart.distance(to: UnsafeRawPointer($0))
            } ?? remaining
            let line = Data(
                bytesNoCopy: UnsafeMutableRawPointer(mutating: lineStart),
                count: lineLength,
                deallocator: .none
            )
            try body(line, slice.baseOffset + Int64(relativeOffset), lineIndex)
            relativeOffset += lineLength + (newline == nil ? 0 : 1)
            lineIndex += 1
        }
    }
}

func firstJSONLValue<T>(in data: Data, transform: (Data) throws -> T?) rethrows -> T? {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress, !rawBuffer.isEmpty else { return nil }
        var relativeOffset = 0
        while relativeOffset < rawBuffer.count {
            let lineStart = baseAddress.advanced(by: relativeOffset)
            let remaining = rawBuffer.count - relativeOffset
            let newline = memchr(lineStart, Int32(0x0A), remaining)
            let lineLength = newline.map {
                lineStart.distance(to: UnsafeRawPointer($0))
            } ?? remaining
            let line = Data(
                bytesNoCopy: UnsafeMutableRawPointer(mutating: lineStart),
                count: lineLength,
                deallocator: .none
            )
            if let value = try transform(line) {
                return value
            }
            relativeOffset += lineLength + (newline == nil ? 0 : 1)
        }
        return nil
    }
}

func parseJSONLines(path: String, checkpoint: ParseCheckpoint?, transform: (YYJSONValue, Int) -> UsageEvent?) throws -> ParseResult {
    let slice = try loadJSONLBytes(path: path, from: checkpoint)
    if slice.endOffset == 0, (checkpoint?.byteOffset ?? 0) > 0 {
        return ParseResult(events: [], newCheckpoint: .start)
    }

    var lineIndex = checkpoint?.lineIndex ?? 0
    var events: [UsageEvent] = []
    forEachJSONLLine(in: slice, startingLineIndex: lineIndex) { line, _, currentLineIndex in
        lineIndex = currentLineIndex + 1
        guard !line.isEmpty,
              let object = try? parseJSONValue(line),
              let event = transform(object, currentLineIndex + 1) else { return }
        events.append(event)
    }
    return ParseResult(
        events: events,
        newCheckpoint: ParseCheckpoint(byteOffset: slice.endOffset, lineIndex: lineIndex)
    )
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
    let rate = firstPricingRate(for: pricingCandidates ?? [model], pricing: pricing)
    let cost = displayCost ?? rate.map { CostCalculator.cost(for: tokens, sourceID: sourceID, rate: $0) } ?? 0
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

func wholeFileResult(_ events: [UsageEvent], path: String, adapterState: Data? = nil) -> ParseResult {
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
    return ParseResult(
        events: events,
        newCheckpoint: ParseCheckpoint(byteOffset: size, lineIndex: 0, adapterState: adapterState)
    )
}

// MARK: - SQLite incremental helpers

struct SQLiteRowWatermark: Codable, Sendable, Equatable {
    var lastRowID: Int64
}

struct SQLiteSessionFingerprints: Codable, Sendable, Equatable {
    var sessions: [String: String]
}

func decodeAdapterState<T: Decodable>(_ type: T.Type, from checkpoint: ParseCheckpoint?) -> T? {
    guard let data = checkpoint?.adapterState else { return nil }
    return try? YYJSONDecoder().decode(type, from: data)
}

func encodeAdapterState<T: Encodable>(_ value: T) -> Data? {
    try? JSONEncoder().encode(value)
}

func sessionFingerprint(
    model: String,
    tokens: TokenCounts,
    cost: Decimal?
) -> String {
    let costText = cost.map { "\($0)" } ?? ""
    return "\(model)|\(tokens.input)|\(tokens.output)|\(tokens.cacheCreate)|\(tokens.cacheRead)|\(tokens.reasoning)|\(costText)"
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


func jsonValueFile(_ path: String) throws -> YYJSONValue? {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard !data.isEmpty else { return nil }
    return try parseJSONValue(data)
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

func jsonValue(from text: String) -> YYJSONValue? {
    guard let data = text.data(using: .utf8) else { return nil }
    return try? parseJSONValue(data)
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

func firstString(in object: YYJSONValue, keys: [String]) -> String? {
    keys.lazy.compactMap { string(object[$0])?.nonEmpty }.first
}

func firstInt(in object: YYJSONValue, keys: [String]) -> Int? {
    keys.lazy.compactMap { int(object[$0]) }.first
}

func firstNumber(in object: YYJSONValue, keys: [String]) -> Double? {
    keys.lazy.compactMap { double(object[$0]) }.first
}

func firstDecimal(in object: YYJSONValue, keys: [String]) -> Decimal? {
    keys.lazy.compactMap { decimal(object[$0]) }.first
}

func firstDate(in object: YYJSONValue, keys: [String]) -> Date? {
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

func nestedInt(in object: YYJSONValue, path: [String]) -> Int? {
    var current: YYJSONValue? = object
    for part in path {
        current = current?[part]
    }
    return int(current)
}

func string(_ value: YYJSONValue?) -> String? {
    guard let value else { return nil }
    if let string = value.string {
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return value.number == nil ? nil : value.description
}

func int(_ value: YYJSONValue?) -> Int? {
    guard let value else { return nil }
    if let exact = Int(value.description) {
        return exact
    }
    if let number = value.number {
        guard number.isFinite,
              number >= -9_223_372_036_854_775_808.0,
              number < 9_223_372_036_854_775_808.0 else { return nil }
        return Int(number)
    }
    return value.string.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

func double(_ value: YYJSONValue?) -> Double? {
    guard let value else { return nil }
    return value.number
        ?? value.string.flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

func decimal(_ value: YYJSONValue?) -> Decimal? {
    guard let value else { return nil }
    return value.decimal
        ?? value.string.flatMap {
            Decimal(string: $0.trimmingCharacters(in: .whitespacesAndNewlines), locale: Locale(identifier: "en_US_POSIX"))
        }
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
    private static let vibeUsageFractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let vibeUsagePlainStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    static func vibeUsageParse(_ value: String) -> Date? {
        (try? vibeUsageFractionalStyle.parse(value))
            ?? (try? vibeUsagePlainStyle.parse(value))
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
}
