import XCTest
import Network
@testable import FMail

/// Tests for the MCP server. The handler tests use a tmp-file IndexDB
/// (not `:memory:`, so it survives the actor's hop) populated with a
/// hand-built fixture.
final class MCPTests: XCTestCase {

    /// Tests share `UserDefaults.standard` with the host app (the test
    /// bundle is loaded into the FMail binary). Without these resets,
    /// any auth state the developer left in their real Settings would
    /// flip the no-auth path on / off in tests that assume the legacy
    /// loopback behaviour.
    private var savedAuthToken: String = ""

    override func setUp() {
        super.setUp()
        savedAuthToken = MCPSettings.authToken
        MCPSettings.authToken = ""
        MainActor.assumeIsolated {
            OAuthStore.shared.revokeAllSessions()
            OAuthStore.shared.closeApprovalWindow()
        }
    }

    override func tearDown() {
        MCPSettings.authToken = savedAuthToken
        MainActor.assumeIsolated {
            OAuthStore.shared.revokeAllSessions()
            OAuthStore.shared.closeApprovalWindow()
        }
        super.tearDown()
    }

    // MARK: — JSONValue / JSON-RPC envelope round-trips

    func testJSONValueRoundTripsAllShapes() throws {
        let v: JSONValue = .object([
            "n": .null,
            "b": .bool(true),
            "i": .int(42),
            "d": .double(3.14),
            "s": .string("hi"),
            "arr": .array([.int(1), .string("x"), .bool(false)])
        ])
        let data = try JSONEncoder().encode(v)
        let back = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(back, v)
    }

    func testJSONRPCRequestDecodesNotification() throws {
        let body = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        let req = try JSONDecoder().decode(JSONRPCRequest.self, from: body)
        XCTAssertNil(req.id)
        XCTAssertEqual(req.method, "notifications/initialized")
    }

    func testJSONRPCResponseEncodesExactlyOneOfResultOrError() throws {
        let success = JSONRPCResponse.success(id: .int(1), result: .object(["ok": .bool(true)]))
        let s = String(data: try JSONEncoder().encode(success), encoding: .utf8) ?? ""
        XCTAssertTrue(s.contains("\"result\""))
        XCTAssertFalse(s.contains("\"error\""))

        let failure = JSONRPCResponse.failure(id: .string("x"), error: .init(code: -32601, message: "nope"))
        let f = String(data: try JSONEncoder().encode(failure), encoding: .utf8) ?? ""
        XCTAssertTrue(f.contains("\"error\""))
        XCTAssertFalse(f.contains("\"result\""))
    }

    // MARK: — HTTP framing

    func testHTTPParserParsesPostWithBody() throws {
        let raw = "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello"
        let data = Data(raw.utf8)
        let result = try HTTPParser.parse(data)
        XCTAssertNotNil(result)
        let (req, total) = result!
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/mcp")
        XCTAssertEqual(req.body, Data("hello".utf8))
        XCTAssertEqual(total, data.count)
    }

    func testHTTPParserReturnsNilWhenIncomplete() throws {
        let raw = "POST /mcp HTTP/1.1\r\nContent-Length: 100\r\n\r\nshort"
        let data = Data(raw.utf8)
        XCTAssertNil(try HTTPParser.parse(data))
    }

    // MARK: — Dispatcher

