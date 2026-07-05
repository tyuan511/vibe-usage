import Foundation

/// Tokens obtained from a provider's OAuth token endpoint, normalized across
/// Claude and Codex's slightly different response shapes.
public struct OAuthTokens: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    /// Codex-only: `account_id` claim pulled out of the `id_token` JWT,
    /// required as the `ChatGPT-Account-Id` header on usage requests.
    public let accountID: String?
    /// Codex-only: the `chatgpt_plan_type` claim (e.g. `"free"`, `"go"`,
    /// `"plus"`, `"pro"`), when the id_token carries one. `nil` for Claude —
    /// its plan comes from the imported CLI credential's `subscriptionType`
    /// instead, not from a token response.
    public let planType: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, accountID: String?, planType: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountID = accountID
        self.planType = planType
    }
}

public enum OAuthTokenError: Error, Equatable, LocalizedError {
    case invalidResponse
    case httpError(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid OAuth token response"
        case .httpError(let code): "OAuth token endpoint returned HTTP \(code)"
        }
    }
}

/// Wire shape shared by both providers' token endpoints (Codex additionally
/// returns `id_token`, which callers decode separately via ``JWTClaims``).
private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Double?
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case idToken = "id_token"
    }
}

/// Performs the authorization_code exchange and refresh_token grant against
/// a provider's token endpoint, reusing the injectable ``HTTPFetching`` seam
/// so tests never make live network calls.
public struct OAuthTokenClient: Sendable {
    private let fetcher: any HTTPFetching
    private let now: @Sendable () -> Date

    public init(fetcher: any HTTPFetching = URLSessionHTTPFetcher(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.fetcher = fetcher
        self.now = now
    }

    /// `grant_type=authorization_code` exchange. `state` is echoed back into
    /// the request body only when the provider requires it (Anthropic does;
    /// OpenAI does not — see `OAuthProviderConfig.includesStateInTokenRequest`).
    public func exchange(code: String, verifier: String, state: String?, config: OAuthProviderConfig) async throws -> OAuthTokens {
        var parameters: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURI,
            "client_id": config.clientID,
            "code_verifier": verifier
        ]
        if config.includesStateInTokenRequest, let state {
            parameters["state"] = state
        }
        return try await request(url: config.tokenURL, parameters: parameters, encoding: config.tokenRequestEncoding)
    }

    /// `grant_type=refresh_token` exchange.
    public func refresh(refreshToken: String, config: OAuthProviderConfig) async throws -> OAuthTokens {
        let parameters: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientID
        ]
        return try await request(url: config.tokenURL, parameters: parameters, encoding: config.tokenRequestEncoding)
    }

    private func request(url: URL, parameters: [String: String], encoding: OAuthTokenRequestEncoding) async throws -> OAuthTokens {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch encoding {
        case .json:
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: parameters)
        case .formURLEncoded:
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formEncode(parameters).data(using: .utf8)
        }

        let (data, response) = try await fetcher.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw OAuthTokenError.httpError(response.statusCode)
        }

        let decoded: TokenResponse
        do {
            decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw OAuthTokenError.invalidResponse
        }
        guard !decoded.accessToken.isEmpty else {
            throw OAuthTokenError.invalidResponse
        }

        let expiresAt = now().addingTimeInterval(decoded.expiresIn ?? 3600)
        let accountID = JWTClaims.chatGPTAccountID(idToken: decoded.idToken, accessToken: decoded.accessToken)
        let planType = JWTClaims.chatGPTPlanType(idToken: decoded.idToken, accessToken: decoded.accessToken)

        return OAuthTokens(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken,
            expiresAt: expiresAt,
            accountID: accountID,
            planType: planType
        )
    }

    private static func formEncode(_ parameters: [String: String]) -> String {
        parameters
            .map { key, value in
                let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }
}

/// Reads claims out of a JWT's payload segment without verifying its
/// signature. Safe here because the JWT in question (Codex's `id_token`) was
/// issued directly to us over TLS by the provider's own token endpoint in the
/// same request/response we're already trusting — we're not accepting this
/// token from an untrusted third party.
public enum JWTClaims {
    /// Extracts the ChatGPT account id, trying the `id_token` first and then
    /// the `access_token`. Codex's usage endpoint needs this as the
    /// `ChatGPT-Account-Id` header. Matches the Codex CLI's own three-level
    /// claim fallback (see 7shi/codex-oauth `extract_account_id`):
    ///   1. top-level `chatgpt_account_id`
    ///   2. `https://api.openai.com/auth` → `chatgpt_account_id`
    ///   3. `organizations[0].id`
    public static func chatGPTAccountID(idToken: String?, accessToken: String?) -> String? {
        for token in [idToken, accessToken] {
            guard let token, let payload = payload(fromJWT: token) else { continue }
            if let id = accountID(fromPayload: payload) { return id }
        }
        return nil
    }

    static func accountID(fromPayload payload: [String: Any]) -> String? {
        if let id = payload["chatgpt_account_id"] as? String, !id.isEmpty {
            return id
        }
        if let auth = payload["https://api.openai.com/auth"] as? [String: Any],
           let id = auth["chatgpt_account_id"] as? String, !id.isEmpty {
            return id
        }
        if let orgs = payload["organizations"] as? [[String: Any]],
           let id = orgs.first?["id"] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    /// Extracts the ChatGPT plan type (e.g. `"free"`, `"go"`, `"plus"`,
    /// `"pro"`), trying `id_token` first and then `access_token`, at the same
    /// two claim locations `chatgpt_account_id` is found at (no organizations
    /// fallback — plan type has no equivalent there).
    public static func chatGPTPlanType(idToken: String?, accessToken: String?) -> String? {
        for token in [idToken, accessToken] {
            guard let token, let payload = payload(fromJWT: token) else { continue }
            if let plan = planType(fromPayload: payload) { return plan }
        }
        return nil
    }

    static func planType(fromPayload payload: [String: Any]) -> String? {
        if let plan = payload["chatgpt_plan_type"] as? String, !plan.isEmpty {
            return plan
        }
        if let auth = payload["https://api.openai.com/auth"] as? [String: Any],
           let plan = auth["chatgpt_plan_type"] as? String, !plan.isEmpty {
            return plan
        }
        return nil
    }

    /// Base64url-decodes the payload segment of a `header.payload.signature`
    /// JWT and parses it as a JSON object. Returns `nil` for any malformed
    /// input rather than throwing, since a missing/garbled claim should just
    /// mean "no account id available", not a hard failure.
    static func payload(fromJWT token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        guard let data = base64URLDecode(String(segments[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}
