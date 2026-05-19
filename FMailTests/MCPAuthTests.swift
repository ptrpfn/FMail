import XCTest
import Network
@testable import FMail

/// Bearer-token auth tests for the MCP HTTP server. The server is bound on
/// port 0 (kernel-assigned ephemeral) and exercised over a real TCP loopback
/// connection, so the full request path (HTTP framing → header parse →
/// auth gate → dispatcher) is covered end-to-end.
final class MCPAuthTests: XCTestCase {

    private var savedToken: String = ""
    private var savedTunnelURL: String = ""

    override func setUp() {
        super.setUp()
        savedToken = MCPSettings.authToken
        savedTunnelURL = MCPSettings.tunnelPublicURL
        MCPSettings.authToken = ""
        // Wipe the tunnel-public-URL too: the fail-closed auth path
        // (`MCPServer.denyIfMissingAuth`) refuses unauthenticated
        // requests when a tunnel is configured, which would invert the
        // expected behaviour of the no-auth tests below.
        MCPSettings.tunnelPublicURL = ""
        // Tests share UserDefaults with the host app, so OAuth sessions
        // persisted by another test (or a real local run) would flip
        // the no-auth path off. Wipe to a known state.
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

    // MARK: — `authToken` empty → no auth required (existing local-loopback behaviour)

    func testNoTokenSetAllowsUnauthenticatedRequest() async throws {
        MCPSettings.authToken = ""
        let server = MCPServer()
        try await server.start(port: 0)
        let port = await server.port
        defer { Task { await server.stop() } }

        let req = httpRequest(body: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        let raw = try await sendRaw(port: port, payload: Data(req.utf8))
        XCTAssertTrue(responseStatusLine(raw).hasPrefix("HTTP/1.1 200"))
    }

    // MARK: — `authToken` set → POST without header is denied

    func testMissingHeaderIsRejectedWith401() async throws {
        MCPSettings.authToken = MCPSettings.generateAuthToken()
        let server = MCPServer()
        try await server.start(port: 0)
        let port = await server.port
        defer { Task { await server.stop() } }

        let req = httpRequest(body: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        let raw = try await sendRaw(port: port, payload: Data(req.utf8))
        XCTAssertTrue(responseStatusLine(raw).hasPrefix("HTTP/1.1 401"))
        XCTAssertTrue(responseHeaders(raw).contains("WWW-Authenticate:"))
    }

    func testWrongTokenIsRejectedWith401() async throws {
        MCPSettings.authToken = MCPSettings.generateAuthToken()
        let server = MCPServer()
        try await server.start(port: 0)
        let port = await server.port
        defer { Task { await server.stop() } }

        let req = httpRequest(
            body: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            headers: ["Authorization": "Bearer wrong-token-value"]
        )
        let raw = try await sendRaw(port: port, payload: Data(req.utf8))
        XCTAssertTrue(responseStatusLine(raw).hasPrefix("HTTP/1.1 401"))
    }

    func testCorrectTokenPasses() async throws {
        let token = MCPSettings.generateAuthToken()
        MCPSettings.authToken = token
        let server = MCPServer()
        try await server.start(port: 0)
        let port = await server.port
        defer { Task { await server.stop() } }

        let req = httpRequest(
            body: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            headers: ["Authorization": "Bearer \(token)"]
        )
        let raw = try await sendRaw(port: port, payload: Data(req.utf8))
        XCTAssertTrue(responseStatusLine(raw).hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(responseBody(raw).contains("\"protocolVersion\""))
    }

    /// Tolerates `Bearer` casing and surrounding whitespace.
    func testTokenSchemeIsCaseInsensitive() async throws {
        let token = MCPSettings.generateAuthToken()
        MCPSettings.authToken = token
        let server = MCPServer()
        try await server.start(port: 0)
        let port = await server.port
        defer { Task { await server.stop() } }

        let req = httpRequest(
            body: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            headers: ["Authorization": "  bearer   \(token)  "]
        )
        let raw = try await sendRaw(port: port, payload: Data(req.utf8))
        XCTAssertTrue(responseStatusLine(raw).hasPrefix("HTTP/1.1 200"))
    }

    // MARK: — GET probe stays unauthenticated for sanity-checks

    func testGETProbeUnauthenticatedEvenWithTokenSet() async throws {
        MCPSettings.authToken = MCPSettings.generateAuthToken()
        let server = MCPServer()
        try await server.start(port: 0)
        let port = await server.port
        defer { Task { await server.stop() } }

        let req = "GET \(MCPProtocol.mcpPath) HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let raw = try await sendRaw(port: port, payload: Data(req.utf8))
        XCTAssertTrue(responseStatusLine(raw).hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(responseBody(raw).contains("\"server\":"))
    }

    // MARK: — Token generator

    func testGenerateAuthTokenIsUnique() {
        let a = MCPSettings.generateAuthToken()
        let b = MCPSettings.generateAuthToken()
        XCTAssertNotEqual(a, b)
        XCTAssertGreaterThanOrEqual(a.count, 40, "32-byte base64url ≈ 43 chars")
        // base64url: no +, /, or = chars.
        XCTAssertFalse(a.contains("+"))
        XCTAssertFalse(a.contains("/"))
        XCTAssertFalse(a.contains("="))
    }

    // MARK: — Helpers

    private func httpRequest(body: String, headers: [String: String] = [:]) -> String {
        var lines: [String] = [
            "POST \(MCPProtocol.mcpPath) HTTP/1.1",
            "Host: localhost",
            "Content-Type: application/json",
            "Content-Length: \(body.utf8.count)"
        ]
        for (k, v) in headers {
            lines.append("\(k): \(v)")
        }
        lines.append("")
        lines.append(body)
        return lines.joined(separator: "\r\n")
    }

    private func responseStatusLine(_ raw: Data) -> String {
        guard let crlf = raw.range(of: Data([0x0D, 0x0A])) else { return "" }
        return String(data: raw.subdata(in: 0..<crlf.lowerBound), encoding: .ascii) ?? ""
    }

    private func responseHeaders(_ raw: Data) -> String {
        guard let sep = raw.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else { return "" }
        return String(data: raw.subdata(in: 0..<sep.lowerBound), encoding: .ascii) ?? ""
    }

    private func responseBody(_ raw: Data) -> String {
        guard let sep = raw.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else { return "" }
        return String(data: raw.subdata(in: sep.upperBound..<raw.count), encoding: .utf8) ?? ""
    }

    private func sendRaw(port: UInt16, payload: Data) async throws -> Data {
        let conn = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let q = DispatchQueue(label: "mcp.auth.test")
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
