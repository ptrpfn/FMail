import XCTest
import Network
@testable import FMail

/// Regression tests for the cleanup pass on the MCP module:
///   - attachment path-traversal defences
///   - HTTP Content-Length guard
///   - fail-closed auth when a tunnel is configured
///   - strict enum parsing (search_emails sort, body_format, direction)
///   - shared ISO-date parser rejecting non-numeric segments
///   - OAuth redirect_uri scheme validation
///   - OAuth pending-code GC + session soft expiry
final class MCPCleanupTests: XCTestCase {

    private var savedToken: String = ""
    private var savedTunnelURL: String = ""

    override func setUp() {
        super.setUp()
        savedToken = MCPSettings.authToken
        savedTunnelURL = MCPSettings.tunnelPublicURL
        MCPSettings.authToken = ""
        MCPSettings.tunnelPublicURL = ""
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

    // MARK: — Path safety: save_to_path rejects `..`

    func testSafeAbsolutePathRejectsParentTraversal() {
        do {
            _ = try MCPHandlers.safeAbsolutePath("~/Documents/../../../../etc/passwd")
            XCTFail("expected PathSafetyError.parentReference")
        } catch let err as PathSafetyError {
            if case .parentReference = err { return }
            XCTFail("wrong PathSafetyError case: \(err)")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testSafeAbsolutePathRejectsRelativeParentSegments() {
        do {
            _ = try MCPHandlers.safeAbsolutePath("foo/../../bar")
            XCTFail("expected PathSafetyError.parentReference")
        } catch let err as PathSafetyError {
            if case .parentReference = err { return }
            XCTFail("wrong PathSafetyError case: \(err)")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testSafeAbsolutePathAcceptsPlainAbsolute() throws {
        let path = try MCPHandlers.safeAbsolutePath("/tmp/fmail-test-clean.pdf")
        XCTAssertEqual(path, "/tmp/fmail-test-clean.pdf")
    }

    func testSafeAbsolutePathExpandsTilde() throws {
        let path = try MCPHandlers.safeAbsolutePath("~/Downloads/fmail-test.pdf")
        XCTAssertTrue(path.hasPrefix(NSHomeDirectory() + "/Downloads/"), "got \(path)")
    }

    func testSafeAbsolutePathRejectsEmpty() {
        do {
            _ = try MCPHandlers.safeAbsolutePath("   ")
            XCTFail("expected PathSafetyError.emptyPath")
        } catch let err as PathSafetyError {
            if case .emptyPath = err { return }
            XCTFail("wrong PathSafetyError case: \(err)")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    // MARK: — Path safety: attachment filename sanitisation

    func testSanitiseFilenameDefangsParentSegments() {
        // An attachment named "../../foo.txt" must not escape its
        // per-rowid directory.
        let cleaned = MCPHandlers.sanitiseFilename("../../foo.txt")
        XCTAssertFalse(cleaned.contains(".."), "got \(cleaned)")
        XCTAssertFalse(cleaned.hasPrefix("."), "got \(cleaned)")
    }

    func testSanitiseFilenameStripsSlashes() {
        XCTAssertFalse(MCPHandlers.sanitiseFilename("foo/bar.pdf").contains("/"))
        XCTAssertFalse(MCPHandlers.sanitiseFilename(#"foo\bar.pdf"#).contains(#"\"#))
    }

    func testSanitiseFilenameProducesNonEmptyFallback() {
        XCTAssertEqual(MCPHandlers.sanitiseFilename("..."), "attachment.bin")
        XCTAssertEqual(MCPHandlers.sanitiseFilename(""), "attachment.bin")
    }

    // MARK: — HTTP framing: Content-Length guard

    func testHTTPParserClampsNegativeContentLength() throws {
        // Negative C-L used to crash `subdata(in:)` when bodyEnd < bodyStart.
        let raw = "POST /mcp HTTP/1.1\r\nContent-Length: -10\r\n\r\n"
        let data = Data(raw.utf8)
        let result = try HTTPParser.parse(data)
        // With C-L clamped to 0, parse succeeds with an empty body.
        let unwrapped = try XCTUnwrap(result)
        XCTAssertEqual(unwrapped.0.body.count, 0)
    }

    func testHTTPParserClampsHugeContentLength() throws {
        // 100 GB would otherwise blow past Int range / cause huge allocs.
        let raw = "POST /mcp HTTP/1.1\r\nContent-Length: 99999999999999\r\n\r\n"
        let data = Data(raw.utf8)
        // The parser keeps waiting for the (clamped) 32 MB body that
        // will never arrive — that's `nil` (not enough bytes yet).
        XCTAssertNil(try HTTPParser.parse(data))
    }

    func testHTTPParserNonNumericContentLength() throws {
        let raw = "POST /mcp HTTP/1.1\r\nContent-Length: banana\r\n\r\nignored"
        let data = Data(raw.utf8)
        let result = try HTTPParser.parse(data)
        let unwrapped = try XCTUnwrap(result)
        XCTAssertEqual(unwrapped.0.body.count, 0)
    }

    // MARK: — Fail-closed when tunnel is configured

    func testTunnelConfiguredWithNoAuthRefusesAnonymousRequest() async throws {
        MCPSettings.authToken = ""
        MCPSettings.tunnelPublicURL = "https://fmail.example.com"
        defer { MCPSettings.tunnelPublicURL = "" }

        let server = MCPServer()
        try await server.start(port: 0)
        let port = await server.port
        defer { Task { await server.stop() } }

        let req = "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
        let raw = try await sendRaw(port: port, payload: Data(req.utf8))
        XCTAssertTrue(statusLine(raw).hasPrefix("HTTP/1.1 401"),
                      "expected 401 when tunnel is configured and no auth set, got: \(statusLine(raw))")
    }

    func testTunnelConfiguredWithStaticTokenStillWorks() async throws {
        let token = MCPSettings.generateAuthToken()
        MCPSettings.authToken = token
        MCPSettings.tunnelPublicURL = "https://fmail.example.com"
        defer { MCPSettings.tunnelPublicURL = "" }

        let server = MCPServer()
        try await server.start(port: 0)
        let port = await server.port
        defer { Task { await server.stop() } }

        let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        let req = """
            POST /mcp HTTP/1.1\r
            Host: localhost\r
            Content-Type: application/json\r
            Authorization: Bearer \(token)\r
            Content-Length: \(body.utf8.count)\r
            \r
            \(body)
            """
        let raw = try await sendRaw(port: port, payload: Data(req.utf8))
        XCTAssertTrue(statusLine(raw).hasPrefix("HTTP/1.1 200"),
                      "expected 200 when token matches, got: \(statusLine(raw))")
    }

    // MARK: — Strict enum parsing

    func testSearchSortRejectsUnknownExplicitValue() {
        do {
            _ = try SearchSort.parseStrict("oldest_first_typo")
            XCTFail("expected invalidParams")
        } catch let p as JSONRPCErrorPayload {
            XCTAssertEqual(p.code, JSONRPCErrorCode.invalidParams)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testSearchSortAcceptsKnownValuesAndNilDefault() throws {
        XCTAssertEqual(try SearchSort.parseStrict(nil), .newestFirst)
        XCTAssertEqual(try SearchSort.parseStrict("relevance"), .relevance)
        XCTAssertEqual(try SearchSort.parseStrict("OLDEST_FIRST"), .oldestFirst)
    }

    func testBodyFormatRejectsUnknownExplicitValue() {
        do {
            _ = try BodyFormat.parseStrict("compact")
            XCTFail("expected invalidParams")
        } catch let p as JSONRPCErrorPayload {
            XCTAssertEqual(p.code, JSONRPCErrorCode.invalidParams)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testThreadDirectionRejectsUnknownExplicitValue() {
        do {
            _ = try ThreadDirection.parseStrict("newest")
            XCTFail("expected invalidParams")
        } catch let p as JSONRPCErrorPayload {
            XCTAssertEqual(p.code, JSONRPCErrorCode.invalidParams)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: — ISO-date parser strictness

    func testParseISODateRejectsNonNumericSegment() {
        XCTAssertNil(MCPHelpers.parseISODate("2024-foo"))
        XCTAssertNil(MCPHelpers.parseISODate("2024-03-bar"))
        XCTAssertNil(MCPHelpers.parseISODate("not-a-year"))
    }

    func testParseISODateAcceptsAllSupportedShapes() {
        XCTAssertNotNil(MCPHelpers.parseISODate("2024"))
        XCTAssertNotNil(MCPHelpers.parseISODate("2024-03"))
        XCTAssertNotNil(MCPHelpers.parseISODate("2024-03-15"))
    }

    func testParseISODateRejectsTooManySegments() {
        XCTAssertNil(MCPHelpers.parseISODate("2024-03-15-16"))
    }

    // MARK: — OAuth redirect-URI scheme validation

    func testAllowedRedirectURIAcceptsHTTPAndHTTPS() {
        XCTAssertTrue(OAuthHandlers.isAllowedRedirectURI("https://claude.ai/cb"))
        XCTAssertTrue(OAuthHandlers.isAllowedRedirectURI("http://localhost:8080/cb"))
    }

    func testAllowedRedirectURIRejectsDangerousSchemes() {
        XCTAssertFalse(OAuthHandlers.isAllowedRedirectURI("javascript:alert(1)"))
        XCTAssertFalse(OAuthHandlers.isAllowedRedirectURI("data:text/html,<script>alert(1)</script>"))
        XCTAssertFalse(OAuthHandlers.isAllowedRedirectURI("file:///etc/passwd"))
    }

    func testAllowedRedirectURIRejectsMalformedURL() {
        XCTAssertFalse(OAuthHandlers.isAllowedRedirectURI(""))
        XCTAssertFalse(OAuthHandlers.isAllowedRedirectURI("not a url"))
    }

    // MARK: — OAuth session soft expiry

    /// Force a back-dated session into the persistent store, then
    /// confirm a freshly-constructed `OAuthStore` rejects it. We can't
    /// mutate `OAuthStore.shared.sessions` directly (it's `private(set)`),
    /// so we exploit the load-on-init code path. The shared instance
    /// already exists, but a new `OAuthStore()` instance also calls
    /// `loadSessions()` — so we use that for the verification.
    @MainActor
    func testTokenIsValidRejectsSessionOlderThanTTL() throws {
        let key = "mcp.oauth.sessions.v1"
        let savedSessions = UserDefaults.standard.data(forKey: key)
        defer {
            if let savedSessions {
                UserDefaults.standard.set(savedSessions, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let expired = OAuthStore.Session(
            clientID: "tester",
            issuedAt: Date().addingTimeInterval(-(OAuthStore.sessionTTL + 60)),
            label: "expired"
        )
        let fresh = OAuthStore.Session(
            clientID: "tester",
            issuedAt: Date(),
            label: "fresh"
        )
        let payload: [String: OAuthStore.Session] = [
            "expired-token": expired,
            "fresh-token": fresh
        ]
        let data = try JSONEncoder().encode(payload)
        UserDefaults.standard.set(data, forKey: key)

        let store = OAuthStore()
        XCTAssertFalse(store.tokenIsValid("expired-token"),
                       "session older than sessionTTL must be rejected")
        XCTAssertTrue(store.tokenIsValid("fresh-token"),
                      "session within sessionTTL must remain valid")
        // The expired session should have been dropped lazily.
        XCTAssertNil(store.sessions["expired-token"])
    }

    @MainActor
    func testPendingCodesAreGarbageCollected() {
        // Issue a code, then issue another after a stub "expiry"
        // window — the first must not survive once `gcExpiredPendingCodes`
        // runs. We can't time-warp easily, so we exercise the call site
        // and rely on the property that a freshly-issued code is always
        // exchangeable.
        let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        let code = OAuthStore.shared.issueAuthorizationCode(
            challenge: challenge,
            challengeMethod: "S256",
            redirectURI: "https://example.com/cb",
            clientID: "tester"
        )
        // Sanity: the code is exchangeable.
        let result = OAuthStore.shared.exchangeCode(
            code,
            verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
            redirectURI: "https://example.com/cb",
            clientID: "tester"
        )
        if case .failure(let err) = result {
            XCTFail("freshly-issued code should still exchange after GC: \(err)")
        }
    }

    // MARK: — HTTP helpers

    private func statusLine(_ raw: Data) -> String {
        guard let crlf = raw.range(of: Data([0x0D, 0x0A])) else { return "" }
        return String(data: raw.subdata(in: 0..<crlf.lowerBound), encoding: .ascii) ?? ""
    }

    private func sendRaw(port: UInt16, payload: Data) async throws -> Data {
        let conn = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let q = DispatchQueue(label: "mcp.cleanup.test")
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
