import Foundation

/// State for the MCP OAuth flow:
///
///   1. Pending **authorization codes** — short-lived (10 min), one-time use.
///      Holds the PKCE challenge + redirect_uri + client_id that were
///      supplied at `/authorize` so `/token` can verify the round-trip.
///   2. Issued **session tokens** — long-lived bearer tokens we hand to
///      clients via `/token`. Persisted to `UserDefaults` so a Cowork
///      connector keeps working across FMail restarts. Validated alongside
///      the static `MCPSettings.authToken` on every `POST /mcp`.
///   3. The **approval window** — a short, opt-in time period during
///      which `/authorize` will render the Approve/Deny page. Outside
///      the window, the page tells the user to open it in Settings. This
///      gates against drive-by approvals via the public URL.
///
/// All state lives on the main actor; `MCPServer` handlers hop in to read/
/// write. Pending codes are scrubbed lazily on access; explicit GC isn't
/// needed at our scale (one user, a handful of OAuth grants ever).
@MainActor
final class OAuthStore {
    static let shared = OAuthStore()

    // MARK: — Pending authorization codes

    struct PendingCode {
        let challenge: String
        let challengeMethod: String
        let redirectURI: String
        let clientID: String
        let createdAt: Date
        var isExpired: Bool { Date().timeIntervalSince(createdAt) > OAuthStore.codeTTL }
    }

    nonisolated static let codeTTL: TimeInterval = 600  // 10 minutes per RFC 6749 §4.1.2

    /// Issued session lifetime — after this many seconds since
    /// `issuedAt`, `tokenIsValid` returns false and the client is
    /// expected to re-authenticate. Mirrors the `expires_in` value
    /// returned to clients at `/token`.
    nonisolated static let sessionTTL: TimeInterval = 30 * 24 * 60 * 60  // 30 days

    private var pendingCodes: [String: PendingCode] = [:]

    /// Generate a fresh authorization code and store the round-trip
    /// context (challenge + redirect_uri + client_id) so the token
    /// endpoint can verify the exchange.
    func issueAuthorizationCode(
        challenge: String,
        challengeMethod: String,
        redirectURI: String,
        clientID: String
    ) -> String {
        gcExpiredPendingCodes()
        let code = randomToken(byteCount: 32)
        pendingCodes[code] = PendingCode(
            challenge: challenge,
            challengeMethod: challengeMethod,
            redirectURI: redirectURI,
            clientID: clientID,
            createdAt: Date()
        )
        return code
    }

    /// Drop codes that have aged out so an attacker poking `/authorize/approve`
    /// can't grow `pendingCodes` without bound. Called opportunistically on
    /// every issue/exchange — at our scale (low single-digit OAuth grants
    /// ever) explicit periodic sweep isn't worth the complexity.
    private func gcExpiredPendingCodes() {
        let cutoff = Date().addingTimeInterval(-Self.codeTTL)
        pendingCodes = pendingCodes.filter { $0.value.createdAt > cutoff }
    }

    /// Consume an authorization code (one-time use). Verifies PKCE +
    /// redirect_uri + client_id match what was stored at `/authorize`.
    /// On success returns a fresh session token; on failure returns the
    /// reason as a string suitable for OAuth `error_description`.
    func exchangeCode(
        _ code: String,
        verifier: String,
        redirectURI: String,
        clientID: String
    ) -> Result<String, OAuthExchangeError> {
        gcExpiredPendingCodes()
        guard let pending = pendingCodes[code] else {
            return .failure(.invalidGrant("unknown or already-used authorization code"))
        }
        // Remove eagerly — even on PKCE failure, the code is now spent.
        pendingCodes.removeValue(forKey: code)

        if pending.isExpired {
            return .failure(.invalidGrant("authorization code expired"))
        }
        guard pending.redirectURI == redirectURI else {
            return .failure(.invalidGrant("redirect_uri mismatch"))
        }
        guard pending.clientID == clientID else {
            return .failure(.invalidClient("client_id mismatch"))
        }
        guard OAuthPKCE.verify(
            verifier: verifier,
            challenge: pending.challenge,
            method: pending.challengeMethod
        ) else {
            return .failure(.invalidGrant("PKCE verifier mismatch"))
        }

        let sessionToken = randomToken(byteCount: 32)
        sessions[sessionToken] = Session(
            clientID: clientID,
            issuedAt: Date(),
            label: "OAuth connector"
        )
        persistSessions()
        return .success(sessionToken)
    }

