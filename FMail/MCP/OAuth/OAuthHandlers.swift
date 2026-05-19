import Foundation

/// HTTP endpoint handlers for the MCP OAuth flow. Each function takes the
/// parsed request line + body and returns the response data ready for
/// `HTTPParser.formatResponse`. Pure-ish: state lives on
/// `OAuthStore.shared` (main actor).
enum OAuthHandlers {

    // MARK: — Metadata discovery (`GET /.well-known/oauth-authorization-server`)

    static func metadata(issuer: String) -> Data {
        let body = OAuthMetadata.make(issuer: issuer)
        let jsonBody = (try? JSONEncoder().encode(JSONValue.object(body))) ?? Data("{}".utf8)
        return HTTPParser.formatResponse(status: 200, body: jsonBody)
    }

    // MARK: — Protected-resource metadata (`GET /.well-known/oauth-protected-resource`)

    /// RFC 9728. Discovered via the `WWW-Authenticate: ..., resource_metadata=...`
    /// hint on the 401 response from `/mcp`. Tells the client to look for
    /// the actual authorization-server metadata at `authorization_servers[0]`.
    static func protectedResource(issuer: String) -> Data {
        let body = OAuthMetadata.makeProtectedResource(issuer: issuer, resourcePath: MCPProtocol.mcpPath)
        let jsonBody = (try? JSONEncoder().encode(JSONValue.object(body))) ?? Data("{}".utf8)
        return HTTPParser.formatResponse(status: 200, body: jsonBody)
    }

    // MARK: — Dynamic client registration (`POST /register`)

    /// RFC 7591 dynamic client registration. The MCP authorization spec
    /// expects the response to echo back the fields the client sent
    /// (especially `redirect_uris`) so the client knows the server has
    /// accepted them — without that, clients bail before the
    /// authorization request. We're a single-user public-client server,
    /// so we issue a fresh `client_id` for every registration and
    /// accept whatever redirect URI is supplied (the user still has to
    /// click Approve on `/authorize`, so the redirect URI is a UX hint
    /// rather than a trust boundary).
    @MainActor
    static func register(body: Data) -> Data {
        let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let name = parsed["client_name"] as? String
        let (clientID, _) = OAuthStore.shared.registerClient(name: name)

        var payload: [String: JSONValue] = [
            "client_id": .string(clientID),
            "client_id_issued_at": .int(Int64(Date().timeIntervalSince1970)),
            "token_endpoint_auth_method": .string("none"),
            "grant_types": .array([.string("authorization_code")]),
            "response_types": .array([.string("code")])
        ]

        // Echo back the client's metadata so it knows we accepted it.
        // RFC 7591 §3.2.1: the response is "essentially the metadata the
        // client sent" plus the issued `client_id`.
        if let redirects = parsed["redirect_uris"] as? [String] {
            payload["redirect_uris"] = .array(redirects.map { .string($0) })
        }
        if let scope = parsed["scope"] as? String, !scope.isEmpty {
            payload["scope"] = .string(scope)
        }
        if let clientName = name, !clientName.isEmpty {
            payload["client_name"] = .string(clientName)
        }
        if let clientURI = parsed["client_uri"] as? String, !clientURI.isEmpty {
            payload["client_uri"] = .string(clientURI)
        }

        let jsonBody = (try? JSONEncoder().encode(JSONValue.object(payload))) ?? Data("{}".utf8)
        return HTTPParser.formatResponse(status: 201, body: jsonBody)
    }

    // MARK: — Authorize page (`GET /authorize`)