    func testDispatcherInitializeReturnsServerInfo() async throws {
        let dispatcher = MCPDispatcher()
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8)
        let result = await dispatcher.dispatch(rawBody: body)
        guard case .response(let data) = result else {
            return XCTFail("expected response, got \(result)")
        }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["jsonrpc"] as? String, "2.0")
        let serverInfo = ((json["result"] as? [String: Any])?["serverInfo"]) as? [String: Any]
        XCTAssertEqual(serverInfo?["name"] as? String, "fmail")
        XCTAssertEqual(serverInfo?["version"] as? String, "0.1.0")
    }

    func testDispatcherToolsListEmptyWhenNoToolsRegistered() async throws {
        let dispatcher = MCPDispatcher()
        let body = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#.utf8)
        let result = await dispatcher.dispatch(rawBody: body)
        guard case .response(let data) = result else {
            return XCTFail("expected response, got \(result)")
        }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tools = ((json["result"] as? [String: Any])?["tools"]) as? [Any]
        XCTAssertEqual(tools?.count ?? -1, 0)
    }

    func testDispatcherUnknownMethodReturnsMethodNotFound() async throws {
        let dispatcher = MCPDispatcher()
        let body = Data(#"{"jsonrpc":"2.0","id":3,"method":"does/not/exist"}"#.utf8)
        let result = await dispatcher.dispatch(rawBody: body)
        guard case .response(let data) = result else {
            return XCTFail("expected response, got \(result)")
        }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let err = json["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? Int, JSONRPCErrorCode.methodNotFound)
    }

    func testDispatcherMalformedJSONReturnsParseError() async throws {
        let dispatcher = MCPDispatcher()
        let body = Data("not even close to json".utf8)
        let result = await dispatcher.dispatch(rawBody: body)
        guard case .response(let data) = result else {
            return XCTFail("expected response, got \(result)")
        }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let err = json["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? Int, JSONRPCErrorCode.parseError)
    }

    func testDispatcherNotificationGetsNoResponse() async throws {
        let dispatcher = MCPDispatcher()
        let body = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        let result = await dispatcher.dispatch(rawBody: body)
        guard case .notification = result else {
            return XCTFail("expected .notification, got \(result)")
        }
    }

    func testDispatcherToolsCallReturnsTextContentBlock() async throws {
        let dispatcher = MCPDispatcher()
        let echoTool = MCPTool(
            name: "echo",
            description: "echoes its arguments",
            inputSchema: .object(["type": .string("object")]),
            handler: { args in args }
        )
        await dispatcher.register(echoTool)

        let body = Data(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{"a":1}}}"#.utf8)
        let result = await dispatcher.dispatch(rawBody: body)
        guard case .response(let data) = result else {
            return XCTFail("expected response, got \(result)")
        }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let res = try XCTUnwrap(json["result"] as? [String: Any])
        XCTAssertEqual(res["isError"] as? Bool, false)
        let content = try XCTUnwrap(res["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        let text = try XCTUnwrap(content.first?["text"] as? String)
        // The text is itself JSON-encoded args.
        let inner = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(inner["a"] as? Int, 1)
    }

    // MARK: — Phase A3: find_unanswered_threads + mark_read

    func testFindUnansweredThreadsReturnsSchoolThread() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let context = MCPContext(indexDB: fixture.db, bodyLoader: fixture.bodyLoader)

        // Two-day window covers both messages.
        let result = try await MCPHandlers.findUnansweredThreads(
            .object(["since": .string(isoDate(daysAgo: 7))]),
            context: context
        )
        let payload = try roundTrip(result)
        let threads = try XCTUnwrap(payload["threads"] as? [[String: Any]])
        XCTAssertEqual(threads.count, 1, "Only the school thread is unanswered")
        let t = try XCTUnwrap(threads.first)
        XCTAssertEqual(t["thread_id"] as? Int, fixture.schoolThreadId)
        XCTAssertEqual(t["latest_outgoing_address"] as? String, "felix@example.com")
        let recipients = try XCTUnwrap(t["recipient_addresses"] as? [String])
        XCTAssertEqual(recipients, ["anna@example.com"])
    }

    func testFindUnansweredThreadsHonorsSinceFilter() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let context = MCPContext(indexDB: fixture.db, bodyLoader: fixture.bodyLoader)

        // Tomorrow as `since` → nothing is unanswered yet (the latest outgoing
        // message is yesterday, < tomorrow).
        let result = try await MCPHandlers.findUnansweredThreads(
            .object(["since": .string(isoDate(daysAgo: -1))]),
            context: context
        )
        let payload = try roundTrip(result)
        let threads = try XCTUnwrap(payload["threads"] as? [[String: Any]])
        XCTAssertEqual(threads.count, 0)
    }

    func testFindUnansweredThreadsOurAddressMustMatchAccountSender() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let context = MCPContext(indexDB: fixture.db, bodyLoader: fixture.bodyLoader)

        // anna isn't one of our outgoing senders.
        let result = try await MCPHandlers.findUnansweredThreads(
            .object([
                "since": .string(isoDate(daysAgo: 7)),
                "our_address": .string("anna@example.com")
            ]),
            context: context
        )
        let payload = try roundTrip(result)
        let threads = try XCTUnwrap(payload["threads"] as? [[String: Any]])
        XCTAssertEqual(threads.count, 0)
    }

    // MARK: — End-to-end: tools/list registration

    func testToolsListReturnsAllReadToolsAfterRegistration() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let dispatcher = MCPDispatcher()
        let context = MCPContext(indexDB: fixture.db, bodyLoader: fixture.bodyLoader)
        await MCPTools.registerReadTools(on: dispatcher, context: context)

        let names = await dispatcher.registeredToolNames()
        XCTAssertEqual(Set(names), [
            "search_emails",
            "list_threads",
            "list_accounts",
            "get_thread",
            "get_email",
            "get_attachment",
            "get_attachments_for_rowids",
            "find_unanswered_threads"
        ])
    }

    // MARK: — End-to-end: bind on port 0, full handshake

    func testServerHandshakeOverTCP() async throws {
        let server = MCPServer()
        try await server.start(port: 0)
        let port = await server.port
        XCTAssertGreaterThan(port, 0)
        defer {
            Task { await server.stop() }
        }

        // 1. initialize
        let initRequest = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
        let initResp = try await sendOneRequest(port: port, body: initRequest)
        XCTAssertTrue(initResp.contains("\"protocolVersion\""))
        XCTAssertTrue(initResp.contains("\"serverInfo\""))

        // 2. notifications/initialized → 202 No content
        let notifBody = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let notifResp = try await sendOneRequest(port: port, body: notifBody, expectStatus: 202)
        XCTAssertEqual(notifResp.trimmingCharacters(in: .whitespacesAndNewlines), "")

        // 3. tools/list → empty
        let listResp = try await sendOneRequest(port: port, body: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        XCTAssertTrue(listResp.contains("\"tools\""))

        // 4. unknown method → method not found
        let unknownResp = try await sendOneRequest(port: port, body: #"{"jsonrpc":"2.0","id":3,"method":"nope"}"#)
        XCTAssertTrue(unknownResp.contains("\"-32601\"") || unknownResp.contains("-32601"))
    }

    // MARK: — Read handlers against an in-memory fixture

    func testSearchEmailsReturnsMatchingMessages() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }

        let context = MCPContext(indexDB: fixture.db, bodyLoader: fixture.bodyLoader)
        let result = try await MCPHandlers.searchEmails(
            .object(["query": .string("school")]),
            context: context
        )
        let payload = try roundTrip(result)
        let results = try XCTUnwrap(payload["results"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(results.count, 2, "Expected both school-trip messages")
        let senders = results.compactMap { $0["sender_address"] as? String }
        XCTAssertTrue(senders.contains("anna@example.com"))
        XCTAssertTrue(senders.contains("felix@example.com"))
        // newest-first
        XCTAssertEqual(results.first?["sender_address"] as? String, "felix@example.com")
        XCTAssertNotNil(results.first?["thread_id"])
        XCTAssertNotNil(results.first?["mailbox_path"])
    }

    func testSearchEmailsHonorsLimit() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let context = MCPContext(indexDB: fixture.db, bodyLoader: fixture.bodyLoader)

        // Match anything from anna; we have 2 such messages in the fixture.
        let result = try await MCPHandlers.searchEmails(
            .object([
                "query": .string("from:anna"),
                "limit": .int(1)
            ]),
            context: context
        )
        let payload = try roundTrip(result)
        let results = try XCTUnwrap(payload["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 1)
    }

    func testSearchEmailsRejectsEmptyQuery() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let context = MCPContext(indexDB: fixture.db, bodyLoader: fixture.bodyLoader)

        do {
            _ = try await MCPHandlers.searchEmails(.object(["query": .string("")]), context: context)
            XCTFail("expected invalidParams")
        } catch let payload as JSONRPCErrorPayload {
            XCTAssertEqual(payload.code, JSONRPCErrorCode.invalidParams)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testListThreadsAllMailboxes() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let context = MCPContext(indexDB: fixture.db, bodyLoader: fixture.bodyLoader)

        let result = try await MCPHandlers.listThreads(.object([:]), context: context)
        let payload = try roundTrip(result)
        let threads = try XCTUnwrap(payload["threads"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(threads.count, 1)
    }

    func testListThreadsUnreadOnly() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let context = MCPContext(indexDB: fixture.db, bodyLoader: fixture.bodyLoader)

        let result = try await MCPHandlers.listThreads(
            .object(["unread_only": .bool(true)]),
            context: context
        )
        let payload = try roundTrip(result)
        let threads = try XCTUnwrap(payload["threads"] as? [[String: Any]])
        // Fixture has one unread thread (msg #2 is unread).
        XCTAssertGreaterThanOrEqual(threads.count, 1)
        for t in threads {
            XCTAssertGreaterThan(t["unread_count"] as? Int ?? 0, 0)
        }
    }

    func testGetEmailReturnsFullShape() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let context = MCPContext(indexDB: fixture.db, bodyLoader: fixture.bodyLoader)

        let result = try await MCPHandlers.getEmail(
            .object([
                "rowid": .int(Int64(fixture.schoolMessageRowId)),
                "max_body_chars": .int(0)
            ]),
            context: context
        )
        let payload = try roundTrip(result)
        XCTAssertEqual(payload["rowid"] as? Int, fixture.schoolMessageRowId)
        XCTAssertEqual(payload["sender_address"] as? String, "anna@example.com")
        let to = try XCTUnwrap(payload["to"] as? [String])
        XCTAssertEqual(to, ["felix@example.com"])
        // No .emlx on disk → empty body
        XCTAssertEqual(payload["plain_text_body"] as? String, "")
    }

    func testGetEmailUnknownRowidThrows() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let context = MCPContext(indexDB: fixture.db, bodyLoader: fixture.bodyLoader)

        do {
            _ = try await MCPHandlers.getEmail(.object(["rowid": .int(999999)]), context: context)
            XCTFail("expected invalidParams")
        } catch let payload as JSONRPCErrorPayload {
            XCTAssertEqual(payload.code, JSONRPCErrorCode.invalidParams)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testGetThreadReturnsAllMessages() async throws {
        let fixture = try await Fixture.make()
        defer { try? fixture.cleanup() }
        let context = MCPContext(indexDB: fixture.db, bodyLoader: fixture.bodyLoader)

        let result = try await MCPHandlers.getThread(
            .object([
                "thread_id": .int(Int64(fixture.schoolThreadId)),
                "include_bodies": .bool(false)
            ]),
            context: context
        )
        let payload = try roundTrip(result)
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2, "Fixture school thread has 2 messages")
    }

    // MARK: — Helpers

    /// Open a TCP connection to localhost:port, send a single HTTP/1.1 POST,
    /// read the full response, return the body as a string. Caller can
    /// optionally assert the status line.
    private func sendOneRequest(port: UInt16, body: String, expectStatus: Int = 200) async throws -> String {
        let req = "POST \(MCPProtocol.mcpPath) HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let raw = try await sendRaw(port: port, payload: Data(req.utf8))
        // Split status line + headers + body
        guard let sep = raw.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else {
            XCTFail("no header terminator in response")
            return ""
        }
        let headerStr = String(data: raw.subdata(in: 0..<sep.lowerBound), encoding: .ascii) ?? ""
        if !headerStr.hasPrefix("HTTP/1.1 \(expectStatus)") {
            XCTFail("expected HTTP/1.1 \(expectStatus); got: \(headerStr)")
        }
        let bodyData = raw.subdata(in: sep.upperBound..<raw.count)
        return String(data: bodyData, encoding: .utf8) ?? ""
    }

    /// ISO-8601 date string for `daysAgo` days before today (negative = future).
    private func isoDate(daysAgo: Int) -> String {
        let date = Date().addingTimeInterval(TimeInterval(-86400 * daysAgo))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// JSON-encode a JSONValue, then JSONSerialize-decode it to `[String: Any]`
    /// so tests can assert with the looser shape.
    private func roundTrip(_ v: JSONValue) throws -> [String: Any] {
        let data = try JSONEncoder().encode(v)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "expected object"])
        }
        return dict
    }

    private func sendRaw(port: UInt16, payload: Data) async throws -> Data {
        let conn = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let q = DispatchQueue(label: "mcp.test.client")
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
