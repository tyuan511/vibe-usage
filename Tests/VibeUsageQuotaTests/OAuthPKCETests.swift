import Foundation
import Testing
@testable import VibeUsageQuota

@Suite struct OAuthPKCETests {
    /// RFC 7636 Appendix B test vector.
    @Test func challengeMatchesRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = OAuthPKCE.challenge(forVerifier: verifier)
        #expect(challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func generatedVerifierIsWithinRFCLengthRange() {
        let verifier = OAuthPKCE.generateVerifier()
        #expect(verifier.count >= 43 && verifier.count <= 128)
        #expect(!verifier.contains("+"))
        #expect(!verifier.contains("/"))
        #expect(!verifier.contains("="))
    }

    @Test func generatePairsAreConsistent() {
        let (verifier, challenge) = OAuthPKCE.generate()
        #expect(OAuthPKCE.challenge(forVerifier: verifier) == challenge)
    }

    @Test func generateProducesDistinctVerifiersEachCall() {
        let first = OAuthPKCE.generateVerifier()
        let second = OAuthPKCE.generateVerifier()
        #expect(first != second)
    }
}

@Suite struct OAuthProviderConfigTests {
    @Test func codexAuthorizeURLCarriesSimplifiedFlowAndOrgParams() throws {
        let url = OAuthProviderConfig.codex.authorizeURL(codeChallenge: "chal", state: "st")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(items["codex_cli_simplified_flow"] == "true")
        #expect(items["id_token_add_organizations"] == "true")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["client_id"] == OAuthProviderConfig.codexClientID)
    }

    @Test func claudeAuthorizeURLHasNoCodexOnlyParams() throws {
        let url = OAuthProviderConfig.claude.authorizeURL(codeChallenge: "chal", state: "st")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let names = Set((components.queryItems ?? []).map(\.name))
        #expect(!names.contains("codex_cli_simplified_flow"))
        #expect(names.contains("state"))
    }
}