    @MainActor
    static func authorizePage(query: [String: String], clientNameLookup: (String) -> String? = { _ in nil }) -> Data {
        // Validate the well-typed pieces. The MCP spec mandates PKCE-S256.
        guard let responseType = query["response_type"], responseType == "code" else {
            return htmlResponse(status: 400, html: OAuthApprovalPage.renderError(message: "Unsupported response_type. Only 'code' is allowed."))
        }
        guard let clientID = query["client_id"], !clientID.isEmpty else {
            return htmlResponse(status: 400, html: OAuthApprovalPage.renderError(message: "Missing client_id."))
        }
        guard let redirectURI = query["redirect_uri"], isAllowedRedirectURI(redirectURI) else {
            return htmlResponse(status: 400, html: OAuthApprovalPage.renderError(message: "Missing or unsupported redirect_uri. Only http/https schemes are accepted."))
        }
        guard let codeChallenge = query["code_challenge"], !codeChallenge.isEmpty else {
            return htmlResponse(status: 400, html: OAuthApprovalPage.renderError(message: "Missing code_challenge (PKCE is required)."))
        }
        let challengeMethod = query["code_challenge_method"] ?? "S256"
        guard challengeMethod.uppercased() == "S256" else {
            return htmlResponse(status: 400, html: OAuthApprovalPage.renderError(message: "Only S256 code_challenge_method is supported."))
        }

        let ctx = OAuthApprovalPage.Context(
            clientID: clientID,
            clientName: clientNameLookup(clientID),
            redirectURI: redirectURI,
            state: query["state"] ?? "",
            codeChallenge: codeChallenge,
            codeChallengeMethod: challengeMethod,
            scope: query["scope"],
            windowState: OAuthStore.shared.approvalWindowState
        )
        return htmlResponse(status: 200, html: OAuthApprovalPage.render(ctx))
    }

    // MARK: — Approve (`POST /authorize/approve`)

    /// Approves the pending request. Requires the approval window to be
    /// open *now*; otherwise the click is rejected. On success, generates
    /// an authorization code and 302s the browser to
    /// `redirect_uri?code=...&state=...`. Closes the approval window
    /// immediately so a single window grants exactly one code.
    @MainActor
    static func authorizeApprove(form: [String: String]) -> Data {
        guard OAuthStore.shared.approvalWindowIsOpen else {
            return htmlResponse(status: 403, html: OAuthApprovalPage.renderError(
                message: "Approval window not open. Open it in FMail Settings, then start the connector flow again."
            ))
        }
        guard let clientID = form["client_id"],
              let redirectURI = form["redirect_uri"],
              let challenge = form["code_challenge"]
        else {
            return htmlResponse(status: 400, html: OAuthApprovalPage.renderError(
                message: "Approval form was missing required fields."
            ))
        }
        guard isAllowedRedirectURI(redirectURI) else {
            return htmlResponse(status: 400, html: OAuthApprovalPage.renderError(
                message: "redirect_uri scheme not allowed."
            ))
        }
        let method = form["code_challenge_method"] ?? "S256"
        let state = form["state"] ?? ""

        let code = OAuthStore.shared.issueAuthorizationCode(
            challenge: challenge,
            challengeMethod: method,
            redirectURI: redirectURI,
            clientID: clientID
        )
        OAuthStore.shared.closeApprovalWindow()

        let separator = redirectURI.contains("?") ? "&" : "?"
        let location = "\(redirectURI)\(separator)code=\(percentEncode(code))&state=\(percentEncode(state))"
        return HTTPParser.formatResponse(
            status: 302,
            body: Data(),
            extraHeaders: [("Location", location)]
        )
    }

    // MARK: — Deny (`POST /authorize/deny`)

    @MainActor
    static func authorizeDeny(form: [String: String]) -> Data {
        // Per RFC 6749 §4.1.2.1, deny redirects back with `error=access_denied`.
        guard let redirectURI = form["redirect_uri"], isAllowedRedirectURI(redirectURI) else {
            return htmlResponse(status: 400, html: OAuthApprovalPage.renderError(
                message: "Missing or unsupported redirect_uri."
            ))
        }
        let state = form["state"] ?? ""
        let separator = redirectURI.contains("?") ? "&" : "?"
        let location = "\(redirectURI)\(separator)error=access_denied&state=\(percentEncode(state))"
        return HTTPParser.formatResponse(
            status: 302,
            body: Data(),
            extraHeaders: [("Location", location)]
        )
    }

    // MARK: — Token (`POST /token`)

