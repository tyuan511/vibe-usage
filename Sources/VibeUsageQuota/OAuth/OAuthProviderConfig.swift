import Foundation
import VibeUsageCore

/// How a provider delivers the authorization code back to the app after the
/// user approves consent in the browser.
public enum OAuthCallbackStyle: Sendable, Equatable {
    /// A local HTTP server binds `127.0.0.1:port` and the OAuth redirect_uri
    /// points at it directly (Codex).
    case loopback(port: Int, path: String)
    /// No browser flow: the token is imported from the provider's own CLI
    /// credential store (Claude — Anthropic blocks third-party OAuth token
    /// minting server-side, so VibeUsage reuses Claude Code's existing token
    /// like CodexBar does). See `ClaudeCLICredentialReader`.
    case importFromCLI
}

/// How a provider's token endpoint expects the `authorization_code` /
/// `refresh_token` request body to be encoded. The two providers differ:
/// Anthropic's `console.anthropic.com/v1/oauth/token` expects a JSON body
/// (and returns 403 for form-encoded); OpenAI's `auth.openai.com/oauth/token`
/// is a standard `application/x-www-form-urlencoded` endpoint.
public enum OAuthTokenRequestEncoding: Sendable, Equatable {
    case json
    case formURLEncoded
}

/// Static OAuth client configuration for a single quota-connectable provider.
/// Every value marked "VERIFY" below is a best-effort community-sourced
/// constant (VibeUsage has no first-party client registration of its own for
/// either provider) and is deliberately isolated here as a single named
/// constant so it's trivial to correct once verified against a live account.
public struct OAuthProviderConfig: Sendable, Equatable {
    public let provider: AgentSourceID
    public let authorizeURL: URL
    public let tokenURL: URL
    public let clientID: String
    public let redirectURI: String
    public let scopes: [String]
    public let callbackStyle: OAuthCallbackStyle
    /// Extra provider-specific query items appended to the authorize URL
    /// beyond the standard OAuth/PKCE set (Codex requires
    /// `codex_cli_simplified_flow` for the loopback code response and
    /// `id_token_add_organizations` so org claims land in the id_token).
    public let extraAuthorizeParams: [String: String]
    public let tokenRequestEncoding: OAuthTokenRequestEncoding
    /// Whether the `authorization_code` exchange body must echo the `state`
    /// value. Anthropic requires it (403 otherwise); OpenAI's standard token
    /// endpoint does not expect it in the body (state is validated via the
    /// loopback redirect instead).
    public let includesStateInTokenRequest: Bool

    public init(
        provider: AgentSourceID,
        authorizeURL: URL,
        tokenURL: URL,
        clientID: String,
        redirectURI: String,
        scopes: [String],
        callbackStyle: OAuthCallbackStyle,
        extraAuthorizeParams: [String: String] = [:],
        tokenRequestEncoding: OAuthTokenRequestEncoding,
        includesStateInTokenRequest: Bool
    ) {
        self.provider = provider
        self.authorizeURL = authorizeURL
        self.tokenURL = tokenURL
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.callbackStyle = callbackStyle
        self.extraAuthorizeParams = extraAuthorizeParams
        self.tokenRequestEncoding = tokenRequestEncoding
        self.includesStateInTokenRequest = includesStateInTokenRequest
    }

    /// Builds the full `authorize` URL (including PKCE + state query params)
    /// the browser should be opened to.
    public func authorizeURL(codeChallenge: String, state: String) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        items.append(contentsOf: extraAuthorizeParams.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        })
        components.queryItems = items
        return components.url!
    }

    // MARK: - Codex / OpenAI (ChatGPT)

    /// Loopback port the Codex CLI's public client_id has registered as its
    /// redirect_uri; VibeUsage must bind this exact port for the redirect to
    /// resolve. Not a VibeUsage choice — fixed by the client_id's registration.
    public static let codexLoopbackPort = 1455
    public static let codexLoopbackPath = "/auth/callback"

    /// Public client_id used by the Codex CLI's own `codex login` OAuth flow.
    /// VERIFY: sourced from community reverse-engineering of the Codex CLI;
    /// reused here (not read from the CLI's own token storage) so VibeUsage
    /// can mint and hold entirely separate tokens under the same app
    /// registration Anthropic/OpenAI already trust for a loopback redirect.
    public static let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    /// VERIFY: `offline_access` is included deliberately (beyond whatever the
    /// CLI itself requests) to guarantee a refresh_token is issued.
    public static let codexScopes = ["openid", "profile", "email", "offline_access"]

    public static let codex = OAuthProviderConfig(
        provider: .codexQuota,
        authorizeURL: URL(string: "https://auth.openai.com/oauth/authorize")!,
        tokenURL: URL(string: "https://auth.openai.com/oauth/token")!,
        clientID: codexClientID,
        redirectURI: "http://localhost:\(codexLoopbackPort)\(codexLoopbackPath)",
        scopes: codexScopes,
        callbackStyle: .loopback(port: codexLoopbackPort, path: codexLoopbackPath),
        extraAuthorizeParams: [
            "id_token_add_organizations": "true",
            "codex_cli_simplified_flow": "true"
        ],
        tokenRequestEncoding: .formURLEncoded,
        includesStateInTokenRequest: false
    )

    // MARK: - Claude / Anthropic

    /// Public client_id used by the Claude Code CLI's own OAuth flow, needed
    /// as the `client_id` when refreshing the reused Claude Code token.
    public static let claudeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// Anthropic moved the OAuth token endpoint off the now-dead
    /// `console.anthropic.com` host; `platform.claude.com` is the current one
    /// (used here only to refresh a reused Claude Code token).
    public static let claudeTokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    /// Claude is `.importFromCLI`: there is no VibeUsage-driven browser
    /// authorize step (Anthropic blocks third-party token minting), so the
    /// authorize/redirect/scope fields are unused placeholders here — only the
    /// token URL + client id matter, and only for the refresh grant.
    public static let claude = OAuthProviderConfig(
        provider: .claudeQuota,
        authorizeURL: claudeTokenURL,
        tokenURL: claudeTokenURL,
        clientID: claudeClientID,
        redirectURI: "",
        scopes: [],
        callbackStyle: .importFromCLI,
        tokenRequestEncoding: .json,
        includesStateInTokenRequest: false
    )
}
