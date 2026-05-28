import XCTest
@testable import FMail

/// Coverage for the host/issuer logic that decides which origin FMail
/// advertises in OAuth discovery + the 401 `resource_metadata` hint, plus the
/// `HTTPParser.formatResponse` content-type path. Security-adjacent (a spoofed
/// Host must not change auth, only the advertised discovery URL) and pure, so
/// worth pinning down.
final class MCPServerOriginTests: XCTestCase {

    // MARK: — isLoopbackHost

    func testLoopbackHostsAreRecognised() {
        // IPv6 appears bracketed in a Host header per RFC 3986 (`[::1]`),
        // which is the form this function handles.
        for host in ["127.0.0.1", "localhost",
                     "127.0.0.1:8765", "localhost:8765", "[::1]:8765",
                     "LOCALHOST", "[::1]"] {
            XCTAssertTrue(MCPServer.isLoopbackHost(host), "\(host) should be loopback")
        }
    }

    func testNonLoopbackHostsAreRejected() {
        for host in ["fmail.example.com", "10.0.0.1", "192.168.1.5:8765",
                     "example.com:8765", ""] {
            XCTAssertFalse(MCPServer.isLoopbackHost(host), "\(host) should NOT be loopback")
        }
    }

    // MARK: — issuerOrigin

    private func request(host: String) -> HTTPRequestLine {
        HTTPRequestLine(method: "GET", path: "/mcp", query: "",
                        headers: ["host": host], body: Data())
    }

    func testLoopbackRequestUsesHostOrigin() {
        let server = MCPServer()
        XCTAssertEqual(server.issuerOrigin(for: request(host: "127.0.0.1:8765")),
                       "http://127.0.0.1:8765")
    }

    func testTunnelRequestUsesConfiguredPublicURL() {
        let prev = MCPSettings.tunnelPublicURL
        defer { MCPSettings.tunnelPublicURL = prev }
        MCPSettings.tunnelPublicURL = "https://fmail.example.com/"

        let server = MCPServer()
        // Non-loopback Host → the configured public URL wins, trailing slash trimmed.
        XCTAssertEqual(server.issuerOrigin(for: request(host: "fmail.example.com")),
                       "https://fmail.example.com")
    }

    func testTunnelRequestWithoutPublicURLFallsBackToLoopbackPort() {
        let prev = MCPSettings.tunnelPublicURL
        defer { MCPSettings.tunnelPublicURL = prev }
        MCPSettings.tunnelPublicURL = ""

        let server = MCPServer()
        XCTAssertEqual(server.issuerOrigin(for: request(host: "fmail.example.com")),
                       "http://127.0.0.1:\(MCPSettings.port)")
    }

    // MARK: — formatResponse content type

    private func headerString(_ data: Data) -> String {
        guard let sep = data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else { return "" }
        return String(data: data.subdata(in: 0..<sep.lowerBound), encoding: .utf8) ?? ""
    }

    func testFormatResponseDefaultsToJSON() {
        let header = headerString(HTTPParser.formatResponse(status: 200, body: Data("{}".utf8)))
        XCTAssertTrue(header.contains("Content-Type: application/json"), header)
        XCTAssertTrue(header.hasPrefix("HTTP/1.1 200 OK"), header)
    }

    func testFormatResponseHonorsCustomContentType() {
        let header = headerString(HTTPParser.formatResponse(
            status: 200, body: Data("<html></html>".utf8),
            contentType: "text/html; charset=utf-8"
        ))
        XCTAssertTrue(header.contains("Content-Type: text/html; charset=utf-8"), header)
        XCTAssertFalse(header.contains("application/json"), header)
    }

    func testFormatResponseEmitsStatusTextAndExtraHeaders() {
        let header = headerString(HTTPParser.formatResponse(
            status: 401, body: Data(),
            extraHeaders: [("WWW-Authenticate", "Bearer")]
        ))
        XCTAssertTrue(header.hasPrefix("HTTP/1.1 401 Unauthorized"), header)
        XCTAssertTrue(header.contains("WWW-Authenticate: Bearer"), header)
    }
}