    @MainActor
    static func token(form: [String: String]) -> Data {
        guard form["grant_type"] == "authorization_code" else {
            return errorResponse(status: 400, code: "unsupported_grant_type", description: "Only authorization_code is supported.")
        }
        guard let code = form["code"], !code.isEmpty else {
            return errorResponse(status: 400, code: "invalid_request", description: "Missing code.")
        }
        guard let verifier = form["code_verifier"], !verifier.isEmpty else {
            return errorResponse(status: 400, code: "invalid_request", description: "Missing code_verifier (PKCE is required).")
        }
        guard let redirectURI = form["redirect_uri"] else {
            return errorResponse(status: 400, code: "invalid_request", description: "Missing redirect_uri.")
        }
        guard let clientID = form["client_id"], !clientID.isEmpty else {
            return errorResponse(status: 400, code: "invalid_request", description: "Missing client_id.")
        }

        let result = OAuthStore.shared.exchangeCode(
            code, verifier: verifier, redirectURI: redirectURI, clientID: clientID
        )
        switch result {
        case .success(let accessToken):
            let payload: [String: JSONValue] = [
                "access_token": .string(accessToken),
                "token_type": .string("Bearer"),
                // Matches the server-side soft expiry in
                // `OAuthStore.sessionTTL` — sessions older than this are
                // dropped lazily by `tokenIsValid`. Clients re-auth via
                // the dynamic-registration flow after expiry.
                "expires_in": .int(Int64(OAuthStore.sessionTTL))
            ]
            let jsonBody = (try? JSONEncoder().encode(JSONValue.object(payload))) ?? Data("{}".utf8)
            // OAuth requires Cache-Control: no-store on the token response.
            return HTTPParser.formatResponse(
                status: 200,
                body: jsonBody,
                extraHeaders: [("Cache-Control", "no-store"), ("Pragma", "no-cache")]
            )
        case .failure(let err):
            return errorResponse(status: 400, code: err.code, description: err.description)
        }
    }

    // MARK: — Helpers

    /// Wrap an HTML string in an HTTP response with `Content-Type: text/html`.
    private static func htmlResponse(status: Int, html: String) -> Data {
        let body = Data(html.utf8)
        // Override the default Content-Type via the extraHeaders path — we
        // can't change the existing application/json default, so we patch
        // it after by writing our own response. Simpler: re-emit a small
        // response with the right header inline.
        let statusText = statusText(for: status)
        var header = "HTTP/1.1 \(status) \(statusText)\r\n"
        header += "Content-Type: text/html; charset=utf-8\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"
        var out = Data(header.utf8)
        out.append(body)
        return out
    }

    private static func errorResponse(status: Int, code: String, description: String) -> Data {
        let payload: [String: JSONValue] = [
            "error": .string(code),
            "error_description": .string(description)
        ]
        let body = (try? JSONEncoder().encode(JSONValue.object(payload))) ?? Data("{}".utf8)
        return HTTPParser.formatResponse(status: status, body: body)
    }

    private static func statusText(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default: return "OK"
        }
    }

    private static func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    /// Restrict `redirect_uri` to web schemes (`http`, `https`). Without
    /// this, anyone who can reach `/authorize` can craft a URL whose
    /// approval/deny redirect sends the user to a `javascript:` or
    /// `data:` URI when they click — a small open-redirect surface.
    /// `URL(string:)` alone would accept those.
    static func isAllowedRedirectURI(_ s: String) -> Bool {
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }
}

// MARK: — Query / form-encoded body parsing

enum FormParser {
    /// Parse `application/x-www-form-urlencoded` body content into a
    /// dictionary. Per HTML5 — `+` decodes to space, `%XX` is percent.
    static func parse(_ body: Data) -> [String: String] {
        guard let str = String(data: body, encoding: .utf8) else { return [:] }
        return parseURLEncodedString(str)
    }

    /// Parse a `?a=1&b=2` query string into a dictionary. Strips any
    /// leading `?` if present.
    static func parseQuery(_ raw: String) -> [String: String] {
        var s = raw
        if s.hasPrefix("?") { s.removeFirst() }
        return parseURLEncodedString(s)
    }

    private static func parseURLEncodedString(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard !parts.isEmpty else { continue }
            let key = decode(String(parts[0]))
            let value = parts.count > 1 ? decode(String(parts[1])) : ""
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    private static func decode(_ s: String) -> String {
        let withSpaces = s.replacingOccurrences(of: "+", with: " ")
        return withSpaces.removingPercentEncoding ?? withSpaces
    }
}
