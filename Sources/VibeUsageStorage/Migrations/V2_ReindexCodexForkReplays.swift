import Foundation
import GRDB

/// Codex forked-session logs replay their parent's token history with new
/// timestamps. Older adapters also persisted unchanged cumulative snapshots
/// more than once. Reset only affected files and let the fixed adapter rebuild
/// them, leaving unrelated Codex history untouched.
enum V2ReindexCodexForkReplays {
    static func migrate(_ db: GRDB.Database) throws {
        let codexPaths = try String.fetchAll(db, sql: """
            SELECT DISTINCT source_file_path
            FROM usage_event
            WHERE source_id = 'codex-cli'
            """)
        for path in codexPaths where isForkedSession(at: path) {
            try db.execute(
                sql: "DELETE FROM usage_event WHERE source_id = ? AND source_file_path = ?",
                arguments: ["codex-cli", path]
            )
            try db.execute(
                sql: "DELETE FROM file_parse_state WHERE source_id = ? AND file_path = ?",
                arguments: ["codex-cli", path]
            )
        }
        try deleteConfirmedDuplicateSnapshots(db)
    }

    private static func deleteConfirmedDuplicateSnapshots(_ db: GRDB.Database) throws {
        let rows = try Row.fetchAll(db, sql: """
            WITH ordered AS (
                SELECT id,
                       source_file_path,
                       source_file_line,
                       model_raw,
                       input_tokens,
                       output_tokens,
                       cache_create_tokens,
                       cache_read_tokens,
                       reasoning_tokens,
                       LAG(source_file_line) OVER file_order AS previous_source_file_line,
                       LAG(model_raw) OVER file_order AS previous_model_raw,
                       LAG(input_tokens) OVER file_order AS previous_input_tokens,
                       LAG(output_tokens) OVER file_order AS previous_output_tokens,
                       LAG(cache_create_tokens) OVER file_order AS previous_cache_create_tokens,
                       LAG(cache_read_tokens) OVER file_order AS previous_cache_read_tokens,
                       LAG(reasoning_tokens) OVER file_order AS previous_reasoning_tokens
                FROM usage_event
                WHERE source_id = 'codex-cli'
                WINDOW file_order AS (
                    PARTITION BY source_file_path
                    ORDER BY COALESCE(source_file_line, 2147483647), id
                )
            )
            SELECT id, source_file_path, source_file_line, previous_source_file_line
            FROM ordered
            WHERE source_file_line IS NOT NULL
              AND previous_source_file_line IS NOT NULL
              AND model_raw = previous_model_raw
              AND input_tokens = previous_input_tokens
              AND output_tokens = previous_output_tokens
              AND cache_create_tokens = previous_cache_create_tokens
              AND cache_read_tokens = previous_cache_read_tokens
              AND reasoning_tokens = previous_reasoning_tokens
            """)
        let candidates = rows.compactMap { row -> DuplicateCandidate? in
            guard let id: Int64 = row["id"],
                  let path: String = row["source_file_path"],
                  let line: Int = row["source_file_line"],
                  let previousLine: Int = row["previous_source_file_line"] else {
                return nil
            }
            return DuplicateCandidate(id: id, path: path, line: line, previousLine: previousLine)
        }

        var idsToDelete: [Int64] = []
        for (path, fileCandidates) in Dictionary(grouping: candidates, by: \.path) {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let lines = Set(fileCandidates.flatMap { [$0.line, $0.previousLine] })
            let totals = totalUsageSignatures(at: lines, in: path)
            idsToDelete.append(contentsOf: fileCandidates.compactMap { candidate in
                guard let current = totals[candidate.line],
                      let previous = totals[candidate.previousLine],
                      current == previous else {
                    return nil
                }
                return candidate.id
            })
        }

        for start in stride(from: 0, to: idsToDelete.count, by: 500) {
            let ids = idsToDelete[start..<min(start + 500, idsToDelete.count)]
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            try db.execute(
                sql: "DELETE FROM usage_event WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids.map { $0 })
            )
        }
    }

    private static func totalUsageSignatures(at targetLines: Set<Int>, in path: String) -> [Int: TotalUsageSignature] {
        guard !targetLines.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return [:]
        }

        var signatures: [Int: TotalUsageSignature] = [:]
        var offset = 0
        var lineNumber = 1
        while offset < data.count, signatures.count < targetLines.count {
            let newline = data[offset...].firstIndex(of: 0x0A) ?? data.count
            if targetLines.contains(lineNumber),
               let object = try? JSONSerialization.jsonObject(with: data[offset..<newline]) as? [String: Any],
               let payload = object["payload"] as? [String: Any],
               payload["type"] as? String == "token_count",
               let info = payload["info"] as? [String: Any],
               let total = info["total_token_usage"] as? [String: Any] {
                signatures[lineNumber] = TotalUsageSignature(total)
            }
            offset = newline < data.count ? newline + 1 : data.count
            lineNumber += 1
        }
        return signatures
    }

    private static func isForkedSession(at path: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return false
        }
        defer { try? handle.close() }

        var firstLine = Data()
        while firstLine.count < 1_048_576 {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: 65_536), !next.isEmpty else {
                    break
                }
                chunk = next
            } catch {
                break
            }
            firstLine.append(chunk)
            if let newline = firstLine.firstIndex(of: 0x0A) {
                firstLine = firstLine[..<newline]
                break
            }
        }
        guard let object = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any] else {
            return false
        }
        return (payload["forked_from_id"] as? String)?.isEmpty == false
    }
}

private struct DuplicateCandidate {
    let id: Int64
    let path: String
    let line: Int
    let previousLine: Int
}

private struct TotalUsageSignature: Equatable {
    let input: Int
    let cachedInput: Int
    let output: Int
    let reasoningOutput: Int
    let total: Int

    init(_ dictionary: [String: Any]) {
        input = Self.integer(dictionary["input_tokens"])
        cachedInput = Self.integer(dictionary["cached_input_tokens"])
        output = Self.integer(dictionary["output_tokens"])
        reasoningOutput = Self.integer(dictionary["reasoning_output_tokens"])
        total = Self.integer(dictionary["total_tokens"])
    }

    private static func integer(_ value: Any?) -> Int {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value) ?? 0
        default:
            return 0
        }
    }
}
