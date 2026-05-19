import XCTest
import Network
@testable import FMail

/// Coverage for the MCP OAuth 2.1 / RFC 7636 flow that lets remote MCP
/// clients (Cowork's Custom Connector) authenticate to FMail. Tests
/// exercise the full request path through the real `MCPServer` bound on
/// port 0, including:
///
///   - PKCE math (S256, base64url, no padding)
///   - Authorization-window gating
///   - One-time / TTL'd auth codes
///   - PKCE verifier round-trip
///   - Session token validation on subsequent /mcp calls
final class OAuthFlowTests: XCTestCase {

    private var savedToken: String = ""
    private var savedTunnelURL: String = ""

    override func setUp() {
        super.setUp()
        savedToken = MCPSettings.authToken
        savedTunnelURL = MCPSettings.tunnelPublicURL
        MCPSettings.authToken = ""
        MCPSettings.tunnelPublicURL = ""
        // Each test starts with a clean OAuthStore — we can't replace the
        // singleton, but we can wipe its state.
        MainActor.assumeIsolated {
            OAuthStore.shared.revokeAllSessions()
            OAuthStore.shared.closeApprovalWindow()
        }
    }

    override func tearDown() {
        MCPSettings.authToken = savedToken
        MCPSettings.tunnelPublicURL = savedTunnelURL
        MainActor.assumeIsolated {
            OAuthStore.shared.revokeAllSessions()
            OAuthStore.shared.closeApprovalWindow()
        }
        super.tearDown()
    }

    // MARK: — PKCE math

    func testPKCEVerifyAcceptsMatchingS256() {
        // From RFC 7636 Appendix B example:
        //   verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        //   challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        XCTAssertTrue(OAuthPKCE.verify(verifier: verifier, challenge: challenge, method: "S256"))
    }

    func testPKCEVerifyRejectsWrongVerifier() {
        let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        XCTAssertFalse(OAuthPKCE.verify(verifier: "wrong-verifier", challenge: challenge, method: "S256"))
    }

    func testPKCEVerifyRejectsPlainMethod() {
        // MCP spec mandates S256; we don't accept plain even if values match.
        XCTAssertFalse(OAuthPKCE.verify(verifier: "abc", challenge: "abc", method: "plain"))
    }

    func testPKCEVerifyRejectsTooShortVerifier() {
        // < 43 chars violates RFC 7636 §4.1.
        XCTAssertFalse(OAuthPKCE.verify(verifier: "tooshort", challenge: "irrelevant", method: "S256"))
    }

    // MARK: — Authorization window gating

    func testApprovePathRefusedWhenWindowClosed() async throws {
        let server = MCPServer()
        try await server.start(port: 0)
        let port = await server.port
        defer { Task { await server.stop() } }

        // Approval window is closed by default after setUp wipe.
        let form = "client_id=abc&redirect_uri=https%3A%2F%2Fclaude.ai%2Fcb&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256&state=xyz"
        let raw = try await postForm(port: port, path: "/authorize/approve", body: form)
        XCTAssertTrue(responseStatus(raw).hasPrefix("HTTP/1.1 403"))
    }

    func testApprovePathRedirectsWhenWindowOpen() async throws {
        let server = MCPServer()
        try await server.start(port: 0)
        let port = await server.port
        defer { Task { await server.stop() } }

        await MainActor.run { OAuthStore.shared.openApprovalWindow() }

        let form = "client_id=abc&redirect_uri=https%3A%2F%2Fclaude.ai%2Fcb&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256&state=xyz"
        let raw = try await postForm(port: port, path: "/authorize/approve", body: form)
        XCTAssertTrue(responseStatus(raw).hasPrefix("HTTP/1.1 302"))
        // Location header contains the auth code + state, points at the
        // requested redirect_uri.
        let headers = responseHeaderBlock(raw)
        XCTAssertTrue(headers.contains("Location:"))
        XCTAssertTrue(headers.contains("https://claude.ai/cb"))
        XCTAssertTrue(headers.contains("code="))
        XCTAssertTrue(headers.contains("state=xyz"))

        // Window auto-closed after one approval.
        let stillOpen = await MainActor.run { OAuthStore.shared.approvalWindowIsOpen }
        XCTAssertFalse(stillOpen)
    }

