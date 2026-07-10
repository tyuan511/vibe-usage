import Foundation

/// Resolves a raw, source-reported model identifier to the family key used
/// for pricing lookup and for "by model" grouping in the UI.
///
/// Claude model ids commonly carry a trailing release-date suffix
/// (`claude-sonnet-4-20250514`) that must be stripped to match the pricing
/// snapshot's un-dated family keys (`claude-sonnet-4`). OpenAI/Codex model
/// ids are normally already bare family names (`gpt-5.1-codex-max`) and pass
/// through unchanged, since the pattern below only matches a trailing
/// 8-digit calendar-date-shaped suffix.
public enum ModelAliasResolver {
    // Matches a trailing "-YYYYMMDD" where YYYYMMDD is a plausible calendar
    // date, so a legitimate model name that happens to end in 8 digits for
    // some other reason isn't accidentally truncated.
    private static let dateSuffixPattern = #/-(20\d{2})(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])$/#

    public static func resolveFamily(fromRawModel model: String) -> String {
        guard let range = model.firstRange(of: dateSuffixPattern) else {
            return model
        }
        return String(model[model.startIndex..<range.lowerBound])
    }

    public static func pricingCandidates(fromRawModel model: String, at timestamp: Date?) -> [String] {
        let bareModel = model.split(separator: "/").last.map(String.init) ?? model
        let family = resolveFamily(fromRawModel: bareModel)
        var candidates = [family]
        let normalizedClaudeFamily = normalizeClaudeVersion(from: family)
        if normalizedClaudeFamily != family {
            candidates.append(normalizedClaudeFamily)
        }

        switch family {
        case "gemini-3-pro-high":
            candidates.append("gemini-3-pro-preview")
        case "k2p6":
            candidates.append("kimi-k2.6")
        case "kimi-for-coding":
            let kimiForCodingK26Cutover = Date(timeIntervalSince1970: 1_776_698_890.072)
            candidates.append((timestamp ?? .distantFuture) < kimiForCodingK26Cutover ? "kimi-k2.5" : "kimi-k2.6")
        default:
            break
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    public static func normalizeClaudeVersion(from model: String) -> String {
        for family in ["claude-haiku-", "claude-opus-", "claude-sonnet-"] where model.hasPrefix(family) {
            let rest = String(model.dropFirst(family.count))
            if let dot = rest.firstIndex(of: ".") {
                let major = String(rest[..<dot])
                let suffix = String(rest[rest.index(after: dot)...])
                if major.allSatisfy(\.isNumber), suffix.first?.isNumber == true {
                    return "\(family)\(major)-\(suffix)"
                }
            }
            let characters = Array(rest)
            if characters.count >= 2, characters[0].isNumber, characters[1].isNumber {
                return "\(family)\(characters[0])-\(String(characters.dropFirst()))"
            }
        }
        return model
    }
}
