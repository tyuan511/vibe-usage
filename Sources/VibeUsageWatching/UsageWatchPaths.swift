import Foundation
import VibeUsageCore

enum UsageWatchPaths {
    static func directories(from registry: AdapterRegistry) -> [String] {
        var paths = Set<String>()
        let fileManager = FileManager.default

        for adapter in registry.allAdapters {
            for url in adapter.discoverRootDirectories() {
                var isDirectory: ObjCBool = false
                let path = url.standardizedFileURL.path
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    continue
                }
                paths.insert(path)
            }
        }

        return paths.sorted()
    }

    /// Maps FSEvents paths to adapters whose roots contain them.
    /// Returns an empty set when a path cannot be attributed, so callers can fall back to a full scan.
    static func sourceIDs(forChangedPaths paths: [String], registry: AdapterRegistry) -> Set<AgentSourceID> {
        guard !paths.isEmpty else { return [] }

        let rootsBySource: [(id: AgentSourceID, roots: [String])] = registry.allAdapters.map { adapter in
            let roots = adapter.discoverRootDirectories().map {
                standardizedPath($0.standardizedFileURL.path)
            }
            return (adapter.descriptor.id, roots)
        }

        var matched = Set<AgentSourceID>()
        for rawPath in paths {
            let path = standardizedPath(rawPath)
            var found = false
            for entry in rootsBySource {
                if entry.roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                    matched.insert(entry.id)
                    found = true
                }
            }
            if !found {
                return []
            }
        }
        return matched
    }

    /// Normalizes FSEvents paths for file-level filtering.
    /// SQLite sidecar files (`-wal` / `-shm`) map back to the main database path.
    static func normalizedChangedPaths(_ paths: [String]) -> Set<String> {
        Set(paths.map(canonicalWatchPath))
    }

    /// Whether a discovered file should be considered for a path-filtered scan.
    static func file(_ filePath: String, matchesChangedPaths changedPaths: Set<String>) -> Bool {
        guard !changedPaths.isEmpty else { return true }
        let normalized = Set(changedPaths.map(canonicalWatchPath))
        let candidate = standardizedPath(filePath)
        if normalized.contains(candidate) {
            return true
        }
        return normalized.contains { changed in
            candidate == changed
                || candidate.hasPrefix(changed + "/")
                || changed.hasPrefix(candidate + "/")
        }
    }

    static func canonicalWatchPath(_ path: String) -> String {
        var normalized = standardizedPath(path)
        for suffix in ["-wal", "-shm", "-journal"] where normalized.hasSuffix(suffix) {
            normalized.removeLast(suffix.count)
            break
        }
        return normalized
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
