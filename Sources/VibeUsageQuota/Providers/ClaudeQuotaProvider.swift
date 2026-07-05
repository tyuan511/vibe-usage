import Foundation
import VibeUsageCore

/// Fetches Claude Code's subscription rate-limit usage via
/// `GET https://api.anthropic.com/api/oauth/usage`, using a valid access
/// token supplied by the caller (``QuotaConnectionManager``, which owns
/// VibeUsage's own connected-account tokens — this type never reads
/// credentials itself).
///
/// This endpoint's response schema is not publicly documented; window field
/// names are guessed defensively via `QuotaWindowExtractor` (see that type's
/// doc comment) and the raw JSON is dumped in DEBUG builds so the real shape
/// can be verified against a live account.
public struct ClaudeQuotaProvider: Sendable {
    public let sourceID: AgentSourceID = .claudeQuota
    public let displayName = "Claude"

    private let fetcher: any HTTPFetching
    private let now: @Sendable () -> Date

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Window keys to surface, in display order, with bilingual labels.
    /// `seven_day_cowork` / `extra_usage` are intentionally omitted from v1
    /// display (not part of the documented set of three) but are harmless if
    /// present in the payload — they're simply not extracted into a window.
    private static let windowDefinitions: [(key: String, label: String)] = [
        ("five_hour", VibeUsageStrings.text(zh: "5 小时额度", en: "5-Hour Quota")),
        ("seven_day", VibeUsageStrings.text(zh: "7 日额度", en: "7-Day Quota")),
        ("seven_day_opus", VibeUsageStrings.text(zh: "7 日 Opus 额度", en: "7-Day Opus Quota")),
        ("seven_day_sonnet", VibeUsageStrings.text(zh: "7 日 Sonnet 额度", en: "7-Day Sonnet Quota"))
    ]

    public init(
        fetcher: any HTTPFetching = URLSessionHTTPFetcher(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.now = now
    }

    /// Fetches with the given already-valid access token. Callers are
    /// expected to have obtained this from `QuotaConnectionManager
    /// .validAccessToken(for:)` (which handles refreshing) before calling.
    public func fetch(accessToken: String) async -> QuotaSourceSnapshot {
        let fetchedAt = now()

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        do {
            let (data, response) = try await fetcher.data(for: request)

            #if DEBUG
            if let raw = String(data: data, encoding: .utf8) {
                print("[VibeUsageQuota] Claude /api/oauth/usage raw response: \(raw)")
            }
            #endif

            if response.statusCode == 401 {
                return snapshot(.unauthorized, at: fetchedAt)
            }
            guard (200..<300).contains(response.statusCode) else {
                return snapshot(.networkError("HTTP \(response.statusCode)"), at: fetchedAt)
            }

            let windows = try Self.parseWindows(data: data, now: fetchedAt)
            return snapshot(.ok(windows), at: fetchedAt)
        } catch {
            return snapshot(.networkError(error.localizedDescription), at: fetchedAt)
        }
    }

    static func parseWindows(data: Data, now: Date) throws -> [QuotaWindow] {
        let root = try JSONDecoder().decode(QuotaJSONValue.self, from: data)
        guard let object = root.objectValue else { return [] }

        var windows: [QuotaWindow] = []
        for definition in windowDefinitions {
            guard let windowObject = object[definition.key]?.objectValue else { continue }
            guard let usedFraction = QuotaWindowExtractor.usedFraction(from: windowObject) else { continue }
            let resetsAt = QuotaWindowExtractor.resetsAt(from: windowObject, now: now)
            windows.append(
                QuotaWindow(
                    id: definition.key,
                    label: definition.label,
                    usedFraction: usedFraction,
                    usedPercentText: QuotaFormatting.percentText(usedFraction: usedFraction),
                    resetsAt: resetsAt,
                    resetCountdownText: QuotaFormatting.countdownText(resetsAt: resetsAt, now: now)
                )
            )
        }
        return windows
    }

    private func snapshot(_ state: QuotaSourceState, at fetchedAt: Date) -> QuotaSourceSnapshot {
        QuotaSourceSnapshot(sourceID: sourceID, displayName: displayName, state: state, fetchedAt: fetchedAt)
    }
}
