import Foundation
import Testing
import VibeUsageCore
@testable import VibeUsageQuota

@Suite struct ConnectedAccountStoreTests {
    @Test func loadReturnsNilWhenNothingSaved() {
        let store = InMemoryConnectedAccountStore()
        #expect(store.load(.claudeQuota) == nil)
    }

    @Test func saveThenLoadRoundTrips() {
        let store = InMemoryConnectedAccountStore()
        let account = ConnectedAccount(
            accessToken: "tok",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            accountID: "acc-1",
            subscriptionType: "max"
        )
        store.save(account, for: .claudeQuota)
        #expect(store.load(.claudeQuota) == account)
    }

    @Test func clearRemovesTheStoredAccount() {
        let store = InMemoryConnectedAccountStore()
        store.save(ConnectedAccount(accessToken: "tok", refreshToken: nil, expiresAt: Date()), for: .codexQuota)
        store.clear(.codexQuota)
        #expect(store.load(.codexQuota) == nil)
    }

    @Test func providersAreStoredIndependently() {
        let store = InMemoryConnectedAccountStore()
        store.save(ConnectedAccount(accessToken: "claude-tok", refreshToken: nil, expiresAt: Date()), for: .claudeQuota)
        store.save(ConnectedAccount(accessToken: "codex-tok", refreshToken: nil, expiresAt: Date()), for: .codexQuota)
        #expect(store.load(.claudeQuota)?.accessToken == "claude-tok")
        #expect(store.load(.codexQuota)?.accessToken == "codex-tok")
    }
}

// MARK: - JWT claim extraction

@Suite struct JWTClaimsTests {
    @Test func extractsTopLevelChatGPTAccountID() {
        let payload = #"{"chatgpt_account_id":"acct-123","sub":"user-1"}"#
        let idToken = jwt(payload)
        #expect(JWTClaims.chatGPTAccountID(idToken: idToken, accessToken: nil) == "acct-123")
    }

    @Test func fallsBackToNestedAuthClaim() {
        let payload = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"nested-9"}}"#
        #expect(JWTClaims.chatGPTAccountID(idToken: jwt(payload), accessToken: nil) == "nested-9")
    }

    @Test func fallsBackToFirstOrganizationID() {
        let payload = #"{"organizations":[{"id":"org-1"},{"id":"org-2"}]}"#
        #expect(JWTClaims.chatGPTAccountID(idToken: jwt(payload), accessToken: nil) == "org-1")
    }

    @Test func fallsBackFromIDTokenToAccessToken() {
        let idToken = jwt(#"{"sub":"user-1"}"#)
        let accessToken = jwt(#"{"chatgpt_account_id":"from-access"}"#)
        #expect(JWTClaims.chatGPTAccountID(idToken: idToken, accessToken: accessToken) == "from-access")
    }

    @Test func returnsNilForMalformedToken() {
        #expect(JWTClaims.chatGPTAccountID(idToken: "not-a-jwt", accessToken: nil) == nil)
    }

    @Test func returnsNilWhenNoAccountClaimPresent() {
        #expect(JWTClaims.chatGPTAccountID(idToken: jwt(#"{"sub":"user-1"}"#), accessToken: nil) == nil)
    }

    @Test func extractsTopLevelPlanType() {
        let payload = #"{"chatgpt_plan_type":"plus","sub":"user-1"}"#
        #expect(JWTClaims.chatGPTPlanType(idToken: jwt(payload), accessToken: nil) == "plus")
    }

    @Test func planTypeFallsBackToNestedAuthClaim() {
        let payload = #"{"https://api.openai.com/auth":{"chatgpt_plan_type":"pro"}}"#
        #expect(JWTClaims.chatGPTPlanType(idToken: jwt(payload), accessToken: nil) == "pro")
    }

    @Test func planTypeReturnsNilWhenAbsent() {
        #expect(JWTClaims.chatGPTPlanType(idToken: jwt(#"{"sub":"user-1"}"#), accessToken: nil) == nil)
    }

    private func jwt(_ payload: String) -> String {
        "eyJhbGciOiJub25lIn0." + base64URL(payload) + ".signature"
    }

    private func base64URL(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Fakes

final class InMemoryConnectedAccountStore: ConnectedAccountStoring, @unchecked Sendable {
    private var storage: [AgentSourceID: ConnectedAccount] = [:]

    func load(_ provider: AgentSourceID) -> ConnectedAccount? {
        storage[provider]
    }

    func loadAllAccounts() -> [AgentSourceID: ConnectedAccount] {
        storage
    }

    func save(_ account: ConnectedAccount, for provider: AgentSourceID) {
        storage[provider] = account
    }

    func clear(_ provider: AgentSourceID) {
        storage[provider] = nil
    }
}

// MARK: - Claude CLI credential parsing

@Suite struct ClaudeCLICredentialReaderTests {
    @Test func parsesClaudeAiOauthPayload() {
        let json = #"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"ref","expiresAt":1800000000000,"subscriptionType":"max"}}"#
        let cred = KeychainClaudeCLICredentialReader.parse(Data(json.utf8))
        #expect(cred?.accessToken == "tok")
        #expect(cred?.refreshToken == "ref")
        #expect(cred?.subscriptionType == "max")
        #expect(cred?.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func returnsNilForEmptyAccessToken() {
        let json = #"{"claudeAiOauth":{"accessToken":"","refreshToken":"ref","expiresAt":0}}"#
        #expect(KeychainClaudeCLICredentialReader.parse(Data(json.utf8)) == nil)
    }

    @Test func treatsZeroExpiryAsUnset() {
        let json = #"{"claudeAiOauth":{"accessToken":"tok","expiresAt":0}}"#
        let cred = KeychainClaudeCLICredentialReader.parse(Data(json.utf8))
        #expect(cred?.accessToken == "tok")
        #expect(cred?.expiresAt == nil)
        #expect(cred?.refreshToken == nil)
    }

    @Test func returnsNilForUnrelatedJSON() {
        #expect(KeychainClaudeCLICredentialReader.parse(Data(#"{"foo":1}"#.utf8)) == nil)
    }
}
