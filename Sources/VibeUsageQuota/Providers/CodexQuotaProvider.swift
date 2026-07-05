import Foundation
import VibeUsageCore

/// Fetches Codex/ChatGPT subscription rate-limit usage via
/// `GET https://chatgpt.com/backend-api/wham/usage`, using a valid access
/// token (and optional account id) supplied by the caller
/// (``QuotaConnectionManager``, which owns VibeUsage's own connected-account
/// tokens — this type never reads credentials itself).
///
/// This endpoint's response schema is not publicly documented; window field
/// names are guessed defensively via `QuotaWindowExtractor` (see that type's
/// doc comment) and the raw JSON is dumped in DEBUG builds so the real shape
/// can be verified against a live account.
public struct CodexQuotaProvider: Sendable {
    public let sourceID: AgentSourceID = .codexQuota
    public let displayName = "Codex"

    private let fetcher: any HTTPFetching
    private let now: @Sendable () -> Date

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// `primary_window`'s actual meaning depends on the account's plan, not
    /// on the key name: free accounts only get a single rolling 30-day
    /// quota (reported as `primary_window` with no `secondary_window` at
    /// all), while paid accounts (Plus/Pro/Team) get a 5-hour `primary_window`
    /// stacked with a 7-day `secondary_window`. So the label can't be a fixed
    /// string per key — it's derived from whether `secondary_window` is also
    /// present in the same payload, which is the actual tier signal.
    private static let secondaryWindowLabel = VibeUsageStrings.text(zh: "7 日额度", en: "7-Day Quota")
    private static let pairedPrimaryWindowLabel = VibeUsageStrings.text(zh: "5 小时额度", en: "5-Hour Quota")
    private static let soloPrimaryWindowLabel = VibeUsageStrings.text(zh: "30 日额度", en: "30-Day Quota")

    public init(
        fetcher: any HTTPFetching = URLSessionHTTPFetcher(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetcher = fetcher
        self.now = now
    }

    /// Fetches with the given already-valid access token / account id.
    /// Callers are expected to have obtained the token from
    /// `QuotaConnectionManager.validAccessToken(for:)` (which handles
    /// refreshing) before calling.
    public func fetch(accessToken: String, accountID: String?) async -> QuotaSourceSnapshot {
        let fetchedAt = now()

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, response) = try await fetcher.data(for: request)

            #if DEBUG
            if let raw = String(data: data, encoding: .utf8) {
                print("[VibeUsageQuota] Codex /backend-api/wham/usage raw response: \(raw)")
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
        guard let object = root.objectValue,
              let rateLimit = object["rate_limit"]?.objectValue else {
            return []
        }

        let hasSecondaryWindow = rateLimit["secondary_window"]?.objectValue != nil
        let definitions: [(key: String, label: String)] = [
            ("primary_window", hasSecondaryWindow ? pairedPrimaryWindowLabel : soloPrimaryWindowLabel),
            ("secondary_window", secondaryWindowLabel)
        ]

        var windows: [QuotaWindow] = []
        for definition in definitions {
            guard let windowObject = rateLimit[definition.key]?.objectValue else { continue }
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
