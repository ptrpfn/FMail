import Foundation
import CryptoKit

/// PKCE (RFC 7636) verification — verifies that a `code_verifier` submitted
/// at the token endpoint matches the `code_challenge` recorded at the
/// authorization endpoint. We only support `S256` (the spec mandates it
/// for new servers; `plain` is forbidden by MCP spec).
///
/// Math: challenge == base64url(SHA256(verifier)), no padding.
enum OAuthPKCE {
    /// Verifier must be 43–128 chars per RFC 7636 §4.1.
    static let minVerifierLength = 43
    static let maxVerifierLength = 128

    /// Returns true iff `verifier` is a valid PKCE code_verifier whose
    /// S256-derived challenge equals `challenge`.
    static func verify(verifier: String, challenge: String, method: String) -> Bool {
        guard method.uppercased() == "S256" else { return false }
        guard verifier.count >= minVerifierLength, verifier.count <= maxVerifierLength else {
            return false
        }
        let data = Data(verifier.utf8)
        let digest = SHA256.hash(data: data)
        let computed = base64URLEncode(Data(digest))
        return MCPHelpers.constantTimeEqual(computed, challenge)
    }

    /// `+` → `-`, `/` → `_`, drop `=` padding. Standard PKCE encoding.
    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Cryptographically-random base64url token (`byteCount` raw bytes).
    /// Shared by `OAuthStore` (codes + sessions + client ids) and
    /// `MCPSettings.generateAuthToken`.
    static func randomToken(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let rc = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if rc != errSecSuccess {
            // SecRandom failure is exceptional; fall back to arc4random.
            for i in 0..<byteCount { bytes[i] = UInt8.random(in: 0...255) }
        }
        return base64URLEncode(Data(bytes))
    }
}
