import XCTest
@testable import FMail

/// Phase B1 unit tests. No live OAuth flow / Gmail API calls — those run
/// against Google's servers and would need credentials. These pin the
/// pure components: PKCE math, OAuth URL construction, callback parsing,
/// token-refresh request body, Base64URL encoding.
final class GmailOAuthTests: XCTestCase {

    // MARK: — PKCE

    /// RFC 7636 Appendix B test vector. Pins our SHA-256 + base64url
    /// implementation against the spec's example.
    func testPKCEChallengeMatchesRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = PKCE.makeChallenge(verifier: verifier)
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testPKCEGenerateReturnsConformantVerifier() {
        let pkce = PKCE.generate()
        XCTAssertEqual(pkce.method, "S256")
        XCTAssertGreaterThanOrEqual(pkce.verifier.count, 43)
        XCTAssertLessThanOrEqual(pkce.verifier.count, 128)
        // Verifier must only contain the unreserved set [A-Z a-z 0-9 - . _ ~]
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(pkce.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    func testPKCEChallengeIsConsistentWithVerifier() {
        let pkce = PKCE.generate()
        XCTAssertEqual(pkce.challenge, PKCE.makeChallenge(verifier: pkce.verifier))
    }

    // MARK: — Base64URL

    func testBase64URLRoundTrips() {
        let data = Data([0xFB, 0xEF, 0xFC])  // bytes that produce + and / in standard base64
        let encoded = Base64URL.encode(data)
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        let decoded = Base64URL.decode(encoded)
        XCTAssertEqual(decoded, data)
    }

    // MARK: — Authorization URL

    func testAuthorizationURLContainsAllRequiredParameters() {
        let req = AuthorizationRequest(
            clientID: "test-client.apps.googleusercontent.com",
            redirectURI: "http://127.0.0.1:5000/oauth-callback",
            scopes: ["https://www.googleapis.com/auth/gmail.modify"],
            state: "state-12345",
            pkceChallenge: "challenge-abc",
            pkceMethod: "S256"
        )
        let url = req.authorizationURL()
        let s = url.absoluteString
        // Endpoint
        XCTAssertTrue(s.hasPrefix("https://accounts.google.com/o/oauth2/v2/auth"), "endpoint: \(s)")
        // Required OAuth params
        XCTAssertTrue(s.contains("client_id=test-client.apps.googleusercontent.com"))
        XCTAssertTrue(s.contains("redirect_uri=http://127.0.0.1:5000/oauth-callback"))
        XCTAssertTrue(s.contains("response_type=code"))
        XCTAssertTrue(s.contains("scope=https://www.googleapis.com/auth/gmail.modify"))
        XCTAssertTrue(s.contains("state=state-12345"))
        // PKCE
        XCTAssertTrue(s.contains("code_challenge=challenge-abc"))
        XCTAssertTrue(s.contains("code_challenge_method=S256"))
        // Refresh token request
        XCTAssertTrue(s.contains("access_type=offline"))
        XCTAssertTrue(s.contains("prompt=consent"))
    }

    // MARK: — Callback parser

    func testCallbackParserExtractsCode() throws {
        let url = URL(string: "http://127.0.0.1:5000/oauth-callback?code=auth-code-123&state=expected-state")!
        let code = try OAuthCallbackParser.parse(url, expectedState: "expected-state")
        XCTAssertEqual(code, "auth-code-123")
    }

    func testCallbackParserRejectsStateMismatch() {
        let url = URL(string: "http://127.0.0.1:5000/oauth-callback?code=x&state=BADSTATE")!
        do {
            _ = try OAuthCallbackParser.parse(url, expectedState: "expected-state")
            XCTFail("expected state-mismatch error")
        } catch OAuthFlowError.stateMismatch {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testCallbackParserSurfacesUserDenied() {
        let url = URL(string: "http://127.0.0.1:5000/oauth-callback?error=access_denied&state=expected-state")!
        do {
            _ = try OAuthCallbackParser.parse(url, expectedState: "expected-state")
            XCTFail("expected userDenied error")
        } catch OAuthFlowError.userDenied(let reason) {
            XCTAssertEqual(reason, "access_denied")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testCallbackParserMissingCodeError() {
        let url = URL(string: "http://127.0.0.1:5000/oauth-callback?state=expected-state")!
        do {
            _ = try OAuthCallbackParser.parse(url, expectedState: "expected-state")
            XCTFail("expected missingCode")
        } catch OAuthFlowError.missingCodeInCallback {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: — Token exchange with mocked URLSession

    func testExchangeCodePostsToTokenEndpointWithExpectedBody() async throws {
        let recordingSession = RecordingURLSession()
        recordingSession.cannedResponse = Data("""
        {
          "access_token": "access-xyz",
          "refresh_token": "refresh-abc",
          "expires_in": 3600,
          "token_type": "Bearer"
        }
        """.utf8)
        recordingSession.cannedStatus = 200

        let exchange = OAuthTokenExchange(session: recordingSession)
        let creds = try await exchange.exchangeCode(
            clientID: "test-client",
            code: "the-code",
            verifier: "the-verifier",
            redirectURI: "http://127.0.0.1:5000/oauth-callback"
        )
        XCTAssertEqual(creds.accessToken, "access-xyz")
        XCTAssertEqual(creds.refreshToken, "refresh-abc")
        XCTAssertGreaterThan(creds.expiresAt.timeIntervalSinceNow, 3500)
        XCTAssertLessThan(creds.expiresAt.timeIntervalSinceNow, 3700)

        // Verify the request body.
        let req = try XCTUnwrap(recordingSession.lastRequest)
        XCTAssertEqual(req.url, GmailOAuthConfig.tokenEndpoint)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let bodyStr = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(bodyStr.contains("client_id=test-client"))
        XCTAssertTrue(bodyStr.contains("code=the-code"))
        XCTAssertTrue(bodyStr.contains("code_verifier=the-verifier"))
        XCTAssertTrue(bodyStr.contains("grant_type=authorization_code"))
        // redirect_uri is percent-encoded
        XCTAssertTrue(bodyStr.contains("redirect_uri=http"))
    }

    func testRefreshPostsCorrectBodyAndUpdatesCredentials() async throws {
        let recordingSession = RecordingURLSession()
        recordingSession.cannedResponse = Data("""
        {
          "access_token": "new-access",
          "expires_in": 3600,
          "token_type": "Bearer"
        }
        """.utf8)
        recordingSession.cannedStatus = 200

        var creds = StoredCredentials(
            refreshToken: "refresh-token-value",
            accessToken: "old-access",
            expiresAt: Date().addingTimeInterval(-1)  // already expired
        )
        let exchange = OAuthTokenExchange(session: recordingSession)
        try await exchange.refresh(clientID: "test-client", credentials: &creds)
        XCTAssertEqual(creds.accessToken, "new-access")
        XCTAssertEqual(creds.refreshToken, "refresh-token-value")  // unchanged
        XCTAssertGreaterThan(creds.expiresAt.timeIntervalSinceNow, 3500)

        let req = try XCTUnwrap(recordingSession.lastRequest)
        let bodyStr = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(bodyStr.contains("client_id=test-client"))
        XCTAssertTrue(bodyStr.contains("grant_type=refresh_token"))
        XCTAssertTrue(bodyStr.contains("refresh_token=refresh-token-value"))
    }

    func testTokenExchangeSurfacesHTTPErrors() async {
        let session = RecordingURLSession()
        session.cannedResponse = Data(#"{"error":"invalid_grant"}"#.utf8)
        session.cannedStatus = 400

        let exchange = OAuthTokenExchange(session: session)
        do {
            _ = try await exchange.exchangeCode(
                clientID: "test", code: "bad", verifier: "x", redirectURI: "http://127.0.0.1:5000/cb"
            )
            XCTFail("expected tokenExchangeFailed")
        } catch OAuthFlowError.tokenExchangeFailed {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: — StoredCredentials.isExpiring

    func testCredentialsExpiringWindow() {
        var creds = StoredCredentials(
            refreshToken: "r", accessToken: "a",
            expiresAt: Date().addingTimeInterval(120)
        )
        XCTAssertFalse(creds.isExpiring(within: 60))
        creds = StoredCredentials(
            refreshToken: "r", accessToken: "a",
            expiresAt: Date().addingTimeInterval(30)
        )
        XCTAssertTrue(creds.isExpiring(within: 60))
        creds = StoredCredentials(
            refreshToken: "r", accessToken: "a",
            expiresAt: Date().addingTimeInterval(-5)
        )
        XCTAssertTrue(creds.isExpiring(within: 60))
    }

    // MARK: — Keychain label derivation

    func testKeychainLabelIsCaseInsensitive() {
        let a = GmailAuthManager.keychainLabel(for: "Felix@Gmail.com")
        let b = GmailAuthManager.keychainLabel(for: "felix@gmail.com")
        XCTAssertEqual(a, b, "we should look up by lowercased email so case typos don't fragment keys")
    }
}

// MARK: — Recording URLSession mock

/// Records the last request and returns canned bytes. Used to test the
/// token exchange without hitting Google.
final class RecordingURLSession: URLSessionProtocol, @unchecked Sendable {
    nonisolated(unsafe) var lastRequest: URLRequest?
    nonisolated(unsafe) var cannedResponse: Data = Data()
    nonisolated(unsafe) var cannedStatus: Int = 200

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: cannedStatus,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (cannedResponse, response)
    }
}