    // MARK: — Issued session tokens (long-lived, persisted)

    struct Session: Codable, Equatable {
        let clientID: String
        let issuedAt: Date
        let label: String  // human-readable for the Settings UI
    }

    private(set) var sessions: [String: Session] = [:]

    /// True iff the token is in `sessions` AND was issued within the
    /// last `sessionTTL`. Expired sessions are dropped lazily on this
    /// call — no periodic sweep needed at our scale.
    func tokenIsValid(_ token: String) -> Bool {
        guard let session = sessions[token] else { return false }
        if Date().timeIntervalSince(session.issuedAt) > Self.sessionTTL {
            sessions.removeValue(forKey: token)
            persistSessions()
            return false
        }
        return true
    }

    func revokeAllSessions() {
        sessions.removeAll()
        persistSessions()
    }

    func revokeSession(token: String) {
        sessions.removeValue(forKey: token)
        persistSessions()
    }

    // MARK: — Dynamic client registration

    /// Issue a stable `client_id` for a newly-registered MCP client. We
    /// don't differentiate clients — the single-user model means every
    /// grant flows through one approval anyway. The client secret is
    /// empty (we're a "public client" using PKCE). The supplied `name`
    /// is currently ignored; it's accepted because RFC 7591 callers
    /// supply it and we may want to surface it in the Settings UI.
    func registerClient(name: String?) -> (clientID: String, clientSecret: String) {
        _ = name
        let id = randomToken(byteCount: 24)
        return (id, "")
    }

    // MARK: — Approval window

    private var approvalWindowExpiresAt: Date?

    /// Caller-visible state used by Settings UI to render the status row.
    enum ApprovalWindowState: Equatable {
        case closed
        case open(secondsRemaining: Int)
    }

    var approvalWindowState: ApprovalWindowState {
        guard let until = approvalWindowExpiresAt, until > Date() else {
            return .closed
        }
        return .open(secondsRemaining: Int(until.timeIntervalSinceNow))
    }

    /// Open the approval window for `duration` seconds. Subsequent calls
    /// extend the window. Settings UI calls this when the user clicks
    /// "Open approval window".
    func openApprovalWindow(duration: TimeInterval = 300) {
        approvalWindowExpiresAt = Date().addingTimeInterval(duration)
    }

    /// Close the window — called after a successful approval, or by the
    /// user via Settings.
    func closeApprovalWindow() {
        approvalWindowExpiresAt = nil
    }

    /// True iff the window is open right now. The approval endpoint
    /// calls this *before* issuing a code; we close the window
    /// immediately after, so each window grants exactly one code.
    var approvalWindowIsOpen: Bool {
        if case .open = approvalWindowState { return true }
        return false
    }

    // MARK: — Init / persistence

    init() {
        loadSessions()
    }

    private static let sessionsKey = "mcp.oauth.sessions.v1"

    private func loadSessions() {
        guard let data = UserDefaults.standard.data(forKey: Self.sessionsKey),
              let decoded = try? JSONDecoder().decode([String: Session].self, from: data)
        else { return }
        sessions = decoded
    }

    private func persistSessions() {
        if let data = try? JSONEncoder().encode(sessions) {
            UserDefaults.standard.set(data, forKey: Self.sessionsKey)
        }
    }

    // MARK: — Helpers

    /// 32-byte random buffer → base64url-encoded (~43 chars), no padding.
    private func randomToken(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let rc = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if rc != errSecSuccess {
            for i in 0..<byteCount { bytes[i] = UInt8.random(in: 0...255) }
        }
        return OAuthPKCE.base64URLEncode(Data(bytes))
    }
}

/// OAuth 2.0 errors per RFC 6749 §5.2. We only surface the ones the
/// token endpoint can produce.
enum OAuthExchangeError: Error {
    case invalidGrant(String)
    case invalidClient(String)
    case invalidRequest(String)

    var code: String {
        switch self {
        case .invalidGrant: return "invalid_grant"
        case .invalidClient: return "invalid_client"
        case .invalidRequest: return "invalid_request"
        }
    }

    var description: String {
        switch self {
        case .invalidGrant(let m), .invalidClient(let m), .invalidRequest(let m): return m
        }
    }
}