    // MARK: — End-to-end /token exchange

    func testTokenExchangeIssuesSessionToken() async throws {
        let server = MCPServer()
        try await server.start(port: 0)
        let port = await server.port
        defer { Task { await server.stop() } }

        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

        // 1. Open window + approve a synthetic request.
        await MainActor.run { OAuthStore.shared.openApprovalWindow() }
        let approveBody = "client_id=test&redirect_uri=https%3A%2F%2Fclaude.ai%2Fcb&code_challenge=\(challenge)&code_challenge_method=S256&state=xyz"
        let approveResp = try await postForm(port: port, path: "/authorize/approve", body: approveBody)
        XCTAssertTrue(responseStatus(approveResp).hasPrefix("HTTP/1.1 302"))
        let code = try XCTUnwrap(extractQueryParam("code", fromLocationIn: approveResp))

        // 2. Exchange the code at /token.
        let tokenBody = "grant_type=authorization_code&code=\(code)&redirect_uri=https%3A%2F%2Fclaude.ai%2Fcb&client_id=test&code_verifier=\(verifier)"
        let tokenResp = try await postForm(port: port, path: "/token", body: tokenBody)
        XCTAssertTrue(responseStatus(tokenResp).hasPrefix("HTTP/1.1 200"))
        let json = try parseJSONBody(tokenResp)
        let accessToken = try XCTUnwrap(json["access_token"] as? String)
        XCTAssertEqual(json["token_type"] as? String, "Bearer")
        XCTAssertFalse(accessToken.isEmpty)

        // 3. The issued token is now valid for /mcp.
        let mcpResp = try await postMCP(port: port, body: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#, token: accessToken)
        XCTAssertTrue(responseStatus(mcpResp).hasPrefix("HTTP/1.1 200"))
    }

    func testTokenExchangeRejectsBadVerifier() async throws {
        let server = MCPServer()
        try await server.start(port: 0)
        let port = await server.port
        defer { Task { await server.stop() } }

        let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

        await MainActor.run { OAuthStore.shared.openApprovalWindow() }
        let approveBody = "client_id=test&redirect_uri=https%3A%2F%2Fclaude.ai%2Fcb&code_challenge=\(challenge)&code_challenge_method=S256&state=xyz"
        let approveResp = try await postForm(port: port, path: "/authorize/approve", body: approveBody)
        let code = try XCTUnwrap(extractQueryParam("code", fromLocationIn: approveResp))

        // Wrong verifier.
        let tokenBody = "grant_type=authorization_code&code=\(code)&redirect_uri=https%3A%2F%2Fclaude.ai%2Fcb&client_id=test&code_verifier=wrong-verifier-but-long-enough-to-pass-the-length-check-XXXX"
        let tokenResp = try await postForm(port: port, path: "/token", body: tokenBody)
        XCTAssertTrue(responseStatus(tokenResp).hasPrefix("HTTP/1.1 400"))
        let json = try parseJSONBody(tokenResp)
        XCTAssertEqual(json["error"] as? String, "invalid_grant")
    }

    func testAuthCodeIsOneTimeUse() async throws {
        let server = MCPServer()
        try await server.start(port: 0)
        let port = await server.port
        defer { Task { await server.stop() } }

        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

        await MainActor.run { OAuthStore.shared.openApprovalWindow() }
        let approveBody = "client_id=test&redirect_uri=https%3A%2F%2Fclaude.ai%2Fcb&code_challenge=\(challenge)&code_challenge_method=S256&state=xyz"
        let approveResp = try await postForm(port: port, path: "/authorize/approve", body: approveBody)
        let code = try XCTUnwrap(extractQueryParam("code", fromLocationIn: approveResp))

        let tokenBody = "grant_type=authorization_code&code=\(code)&redirect_uri=https%3A%2F%2Fclaude.ai%2Fcb&client_id=test&code_verifier=\(verifier)"
        _ = try await postForm(port: port, path: "/token", body: tokenBody)
        // Second exchange of the same code must fail.
        let secondResp = try await postForm(port: port, path: "/token", body: tokenBody)
        XCTAssertTrue(responseStatus(secondResp).hasPrefix("HTTP/1.1 400"))
        let json = try parseJSONBody(secondResp)
        XCTAssertEqual(json["error"] as? String, "invalid_grant")
    }

    // MARK: — Metadata discovery

    func testMetadataEndpointReturnsExpectedShape() async throws {
        let server = MCPServer()
        try await server.start(port: 0)
        let port = await server.port
        defer { Task { await server.stop() } }

        let resp = try await get(port: port, path: "/.well-known/oauth-authorization-server")
        XCTAssertTrue(responseStatus(resp).hasPrefix("HTTP/1.1 200"))
        let json = try parseJSONBody(resp)
        XCTAssertNotNil(json["issuer"])
        XCTAssertNotNil(json["authorization_endpoint"])
        XCTAssertNotNil(json["token_endpoint"])
        let pkceMethods = try XCTUnwrap(json["code_challenge_methods_supported"] as? [String])
        XCTAssertEqual(pkceMethods, ["S256"])
    }

    /// MCP authorization spec requires `/.well-known/oauth-protected-resource`
    /// (RFC 9728) — clients hit this after seeing the
    /// `WWW-Authenticate: ..., resource_metadata=...` hint on a 401.
    /// The response points at the authorization server.
    func testProtectedResourceEndpointReturnsExpectedShape() async throws {
        let server = MCPServer()
        try await server.start(port: 0)
        let port = await server.port
        defer { Task { await server.stop() } }

        let resp = try await get(port: port, path: "/.well-known/oauth-protected-resource")
        XCTAssertTrue(responseStatus(resp).hasPrefix("HTTP/1.1 200"))
        let json = try parseJSONBody(resp)
        let resource = try XCTUnwrap(json["resource"] as? String)
        XCTAssertTrue(resource.hasSuffix("/mcp"), "resource must point at the MCP endpoint, got \(resource)")
        let servers = try XCTUnwrap(json["authorization_servers"] as? [String])
        XCTAssertEqual(servers.count, 1)
        XCTAssertNotNil(URL(string: servers[0]))
    }

    /// Without `resource_metadata` on the 401 header, remote MCP clients
    /// can't discover the OAuth flow at all — they'd just see "Unauthorized"
    /// and give up. Regression guard for the Cowork-connector bug.
    func testUnauthenticatedMCPRequestExposesResourceMetadataHint() async throws {
        // Force auth on so the request actually 401s.
        MCPSettings.authToken = "force-auth-required"
        defer { MCPSettings.authToken = "" }

        let server = MCPServer()
        try await server.start(port: 0)
        let port = await server.port
        defer { Task { await server.stop() } }

        let req = "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
        let raw = try await sendRaw(port: port, payload: Data(req.utf8))
        XCTAssertTrue(responseStatus(raw).hasPrefix("HTTP/1.1 401"))
        let headers = responseHeaderBlock(raw)
        XCTAssertTrue(headers.lowercased().contains("www-authenticate:"))
        XCTAssertTrue(headers.contains("resource_metadata="), "401 header must include resource_metadata pointing at /.well-known/oauth-protected-resource")
        XCTAssertTrue(headers.contains("/.well-known/oauth-protected-resource"))
    }

    // MARK: — Authorize page rendering

    func testAuthorizePageRendersWindowClosedNotice() async throws {
        let server = MCPServer()
        try await server.start(port: 0)
        let port = await server.port
        defer { Task { await server.stop() } }

        let resp = try await get(port: port, path: "/authorize?response_type=code&client_id=test&redirect_uri=https%3A%2F%2Fclaude.ai%2Fcb&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256&state=xyz")
        XCTAssertTrue(responseStatus(resp).hasPrefix("HTTP/1.1 200"))
        let body = bodyString(resp)
        XCTAssertTrue(body.contains("Approval window is closed"))
    }

    func testAuthorizePageRendersApproveButtonsWhenWindowOpen() async throws {
        let server = MCPServer()
        try await server.start(port: 0)
        let port = await server.port
        defer { Task { await server.stop() } }

        await MainActor.run { OAuthStore.shared.openApprovalWindow() }

        let resp = try await get(port: port, path: "/authorize?response_type=code&client_id=test&redirect_uri=https%3A%2F%2Fclaude.ai%2Fcb&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256&state=xyz")
        XCTAssertTrue(responseStatus(resp).hasPrefix("HTTP/1.1 200"))
        let body = bodyString(resp)
        XCTAssertTrue(body.contains("Approve"))
        XCTAssertTrue(body.contains("Deny"))
        XCTAssertTrue(body.contains("/authorize/approve"))
    }

    // MARK: — HTTP helpers

    private func postForm(port: UInt16, path: String, body: String) async throws -> Data {
        let req = """
            POST \(path) HTTP/1.1\r
            Host: localhost\r
            Content-Type: application/x-www-form-urlencoded\r
            Content-Length: \(body.utf8.count)\r
            \r
            \(body)
            """
        return try await sendRaw(port: port, payload: Data(req.utf8))
    }

    private func postMCP(port: UInt16, body: String, token: String) async throws -> Data {
        let req = """
            POST /mcp HTTP/1.1\r
            Host: localhost\r
            Content-Type: application/json\r
            Authorization: Bearer \(token)\r
            Content-Length: \(body.utf8.count)\r
            \r
            \(body)
            """
        return try await sendRaw(port: port, payload: Data(req.utf8))
    }

    private func get(port: UInt16, path: String) async throws -> Data {
        let req = "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n"
        return try await sendRaw(port: port, payload: Data(req.utf8))
    }

    private func responseStatus(_ raw: Data) -> String {
        guard let crlf = raw.range(of: Data([0x0D, 0x0A])) else { return "" }
        return String(data: raw.subdata(in: 0..<crlf.lowerBound), encoding: .ascii) ?? ""
    }

    private func responseHeaderBlock(_ raw: Data) -> String {
        guard let sep = raw.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else { return "" }
        return String(data: raw.subdata(in: 0..<sep.lowerBound), encoding: .ascii) ?? ""
    }

    private func bodyString(_ raw: Data) -> String {
        guard let sep = raw.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else { return "" }
        return String(data: raw.subdata(in: sep.upperBound..<raw.count), encoding: .utf8) ?? ""
    }

    private func parseJSONBody(_ raw: Data) throws -> [String: Any] {
        let body = bodyString(raw)
        let data = Data(body.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj ?? [:]
    }

    private func extractQueryParam(_ name: String, fromLocationIn raw: Data) -> String? {
        let headers = responseHeaderBlock(raw)
        for line in headers.split(separator: "\r\n") {
            if line.lowercased().hasPrefix("location:") {
                let value = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
                guard let url = URL(string: value),
                      let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                else { return nil }
                return comps.queryItems?.first(where: { $0.name == name })?.value
            }
        }
        return nil
    }

    private func sendRaw(port: UInt16, payload: Data) async throws -> Data {
        let conn = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let q = DispatchQueue(label: "oauth.test")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: cont.resume()
                case .failed(let err), .waiting(let err): cont.resume(throwing: err)
                default: break
                }
            }
            conn.start(queue: q)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: payload, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
        var accumulated = Data()
        while true {
            let chunk: Data? = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let error { cont.resume(throwing: error); return }
                    if let data, !data.isEmpty { cont.resume(returning: data); return }
                    if isComplete { cont.resume(returning: nil); return }
                    cont.resume(returning: Data())
                }
            }
            guard let chunk else { break }
            accumulated.append(chunk)
        }
        conn.cancel()
        return accumulated
    }
}
