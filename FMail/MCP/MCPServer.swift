import Foundation
import Network

/// Loopback-only HTTP/JSON-RPC server that exposes FMail's index to MCP
/// clients (Claude Code etc.). Off by default — `MCPSettings.enabled`
/// gates startup. Bound to `127.0.0.1` only so nothing on the LAN can reach
/// it; defense-in-depth: every accepted connection is also peer-checked
/// before we read.
actor MCPServer {
    private var listener: NWListener?
    private(set) var isRunning = false
    private(set) var port: UInt16 = 0
    private(set) var lastError: String?

    private let dispatcher: MCPDispatcher
    private let queue = DispatchQueue(label: "com.felixmatschke.FMail.mcp", qos: .userInitiated)

    /// Read cap per request — JSON-RPC requests are tiny; this is a guardrail
    /// against a misbehaving client wedging us with megabytes of bytes.
    private static let maxRequestBytes = 1 << 20  // 1 MB

    init(dispatcher: MCPDispatcher = MCPDispatcher()) {
        self.dispatcher = dispatcher
    }

    /// Hand the dispatcher out so callers (`MCPTools.register`) can register
    /// tools after the server is constructed. Tools registered after
    /// `start()` show up on the next `tools/list`.
    func dispatcherForRegistration() -> MCPDispatcher { dispatcher }

    /// Start listening. Throws if the port is unavailable or NWListener
    /// transitions to `.failed` / `.waiting` (port already in use surfaces
    /// as `.waiting`).
    func start(port portToUse: Int) async throws {
        guard !isRunning else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(portToUse)) else {
            throw MCPServerError.invalidPort(portToUse)
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Restrict to loopback. NWListener defaults to all interfaces; this
        // is the recommended way to keep the listener strictly local.
        parameters.requiredInterfaceType = .loopback

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters, on: nwPort)
        } catch {
            self.lastError = String(describing: error)
            throw error
        }

        let result: Result<UInt16, Error> = await withCheckedContinuation { (cont: CheckedContinuation<Result<UInt16, Error>, Never>) in
            // Resume guard — NWListener may emit multiple state updates.
            let didResume = AtomicFlag()
            newListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let p = newListener.port?.rawValue ?? UInt16(portToUse)
                    if didResume.testAndSet() { cont.resume(returning: .success(p)) }
                case .failed(let err):
                    if didResume.testAndSet() { cont.resume(returning: .failure(err)) }
                case .waiting(let err):
                    // Port already in use surfaces here on macOS. Treat as
                    // a hard failure for our purposes.
                    if didResume.testAndSet() { cont.resume(returning: .failure(err)) }
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] conn in
                Task { [weak self] in await self?.handleConnection(conn) }
            }
            newListener.start(queue: queue)
        }

        switch result {
        case .success(let p):
            // Replace the startup state handler with a logging one so we
            // notice if the listener fails later.
            newListener.stateUpdateHandler = { state in
                if case .failed(let err) = state {
                    Log.mcp.error("MCP listener failed: \(String(describing: err), privacy: .public)")
                }
            }
            self.listener = newListener
            self.isRunning = true
            self.port = p
            self.lastError = nil
            Log.mcp.info("MCP server listening on 127.0.0.1:\(p)")
        case .failure(let err):
            newListener.cancel()
            self.lastError = String(describing: err)
            throw err
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        port = 0
    }

    // MARK: — Connection handling

    private func handleConnection(_ conn: NWConnection) async {
        // Defense-in-depth: refuse any peer that isn't on loopback.
        if !isLoopbackPeer(conn) {
            conn.cancel()
            return
        }

        conn.start(queue: queue)
        defer { conn.cancel() }

        // Read until we have a complete HTTP request (or hit the size cap).
        guard let (request, _) = await readHTTPRequest(conn) else {
            return
        }

        let responseBytes = await produceResponse(for: request)
        logRequest(request, response: responseBytes)
        await writeAll(conn, data: responseBytes)
    }

    /// Log one access-log line per incoming request. Includes the status
    /// code we returned + a hint about auth presence + the User-Agent so
    /// "is Claude actually reaching the server?" / "what's it asking
    /// for?" debugging works from `log stream`. Body content is NOT
    /// logged — it might contain email subjects / addresses.
    ///
    /// View live:
    ///   log stream --predicate 'subsystem == "com.felixmatschke.FMail" && category == "mcp"' --info
    nonisolated private func logRequest(_ req: HTTPRequestLine, response: Data) {
        let status = extractStatusCode(response) ?? 0
        let pathWithQuery = req.query.isEmpty ? req.path : "\(req.path)?\(req.query)"
        let ua = (req.headers["user-agent"] ?? "-").prefix(60)
        let auth = req.headers["authorization"]?.isEmpty == false ? "yes" : "no"
        Log.mcp.info("→ \(req.method, privacy: .public) \(pathWithQuery, privacy: .public) status=\(status, privacy: .public) auth=\(auth, privacy: .public) ua=\"\(ua, privacy: .public)\"")
    }

    /// Pull the integer status code out of a formatted response. The
    /// response starts with `HTTP/1.1 <code> <text>\r\n`.
    nonisolated private func extractStatusCode(_ data: Data) -> Int? {
        guard let crlf = data.range(of: Data([0x0D, 0x0A])) else { return nil }
        let line = String(data: data.subdata(in: 0..<crlf.lowerBound), encoding: .ascii) ?? ""
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }

    private func produceResponse(for request: HTTPRequestLine) async -> Data {
        let method = request.method.uppercased()
        let path = request.path

        // — OAuth endpoints. Auth is what they implement, so they run
        //   unauthenticated by design; public-internet exposure is gated
        //   by the user-controlled approval window (see `OAuthStore`).
        if method == "GET" && path == "/.well-known/oauth-authorization-server" {
            return OAuthHandlers.metadata(issuer: issuerOrigin(for: request))
        }
        if method == "GET" && path == "/.well-known/oauth-protected-resource" {
            return OAuthHandlers.protectedResource(issuer: issuerOrigin(for: request))
        }
        // OAuth handlers are `@MainActor`; calling them from this actor hops
        // to the main actor automatically (no explicit `MainActor.run`).
        if method == "POST" && path == "/register" {
            return await OAuthHandlers.register(body: request.body)
        }
        if method == "GET" && path == "/authorize" {
            let query = FormParser.parseQuery(request.query)
            return await OAuthHandlers.authorizePage(query: query)
        }
        if method == "POST" && path == "/authorize/approve" {
            let form = FormParser.parse(request.body)
            return await OAuthHandlers.authorizeApprove(form: form)
        }
        if method == "POST" && path == "/authorize/deny" {
            let form = FormParser.parse(request.body)
            return await OAuthHandlers.authorizeDeny(form: form)
        }
        if method == "POST" && path == "/token" {
            let form = FormParser.parse(request.body)
            return await OAuthHandlers.token(form: form)
        }

        // — MCP probe / RPC.

        // GET /mcp → small server-info probe (handy for `curl localhost:8765/mcp`).
        // No auth required: the only thing this leaks is "an MCP server is
        // here", which the bearer-protected endpoints would confirm anyway.
        if method == "GET" {
            let info: [String: JSONValue] = [
                "server": .string(MCPProtocol.serverName),
                "version": .string(MCPProtocol.serverVersion),
                "protocolVersion": .string(MCPProtocol.version),
                "endpoint": .string(MCPProtocol.mcpPath)
            ]
            let body = (try? JSONEncoder().encode(info)) ?? Data("{}".utf8)
            return HTTPParser.formatResponse(status: 200, body: body)
        }

        if method != "POST" {
            return HTTPParser.formatResponse(status: 405, body: Data("{}".utf8))
        }
        if path != MCPProtocol.mcpPath {
            return HTTPParser.formatResponse(status: 404, body: Data("{}".utf8))
        }

        // Bearer-token check. The presented token must match either the
        // static `MCPSettings.authToken` (used by Claude Code) or an
        // OAuth-issued session token (used by remote MCP clients that
        // completed the /authorize → /token flow). When both stores are
        // empty, the server runs unauthenticated for local loopback.
        let issuer = issuerOrigin(for: request)
        if let denial = await denyIfMissingAuth(request, issuer: issuer) {
            return denial
        }

        let result = await dispatcher.dispatch(rawBody: request.body)
        switch result {
        case .response(let body):
            return HTTPParser.formatResponse(status: 200, body: body)
        case .notification:
            // Notifications: per MCP Streamable HTTP, return 202 with empty body.
            return HTTPParser.formatResponse(status: 202, body: Data())
        }
    }

    /// Returns a 401 response when the required bearer token is missing or
    /// wrong. Returns nil when auth is disabled AND the server isn't
    /// exposed via a tunnel, or the request carries a recognised token.
    ///
    /// Fail-closed behaviour: if `MCPSettings.tunnelPublicURL` is set
    /// (i.e. the user has configured a Cloudflare tunnel) but neither
    /// auth source is populated, we refuse every request. Without this,
    /// clearing the static token in Settings while a tunnel is running
    /// would silently make the server reachable on the public Internet
    /// with no authentication.
    @MainActor
    private func denyIfMissingAuth(_ request: HTTPRequestLine, issuer: String) -> Data? {
        let staticToken = MCPSettings.authToken
        let presented = bearerToken(in: request.headers["authorization"] ?? "")
        let hasStaticToken = !staticToken.isEmpty
        let hasSessions = !OAuthStore.shared.sessions.isEmpty
        let tunnelConfigured = !MCPSettings.tunnelPublicURL.trimmingCharacters(in: .whitespaces).isEmpty

        if !hasStaticToken && !hasSessions {
            if tunnelConfigured {
                Log.mcp.error("MCP rejected request: tunnel configured but no auth token / OAuth sessions — refusing to serve unauthenticated requests")
                return unauthorizedResponse(issuer: issuer)
            }
            // No auth configured AND no tunnel → loopback-only legacy
            // behaviour; the listener is bound to 127.0.0.1 only.
            return nil
        }
        // Accept static token OR any active OAuth session token. The static
        // token is what the local Claude Code route uses (set it in the MCP
        // config's `headers` Authorization to skip OAuth entirely).
        if hasStaticToken, MCPHelpers.constantTimeEqual(presented, staticToken) { return nil }
        if !presented.isEmpty, OAuthStore.shared.tokenIsValid(presented) { return nil }

        Log.mcp.info("MCP rejected request: missing/invalid bearer token")
        return unauthorizedResponse(issuer: issuer)
    }

    /// Build the standard 401 response with the OAuth discovery hint.
    /// Shared between the fail-closed and bad-token paths. (The specific
    /// rejection reason is logged at each call site.)
    @MainActor
    private func unauthorizedResponse(issuer: String) -> Data {
        let body = Data(#"{"error":"unauthorized"}"#.utf8)
        // The MCP authorization spec discovers OAuth via the
        // `resource_metadata=...` parameter on this header. Without it,
        // remote clients can't find `/.well-known/oauth-protected-resource`
        // and the connector flow fails before it ever reaches /authorize.
        let metadataURL = "\(issuer)/.well-known/oauth-protected-resource"
        return HTTPParser.formatResponse(
            status: 401,
            body: body,
            extraHeaders: [("WWW-Authenticate", #"Bearer realm="fmail", resource_metadata="\#(metadataURL)""#)]
        )
    }

    /// Origin to advertise in OAuth discovery + the 401 `resource_metadata`
    /// hint, derived from the request's `Host`. A loopback host yields an
    /// `http://<host>` issuer so a local MCP client's RFC 8707 resource check
    /// matches the URL it actually connected to (`http://127.0.0.1:8765/mcp`)
    /// instead of the remote tunnel URL; non-loopback (tunnel) requests use
    /// the configured public URL.
    ///
    /// This affects discovery hints ONLY — `denyIfMissingAuth` validates the
    /// bearer token regardless of issuer, so a spoofed `Host` can't bypass
    /// auth or reach the index unauthenticated.
    nonisolated func issuerOrigin(for request: HTTPRequestLine) -> String {
        let host = (request.headers["host"] ?? "").trimmingCharacters(in: .whitespaces)
        if Self.isLoopbackHost(host) {
            return "http://\(host)"
        }
        let raw = MCPSettings.tunnelPublicURL.trimmingCharacters(in: .whitespaces)
        var base = raw.isEmpty ? "http://127.0.0.1:\(MCPSettings.port)" : raw
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    /// True for `127.0.0.1`, `localhost`, or `::1`, with or without a port
    /// (and IPv6 bracket form `[::1]:8765`).
    nonisolated static func isLoopbackHost(_ host: String) -> Bool {
        let h = host.lowercased()
        let name: String
        if h.hasPrefix("["), let close = h.firstIndex(of: "]") {
            name = String(h[h.index(after: h.startIndex)..<close])
        } else if let colon = h.firstIndex(of: ":") {
            name = String(h[h.startIndex..<colon])
        } else {
            name = h
        }
        return name == "127.0.0.1" || name == "localhost" || name == "::1"
    }

    /// Extracts the token from a `Bearer <token>` header value. Tolerates
    /// extra surrounding whitespace and mixed case on the scheme name.
    /// `nonisolated` so `denyIfMissingAuth` (running on the main actor)
    /// can call it without an actor hop.
    nonisolated private func bearerToken(in header: String) -> String {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bearer ") else { return "" }
        let after = trimmed.index(trimmed.startIndex, offsetBy: 7)
        return String(trimmed[after...]).trimmingCharacters(in: .whitespaces)
    }

    private func readHTTPRequest(_ conn: NWConnection) async -> (HTTPRequestLine, Data)? {
        var accumulated = Data()
        while accumulated.count < Self.maxRequestBytes {
            let chunk: Data? = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if error != nil {
                        cont.resume(returning: nil)
                        return
                    }
                    if let data, !data.isEmpty {
                        cont.resume(returning: data)
                        return
                    }
                    if isComplete {
                        cont.resume(returning: nil)
                        return
                    }
                    cont.resume(returning: Data())  // keep going
                }
            }
            guard let chunk else { return nil }
            // A zero-byte chunk means NW had nothing to deliver but the
            // connection isn't done. Don't burn CPU waiting — yield so
            // the next receive call sees fresh data.
            if chunk.isEmpty {
                await Task.yield()
                continue
            }
            accumulated.append(chunk)

            do {
                if let (parsed, _) = try HTTPParser.parse(accumulated) {
                    return (parsed, accumulated)
                }
            } catch {
                Log.mcp.error("Bad HTTP request: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        return nil
    }

    private func writeAll(_ conn: NWConnection, data: Data) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            conn.send(content: data, completion: .contentProcessed { _ in
                cont.resume()
            })
        }
    }

    private func isLoopbackPeer(_ conn: NWConnection) -> Bool {
        switch conn.endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let addr):
                return addr.isLoopback
            case .ipv6(let addr):
                return addr.isLoopback
            case .name(let name, _):
                return name == "localhost" || name == "127.0.0.1" || name == "::1"
            @unknown default:
                return false
            }
        default:
            return false
        }
    }
}

enum MCPServerError: Error, CustomStringConvertible {
    case invalidPort(Int)

    var description: String {
        switch self {
        case .invalidPort(let p): return "invalid MCP port: \(p)"
        }
    }
}

/// Tiny one-shot atomic flag used to guard the startup continuation against
/// double-resume when NWListener emits multiple state updates.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func testAndSet() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
