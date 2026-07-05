import Foundation
import Testing
@testable import VibeUsageQuota

@Suite struct OAuthTokenClientTests {
    /// Captures the outgoing request so the body/headers can be asserted.
    private final class CapturingFetcher: HTTPFetching, @unchecked Sendable {
        var captured: URLRequest?
        let responseBody: Data

        init(responseBody: Data) { self.responseBody = responseBody }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            captured = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (responseBody, response)
        }
    }

    private static let tokenResponse = Data(#"{"access_token":"a","refresh_token":"r","expires_in":3600}"#.utf8)

    @Test func codexExchangeSendsFormBodyWithoutState() async throws {
        let fetcher = CapturingFetcher(responseBody: Self.tokenResponse)
        let client = OAuthTokenClient(fetcher: fetcher)

        _ = try await client.exchange(code: "c", verifier: "v", state: "s", config: .codex)

        let request = try #require(fetcher.captured)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let bodyData = try #require(request.httpBody)
        let body = String(decoding: bodyData, as: UTF8.self)
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code_verifier=v"))
        // OpenAI's token endpoint validates state via the loopback redirect,
        // not the body; echoing an unexpected `state` field is avoided.
        #expect(!body.contains("state="))
    }

    @Test func claudeRefreshSendsJSONBody() async throws {
        let fetcher = CapturingFetcher(responseBody: Self.tokenResponse)
        let client = OAuthTokenClient(fetcher: fetcher)

        _ = try await client.refresh(refreshToken: "old-refresh", config: .claude)

        let request = try #require(fetcher.captured)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let refreshBody = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: refreshBody) as? [String: String])
        #expect(json["grant_type"] == "refresh_token")
        #expect(json["refresh_token"] == "old-refresh")
    }

    /// Codex's token response includes an `id_token` JWT carrying
    /// `chatgpt_plan_type`; the client must surface it on `OAuthTokens` so
    /// `QuotaConnectionManager` can persist it as the account's tier.
    @Test func exchangeExtractsPlanTypeFromIDToken() async throws {
        let idToken = Self.jwt(#"{"chatgpt_account_id":"acct-1","chatgpt_plan_type":"plus"}"#)
        let responseBody = Data(#"{"access_token":"a","refresh_token":"r","expires_in":3600,"id_token":"\#(idToken)"}"#.utf8)
        let fetcher = CapturingFetcher(responseBody: responseBody)
        let client = OAuthTokenClient(fetcher: fetcher)

        let tokens = try await client.exchange(code: "c", verifier: "v", state: nil, config: .codex)

        #expect(tokens.planType == "plus")
        #expect(tokens.accountID == "acct-1")
    }

    @Test func exchangeReturnsNilPlanTypeWhenIDTokenAbsent() async throws {
        let fetcher = CapturingFetcher(responseBody: Self.tokenResponse)
        let client = OAuthTokenClient(fetcher: fetcher)

        let tokens = try await client.exchange(code: "c", verifier: "v", state: nil, config: .codex)

        #expect(tokens.planType == nil)
    }

    private static func jwt(_ payload: String) -> String {
        "eyJhbGciOiJub25lIn0." + base64URL(payload) + ".signature"
    }

    private static func base64URL(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
