import Foundation
import CryptoKit

/// RFC 7636 PKCE (Proof Key for Code Exchange) helpers: a random
/// `code_verifier` plus its S256 `code_challenge`, both base64url-encoded
/// without padding as the spec requires.
public enum OAuthPKCE {
    /// Generates a fresh `(verifier, challenge)` pair. The verifier is 96
    /// random bytes, base64url-encoded (128 chars) — within the RFC's
    /// 43-128 char allowed range.
    public static func generate() -> (verifier: String, challenge: String) {
        let verifier = generateVerifier()
        let challenge = challenge(forVerifier: verifier)
        return (verifier, challenge)
    }

    /// Generates a random `code_verifier`: 96 random bytes, base64url-encoded
    /// without padding (yields 128 characters, within the RFC's 43-128 range).
    public static func generateVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 96)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return base64URLEncode(Data(bytes))
    }

    /// Computes `code_challenge = base64url(SHA256(verifier))` per RFC 7636 S256.
    public static func challenge(forVerifier verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
