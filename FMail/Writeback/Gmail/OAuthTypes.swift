import Foundation

/// Authorization request — what we put in the auth URL we open in the
/// user's browser. Per-OAuth-2.0 + RFC 8252 (Native Apps).
struct AuthorizationRequest: Sendable {
    let clientID: String
    let redirectURI: String           // http://127.0.0.1:<port>/callback
    let scopes: [String]
    let state: String                 // CSRF guard — random, echoed back
    let pkceChallenge: String
    let pkceMethod: String

    /// Build the URL the user's browser is sent to.
    func authorizationURL(endpoint: URL = GmailOAuthConfig.authEndpoint) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkceChallenge),
            URLQueryItem(name: "code_challenge_method", value: pkceMethod),
            URLQueryItem(name: "access_type", value: "offline"),  // request refresh token
            URLQueryItem(name: "prompt", value: "consent")        // always show consent screen
        ]
        return components.url!
    }
}

/// The token endpoint's response body (JSON) when exchanging a code or
/// refreshing. Fields we don't use are omitted.
struct TokenResponse: Sendable, Codable {
    let access_token: String
    let expires_in: Int             // seconds from now
    let refresh_token: String?      // present on initial exchange; nil on refresh
    let scope: String?
    let token_type: String          // "Bearer"
}

/// What we persist to Keychain. JSON-encoded blob. The `expiresAt` is
/// computed from `expires_in` at receive time so we don't depend on
/// re-comparing against the wire-side instant.
struct StoredCredentials: Sendable, Codable {
    let refreshToken: String
    var accessToken: String
    var expiresAt: Date

    /// True when the access token is at most this many seconds from
    /// expiring. Callers (the API client) preemptively refresh in this
    /// window to avoid mid-request expirations.
    func isExpiring(within: TimeInterval = 60) -> Bool {
        Date() >= expiresAt.addingTimeInterval(-within)
    }

    static func from(initial: TokenResponse, at now: Date = Date()) -> StoredCredentials? {
        guard let refresh = initial.refresh_token else { return nil }
        return StoredCredentials(
            refreshToken: refresh,
            accessToken: initial.access_token,
            expiresAt: now.addingTimeInterval(TimeInterval(initial.expires_in))
        )
    }

    /// Apply a refresh response. The refresh token usually stays the
    /// same; we only overwrite the access token + expiry.
    mutating func apply(refresh: TokenResponse, at now: Date = Date()) {
        accessToken = refresh.access_token
        expiresAt = now.addingTimeInterval(TimeInterval(refresh.expires_in))
    }
}

/// Errors specific to OAuth flow setup (independent of HTTP errors that
/// `URLSession` reports).
enum OAuthFlowError: Error, CustomStringConvertible {
    case notConfigured              // GmailOAuthConfig.clientID empty
    case stateMismatch              // CSRF check failed
    case userDenied(String)         // callback `error=access_denied` etc.
    case malformedCallback(String)
    case missingCodeInCallback
    case tokenExchangeFailed(String)
    case noRefreshTokenReturned

    var description: String {
        switch self {
        case .notConfigured:
            return "Gmail OAuth client ID isn't configured (see README: Gmail OAuth setup)"
        case .stateMismatch:
            return "OAuth state mismatch — possible CSRF; flow aborted"
        case .userDenied(let reason):
            return "Authorization denied: \(reason)"
        case .malformedCallback(let m):
            return "Malformed OAuth callback: \(m)"
        case .missingCodeInCallback:
            return "OAuth callback missing `code` parameter"
        case .tokenExchangeFailed(let m):
            return "Token exchange failed: \(m)"
        case .noRefreshTokenReturned:
            return "Google didn't return a refresh token. The user may have already authorized this client — revoke it in Google Account settings and retry."
        }
    }
}

/// Parse an OAuth callback URL's query string into `(code, state)` or an
/// error. Pure function — no networking. Used by the loopback listener
/// when the browser hits our redirect URI.
enum OAuthCallbackParser {
    static func parse(_ url: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw OAuthFlowError.malformedCallback("not a URL: \(url)")
        }
        let items = components.queryItems ?? []
        let dict: [String: String] = Dictionary(uniqueKeysWithValues: items.compactMap {
            guard let v = $0.value else { return nil }
            return ($0.name, v)
        })
        if let err = dict["error"] {
            throw OAuthFlowError.userDenied(err)
        }
        guard let state = dict["state"] else {
            throw OAuthFlowError.malformedCallback("missing state")
        }
        guard state == expectedState else {
            throw OAuthFlowError.stateMismatch
        }
        guard let code = dict["code"], !code.isEmpty else {
            throw OAuthFlowError.missingCodeInCallback
        }
        return code
    }
}
