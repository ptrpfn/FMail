import Foundation

/// Code↔token exchange against Google's `oauth2.googleapis.com/token`
/// endpoint. Two operations:
///   - `exchangeCode` — initial trade: auth_code + PKCE verifier → refresh
///     + access tokens (full `StoredCredentials`).
///   - `refresh` — refresh_token → new access token + expiry, mutates the
///     existing `StoredCredentials` in place.
///
/// Pure HTTP — no Keychain reads/writes here. The caller (typically
/// `GmailAuthManager`) persists.
struct OAuthTokenExchange: Sendable {
    let session: URLSessionProtocol
    let tokenEndpoint: URL

    init(
        session: URLSessionProtocol = URLSession.shared,
        tokenEndpoint: URL = GmailOAuthConfig.tokenEndpoint
    ) {
        self.session = session
        self.tokenEndpoint = tokenEndpoint
    }

    /// Initial exchange after the loopback listener catches the code.
    /// Returns nil from `StoredCredentials.from(initial:)` when Google
    /// doesn't include a refresh token — which happens if the user has
    /// already authorized this client and we didn't pass `prompt=consent`.
    /// We do pass that, so this is rare; surfaced as
    /// `OAuthFlowError.noRefreshTokenReturned`.
    func exchangeCode(
        clientID: String,
        code: String,
        verifier: String,
        redirectURI: String
    ) async throws -> StoredCredentials {
        let body = formURLEncode([
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ])
        let response = try await postForm(body: body)
        guard let creds = StoredCredentials.from(initial: response) else {
            throw OAuthFlowError.noRefreshTokenReturned
        }
        return creds
    }

    /// Refresh-token flow. Mutates the passed-in credentials in place so
    /// the caller can persist back to Keychain in one step.
    func refresh(clientID: String, credentials: inout StoredCredentials) async throws {
        let body = formURLEncode([
            "client_id": clientID,
            "refresh_token": credentials.refreshToken,
            "grant_type": "refresh_token"
        ])
        let response = try await postForm(body: body)
        credentials.apply(refresh: response)
    }

    // MARK: — Internals

    private func postForm(body: String) async throws -> TokenResponse {
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthFlowError.tokenExchangeFailed("non-HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            let snippet = String(data: data, encoding: .utf8) ?? "(no body)"
            throw OAuthFlowError.tokenExchangeFailed("HTTP \(http.statusCode): \(snippet)")
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw OAuthFlowError.tokenExchangeFailed("malformed token JSON: \(error)")
        }
    }

    /// Form-urlencode a small dict. We don't use URLComponents.queryItems
    /// here because that's for URL queries, not request bodies — Google
    /// expects `application/x-www-form-urlencoded` content-type for token
    /// requests, and percent-encoding rules are subtly different.
    private func formURLEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")  // also reserve form delimiters
        return params
            .sorted { $0.key < $1.key }
            .map { k, v in
                let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
                let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
                return "\(ek)=\(ev)"
            }
            .joined(separator: "&")
    }
}

/// Indirection point for testing — tests inject a mock URLSession that
/// returns canned bytes. Production wires `URLSession.shared`.
protocol URLSessionProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}
