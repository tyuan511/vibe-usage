import Foundation

/// A humanized, display-ready view of a raw `project_or_workspace` value from
/// the usage store.
///
/// `key` is the canonical merge key: when the raw value resolves to an
/// absolute path, `key` is that normalized path so the *same* project
/// reported by multiple sources (e.g. Claude Code's munged
/// `-Users-me-code-app` and OpenCode's real `/Users/me/code/app`) collapses
/// into a single row in the UI. When resolution fails, `key` falls back to a
/// stable value derived from the raw input so unrelated projects never
/// accidentally collide.
public struct HumanizedProject: Sendable, Equatable {
    public let key: String
    public let title: String
    public let subtitle: String?

    public init(key: String, title: String, subtitle: String?) {
        self.key = key
        self.title = title
        self.subtitle = subtitle
    }
}

/// Turns raw `project_or_workspace` strings (which vary wildly in shape
/// across adapters) into a display title/subtitle plus a canonical merge key.
///
/// Handles three known-messy shapes seen in real data:
/// - Claude Code stores paths with `/` replaced by `-` (e.g.
///   `-Users-yuantang-code-vibe-usage`), which is ambiguous whenever a real
///   directory name itself contains a hyphen. This type resolves the
///   ambiguity by greedily probing the filesystem for the longest existing
///   directory at each segment boundary.
/// - Codex CLI stores date-like session folder names (`2025/09/19`) instead
///   of a project; those are treated as "ungrouped", not a project.
/// - Empty strings are also "ungrouped".
///
/// Not `Sendable`: it owns a mutable cache and is intended to be constructed
/// fresh per snapshot render on the main actor (UI layer), not shared across
/// threads.
public final class ProjectNameHumanizer {
    private let homeDirectory: String
    private let directoryExists: (String) -> Bool
    private var cache: [String: HumanizedProject?] = [:]

    public init(
        homeDirectory: String = NSHomeDirectory(),
        directoryExists: @escaping (String) -> Bool = ProjectNameHumanizer.defaultDirectoryExists
    ) {
        self.homeDirectory = homeDirectory
        self.directoryExists = directoryExists
    }

    public static func defaultDirectoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// Returns `nil` when `raw` should be bucketed as "ungrouped" by the
    /// caller (empty or date-like values).
    public func humanize(_ raw: String) -> HumanizedProject? {
        if let cached = cache[raw] {
            return cached
        }
        let result = compute(raw)
        cache[raw] = result
        return result
    }

    private func compute(_ raw: String) -> HumanizedProject? {
        // a. Empty -> ungrouped.
        if raw.isEmpty {
            return nil
        }

        // b. Date-like values (session date folders, not projects) -> ungrouped.
        if Self.dateLikeRegex.firstMatch(
            in: raw,
            range: NSRange(raw.startIndex..., in: raw)
        ) != nil {
            return nil
        }

        // c. Claude-style munged absolute paths.
        if raw.hasPrefix("-") {
            return humanizeMungedPath(raw)
        }

        // d. Normal absolute paths.
        if raw.hasPrefix("/") {
            return humanizePath(raw, key: raw)
        }

        // e. Bare names: passthrough.
        return HumanizedProject(key: raw, title: raw, subtitle: nil)
    }

    /// Decodes a Claude-style path where every `/` was replaced by `-`, by
    /// greedily probing the filesystem: at each segment boundary, prefer
    /// treating the boundary as a real path separator if the directory
    /// formed so far exists; otherwise keep the hyphen as a literal character
    /// in the current segment name.
    private func humanizeMungedPath(_ raw: String) -> HumanizedProject {
        let body = String(raw.dropFirst()) // drop leading "-"
        let segments = body.split(separator: "-", omittingEmptySubsequences: false).map(String.init)

        guard !segments.isEmpty else {
            return HumanizedProject(key: raw, title: raw, subtitle: nil)
        }

        // Greedy probing with lookahead: at each position, prefer the
        // longest run of remaining hyphen-joined segments that forms an
        // existing directory under the path resolved so far. This resolves
        // ambiguity like "code-vibe-usage" -> "code/vibe-usage" (not
        // "code-vibe/usage") when only the former exists on disk.
        var resolvedPath = ""
        var index = 0
        while index < segments.count {
            var bestEnd = index + 1
            var matched = false
            var end = segments.count
            while end > index {
                let candidateComponent = segments[index..<end].joined(separator: "-")
                let candidatePath = resolvedPath + "/" + candidateComponent
                if directoryExists(candidatePath) {
                    bestEnd = end
                    matched = true
                    break
                }
                end -= 1
            }
            let component: String
            if matched {
                component = segments[index..<bestEnd].joined(separator: "-")
            } else {
                component = segments[index]
            }
            resolvedPath += "/" + component
            index = matched ? bestEnd : index + 1
        }

        if directoryExists(resolvedPath) {
            return humanizePath(resolvedPath, key: resolvedPath)
        }

        // Probing failed to land on a real directory anywhere: fall back to
        // naive all-"/" replacement for display, but keep the raw string as
        // the merge key so we don't silently collide unrelated projects.
        let naivePath = "/" + body.replacingOccurrences(of: "-", with: "/")
        let displayOnly = humanizePath(naivePath, key: raw)
        return HumanizedProject(key: raw, title: displayOnly.title, subtitle: displayOnly.subtitle)
    }

    private func humanizePath(_ path: String, key: String) -> HumanizedProject {
        let title = (path as NSString).lastPathComponent
        let subtitle = abbreviatedPath(path)
        return HumanizedProject(
            key: key,
            title: title.isEmpty ? path : title,
            subtitle: subtitle
        )
    }

    private func abbreviatedPath(_ path: String) -> String {
        guard !homeDirectory.isEmpty, path.hasPrefix(homeDirectory) else {
            return path
        }
        let remainder = path.dropFirst(homeDirectory.count)
        if remainder.isEmpty {
            return "~"
        }
        guard remainder.hasPrefix("/") else {
            return path
        }
        return "~" + remainder
    }

    private static let dateLikeRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "^\\d{4}[/-]\\d{2}[/-]\\d{2}$")
    }()
}
