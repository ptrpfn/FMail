import Foundation

/// MCP protocol surface — JSON-RPC 2.0 envelope, error codes, the small
/// `JSONValue` sum type we use to pass arbitrary JSON between the transport
/// layer and tool handlers, plus minimal HTTP/1.1 framing helpers.

enum MCPProtocol {
    /// MCP spec revision we report in `initialize`.
    static let version = "2024-11-05"
    static let serverName = "fmail"
    /// Reported in `initialize` / the GET probe. Read from the bundle so it
    /// can't drift from `CFBundleShortVersionString`.
    static var serverVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }
    static let mcpPath = "/mcp"
}

enum JSONRPCErrorCode {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    /// FMail-specific: index isn't loaded yet (FDA missing, still bootstrapping, ...).
    static let indexNotReady = -32000
}

// MARK: — JSONValue

/// Type-erased JSON tree. Lets handler results / params flow through the
/// transport without binding to a per-method Codable type. Encode/decode
/// uses `JSONEncoder`/`JSONDecoder` directly.
indirect enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.typeMismatch(
            JSONValue.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // MARK: — Convenience accessors used by handlers

    var stringValue: String? {
        if case .string(let s) = self { return s } else { return nil }
    }
    var intValue: Int? {
        switch self {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        default: return nil
        }
    }
    var boolValue: Bool? {
        if case .bool(let b) = self { return b } else { return nil }
    }
    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o } else { return nil }
    }
    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a } else { return nil }
    }
}

// MARK: — JSON-RPC envelope

/// JSON-RPC ids may be int, string, or null (and absent on notifications).
enum JSONRPCID: Sendable, Hashable, Codable {
    case int(Int64)
    case string(String)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.typeMismatch(
            JSONRPCID.self,
            .init(codingPath: decoder.codingPath, debugDescription: "id must be int, string, or null")
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .int(let i): try c.encode(i)
        case .string(let s): try c.encode(s)
        }
    }
}

struct JSONRPCRequest: Sendable, Decodable {
    let jsonrpc: String
    let id: JSONRPCID?  // notifications omit `id`
    let method: String
    let params: JSONValue?
}

/// JSON-RPC error payload. Carried inside the `error` slot of a response.
struct JSONRPCErrorPayload: Sendable, Codable, Error {
    let code: Int
    let message: String
    let data: JSONValue?

    init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// A successful or error response. Custom encoding to ensure exactly one of
/// `result` / `error` is emitted, per the JSON-RPC spec.
struct JSONRPCResponse: Sendable, Encodable {
    let jsonrpc: String
    let id: JSONRPCID?
    let result: JSONValue?
    let error: JSONRPCErrorPayload?

    static func success(id: JSONRPCID?, result: JSONValue) -> JSONRPCResponse {
        JSONRPCResponse(jsonrpc: "2.0", id: id, result: result, error: nil)
    }

    static func failure(id: JSONRPCID?, error: JSONRPCErrorPayload) -> JSONRPCResponse {
        JSONRPCResponse(jsonrpc: "2.0", id: id, result: nil, error: error)
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jsonrpc, forKey: .jsonrpc)
        switch id {
        case .some(let id): try c.encode(id, forKey: .id)
        case .none: try c.encodeNil(forKey: .id)
        }
        if let error = error {
            try c.encode(error, forKey: .error)
        } else {
            try c.encode(result ?? .null, forKey: .result)
        }
    }
}

// MARK: — HTTP/1.1 framing

struct HTTPRequestLine: Sendable {
    let method: String
    /// Path *without* the query string — e.g. `/authorize` for an incoming
    /// `GET /authorize?response_type=code&...`. Use `query` for the raw
    /// query, parsed via `FormParser.parseQuery`.
    let path: String
    /// Raw query string, *without* the leading `?`. Empty when no `?`
    /// was present in the request line.
    let query: String
    /// Lowercased keys, last-wins on duplicates. Sufficient for the headers
    /// we care about (`Authorization`, `Content-Length`).
    let headers: [String: String]
    let body: Data
}

enum HTTPParseError: Error, CustomStringConvertible {
    case malformed(String)

    var description: String {
        if case .malformed(let m) = self { return "malformed HTTP: \(m)" }
        return "malformed HTTP"
    }
}

enum HTTPParser {
    /// Try to parse a complete HTTP request from `data`.
    /// - Returns: `(parsed, totalBytesConsumed)` on success.
    ///   `nil` when more bytes are needed.
    /// - Throws: `HTTPParseError` on malformed requests.
    static func parse(_ data: Data) throws -> (HTTPRequestLine, Int)? {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])  // \r\n\r\n
        guard let endRange = data.range(of: separator) else { return nil }

        let headerData = data.prefix(upTo: endRange.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .ascii) else {
            throw HTTPParseError.malformed("non-ASCII headers")
        }
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw HTTPParseError.malformed("empty request")
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            throw HTTPParseError.malformed("bad request line: \(requestLine)")
        }
        let method = parts[0]
        let rawTarget = parts[1]
        let pathSeparator = rawTarget.firstIndex(of: "?")
        let path = pathSeparator.map { String(rawTarget[..<$0]) } ?? rawTarget
        let query = pathSeparator.map { String(rawTarget[rawTarget.index(after: $0)...]) } ?? ""

        var headers: [String: String] = [:]
        var contentLength = 0
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colonIdx]).lowercased()
            let value = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
            headers[key] = String(value)
            if key == "content-length" {
                // Negative or non-numeric → treat as 0 (the parser will
                // return an empty body). A negative value would otherwise
                // produce `bodyEnd < bodyStart` and crash `subdata(in:)`.
                let parsed = Int(value) ?? 0
                contentLength = max(0, min(parsed, Self.maxBodyBytes))
            }
        }

        let bodyStart = endRange.upperBound
        let bodyEnd = bodyStart + contentLength
        if bodyEnd < bodyStart { return nil }  // overflow defence
        if data.count < bodyEnd { return nil }
        let body = data.subdata(in: bodyStart..<bodyEnd)
        return (HTTPRequestLine(method: method, path: path, query: query, headers: headers, body: body), bodyEnd)
    }

    /// Hard cap on Content-Length we'll honour from a request header.
    /// The transport layer also enforces a per-connection read cap
    /// (`MCPServer.maxRequestBytes`); this is a second-line guard so a
    /// malicious header can't push `bodyEnd` past `Int.max`.
    static let maxBodyBytes = 32 * 1024 * 1024  // 32 MB

    /// Format an HTTP/1.1 response with `Connection: close`. Defaults to a
    /// JSON content type; pass `contentType` for other bodies (e.g.
    /// `"text/html; charset=utf-8"` for the OAuth approval page).
    /// `extraHeaders` adds key/value pairs verbatim (e.g.
    /// `["WWW-Authenticate": "Bearer"]` on 401 responses).
    static func formatResponse(
        status: Int = 200,
        body: Data,
        contentType: String = "application/json",
        extraHeaders: [(String, String)] = []
    ) -> Data {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 201: statusText = "Created"
        case 202: statusText = "Accepted"
        case 204: statusText = "No Content"
        case 302: statusText = "Found"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        case 500: statusText = "Internal Server Error"
        default: statusText = "OK"
        }
        var header =
            "HTTP/1.1 \(status) \(statusText)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n"
        for (k, v) in extraHeaders {
            header += "\(k): \(v)\r\n"
        }
        header += "\r\n"
        var out = Data(header.utf8)
        out.append(body)
        return out
    }
}
