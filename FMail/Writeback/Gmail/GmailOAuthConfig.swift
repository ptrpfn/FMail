import Foundation

/// Per-fork Google OAuth configuration. Each fork registers its own
/// Desktop OAuth client at console.cloud.google.com (free, ~5 min one-
/// time setup — see README.md "Gmail OAuth setup") and pastes the client
/// ID below.
///
/// Empty client ID = Gmail authorization is disabled in Settings.
/// AppleScript writeback still works for every account.
///
/// Why is committing the client ID OK for a public repo?
///   1. It's sent in every browser address bar during the auth flow
///      anyway — same security posture as a User-Agent string.
///   2. PKCE (RFC 8252) is what actually protects against auth-code
///      interception. The OAuth flow uses it; the client secret is
///      not required to be in this binary.
///   3. Per-fork client IDs make abuse attribution clean — if someone
///      misuses your client ID's quota, that's tied to your Google
///      Cloud project, not the upstream's.
enum GmailOAuthConfig {
    /// REPLACE with your Google Cloud OAuth 2.0 client ID. Looks like
    /// `<long-number>-<random>.apps.googleusercontent.com`.
    static let clientID: String = ""

    /// Google's authorization endpoint.
    static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!

    /// Google's token-exchange endpoint.
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// Scopes we request. `gmail.modify` covers label changes + trash +
    /// read; does NOT include send (we delegate compose to Mail.app).
    static let scopes: [String] = [
        "https://www.googleapis.com/auth/gmail.modify"
    ]

    /// True when we have a non-empty client ID. The Settings UI uses this
    /// to decide whether to show the "Authorize…" button.
    static var isConfigured: Bool {
        !clientID.isEmpty
    }
}
