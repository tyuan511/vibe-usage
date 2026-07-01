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
}
