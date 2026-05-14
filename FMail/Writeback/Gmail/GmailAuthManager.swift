import Foundation

/// Owns the OAuth credential lifecycle for a single Gmail account:
///   - First-time authorize: drive the loopback flow + persist credentials.
///   - Per-request access: hand back a valid (refreshed if needed) access
///     token.
///   - Revoke: drop the Keychain entry.
///
/// Keyed by the account's email address. The Keychain label is derived
/// deterministically from the email so we can look credentials up later
/// without storing the label anywhere.
actor GmailAuthManager {
    static let shared = GmailAuthManager()

    private let exchange: OAuthTokenExchange
    /// Cache of decoded credentials so we don't re-decrypt on every
    /// access. Keyed by Keychain label. Invalidated on refresh + revoke.
    private var cache: [String: StoredCredentials] = [:]

    init(exchange: OAuthTokenExchange = OAuthTokenExchange()) {
        self.exchange = exchange
    }

    /// Drive the full OAuth flow for an email. Opens the user's browser,
    /// waits for them to consent, exchanges the code, persists the tokens.
    /// Returns the Keychain label that callers store in
    /// `account_writeback.keychain_label`.
    @discardableResult
    func authorize(email: String) async throws -> String {
        guard GmailOAuthConfig.isConfigured else {
            throw OAuthFlowError.notConfigured
        }
        let (code, verifier, redirectURI) = try await OAuthLoopbackListener.run(
            clientID: GmailOAuthConfig.clientID,
            scopes: GmailOAuthConfig.scopes
        )
        let creds = try await exchange.exchangeCode(
            clientID: GmailOAuthConfig.clientID,
            code: code, verifier: verifier, redirectURI: redirectURI
        )
        let label = Self.keychainLabel(for: email)
        try persist(label: label, creds: creds)
        return label
    }

    /// Get a current access token, refreshing if it's within 60s of
    /// expiring. The refreshed credentials are persisted back to Keychain
    /// immediately so a crash mid-session doesn't lose the new expiry.
    func currentAccessToken(label: String) async throws -> String {
        var creds = try loadCredentials(label: label)
        if creds.isExpiring() {
            try await exchange.refresh(clientID: GmailOAuthConfig.clientID, credentials: &creds)
            try persist(label: label, creds: creds)
        }
        return creds.accessToken
    }

    /// Drop the Keychain entry. Doesn't revoke server-side — for that the
    /// user goes to https://myaccount.google.com/permissions. Used when
    /// the user clicks "Revoke" in Settings.
    func revoke(label: String) throws {
        cache[label] = nil
        try Keychain.delete(label: label)
    }

    /// True when this email has stored credentials. Settings UI uses this
    /// to decide between "Authorize" and "Re-authorize / Revoke".
    func isAuthorized(email: String) -> Bool {
        let label = Self.keychainLabel(for: email)
        if cache[label] != nil { return true }
        return (try? Keychain.read(label: label)) != nil
    }

    static func keychainLabel(for email: String) -> String {
        "com.felixmatschke.FMail.gmail.\(email.lowercased())"
    }

    // MARK: — Internals

    private func loadCredentials(label: String) throws -> StoredCredentials {
        if let cached = cache[label] { return cached }
        guard let data = try Keychain.read(label: label) else {
            throw OAuthFlowError.tokenExchangeFailed("no credentials stored for \(label) — re-authorize")
        }
        let decoded = try JSONDecoder().decode(StoredCredentials.self, from: data)
        cache[label] = decoded
        return decoded
    }

    private func persist(label: String, creds: StoredCredentials) throws {
        let data = try JSONEncoder().encode(creds)
        try Keychain.write(label: label, data: data)
        cache[label] = creds
    }
}
