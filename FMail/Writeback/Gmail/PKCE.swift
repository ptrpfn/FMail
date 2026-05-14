import Foundation
import CryptoKit

/// Proof Key for Code Exchange — RFC 7636 / RFC 8252. Generated per-flow:
/// the client picks a random `verifier` and sends its SHA-256 base64url
/// hash as the `challenge` in the auth URL. The token-exchange step sends
/// the verifier; the auth server checks the hash matches.
///
/// Effect: an attacker who intercepts the auth code (e.g. via a malicious
/// app on the same machine listening on a different loopback port)
/// can't redeem it without the verifier — which lives only in our process.
struct PKCE: Sendable, Hashable {
    let verifier: String
    let challenge: String
    /// "S256" — SHA-256. We don't support the legacy "plain" method.
    let method: String

    init(verifier: String, challenge: String, method: String = "S256") {
        self.verifier = verifier
        self.challenge = challenge
        self.method = method
    }

    /// Generate a fresh PKCE pair. Verifier length is 64 chars (well
    /// within RFC's 43-128 range, plenty of entropy).
    static func generate() -> PKCE {
        let v = makeVerifier(length: 64)
        let c = makeChallenge(verifier: v)
        return PKCE(verifier: v, challenge: c)
    }

    /// Internal — exposed for tests so they can pin a known verifier and
    /// verify the challenge derivation matches RFC 7636.
    static func makeVerifier(length: Int) -> String {
        precondition((43...128).contains(length), "PKCE verifier must be 43-128 chars per RFC 7636")
        // Allowed unreserved chars: A-Z, a-z, 0-9, -, ., _, ~
        let allowed = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var out = ""
        out.reserveCapacity(length)
        for _ in 0..<length {
            out.append(allowed.randomElement()!)
        }
        return out
    }

    /// SHA256(verifier) base64url-encoded without padding. Matches the
    /// `S256` PKCE code-challenge method.
    static func makeChallenge(verifier: String) -> String {
        let bytes = Data(verifier.utf8)
        let digest = SHA256.hash(data: bytes)
        let raw = Data(digest)
        return Base64URL.encode(raw)
    }
}

/// base64url encoder/decoder — RFC 4648 §5. Standard base64 with
/// `-`/`_` instead of `+`/`/` and no `=` padding. PKCE + JWT both
/// require this form (NOT plain base64).
enum Base64URL {
    static func encode(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        // Strip trailing `=` padding.
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }

    static func decode(_ s: String) -> Data? {
        var t = s
        t = t.replacingOccurrences(of: "-", with: "+")
        t = t.replacingOccurrences(of: "_", with: "/")
        // Re-add padding to multiple of 4.
        let needed = (4 - t.count % 4) % 4
        t.append(String(repeating: "=", count: needed))
        return Data(base64Encoded: t)
    }
}
