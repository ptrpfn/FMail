import Foundation

/// Tool registry + JSON-RPC method dispatcher for the MCP server.
/// Stateless apart from the registered tools — connection handling lives in
/// `MCPServer`. The registry starts empty; `MCPTools.registerReadTools`
/// populates it once per server start.
actor MCPDispatcher {
    private var tools: [String: MCPTool] = [:]

    func register(_ tool: MCPTool) {
        tools[tool.name] = tool
    }

    func registeredToolNames() -> [String] {
        tools.keys.sorted()
    }

    /// Dispatch a raw HTTP body containing a JSON-RPC request.
    /// Returns either a JSON response (for requests) or a notification ack
    /// (for notifications — caller maps to HTTP 202).
    func dispatch(rawBody: Data) async -> MCPDispatchResult {
        // Decode envelope
        let req: JSONRPCRequest
        do {
            req = try JSONDecoder().decode(JSONRPCRequest.self, from: rawBody)
        } catch {
            // No id — emit a parse-error response with id: null
            let resp = JSONRPCResponse.failure(
                id: .null,
                error: JSONRPCErrorPayload(
                    code: JSONRPCErrorCode.parseError,
                    message: "Parse error: \(error.localizedDescription)"
                )
            )
            return .response(encode(resp))
        }

        // Notifications: id absent → no response (HTTP 202).
        if req.id == nil {
            // Currently the only notification we expect is `notifications/initialized`.
            // We don't need to do anything with it.
            return .notification
        }

        let id = req.id ?? .null
        do {
            let result: JSONValue
            switch req.method {
            case "initialize":
                result = handleInitialize(req.params)
            case "ping":
                result = .object([:])
            case "tools/list":
                result = handleToolsList()
            case "tools/call":
                result = try await handleToolsCall(req.params)
            default:
                throw JSONRPCErrorPayload(
                    code: JSONRPCErrorCode.methodNotFound,
                    message: "Method not found: \(req.method)"
                )
            }
            return .response(encode(JSONRPCResponse.success(id: id, result: result)))
        } catch let payload as JSONRPCErrorPayload {
            return .response(encode(JSONRPCResponse.failure(id: id, error: payload)))
        } catch {
            // Log the full Swift error (with type info) locally; ship
            // only the localized description to the wire so Swift type
            // names don't leak to clients.
            Log.mcp.error("MCP internal error on \(req.method, privacy: .public): \(String(describing: error), privacy: .public)")
            return .response(encode(JSONRPCResponse.failure(
                id: id,
                error: JSONRPCErrorPayload(
                    code: JSONRPCErrorCode.internalError,
                    message: error.localizedDescription
                )
            )))
        }
    }

    // MARK: — Method handlers

    private func handleInitialize(_ params: JSONValue?) -> JSONValue {
        // We advertise tools support but no listChanged events (the registry
        // is fixed at app boot).
        .object([
            "protocolVersion": .string(MCPProtocol.version),
            "capabilities": .object([
                "tools": .object(["listChanged": .bool(false)])
            ]),
            "serverInfo": .object([
                "name": .string(MCPProtocol.serverName),
                "version": .string(MCPProtocol.serverVersion)
            ])
        ])
    }

    private func handleToolsList() -> JSONValue {
        let entries: [JSONValue] = tools.values
            .sorted(by: { $0.name < $1.name })
            .map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "inputSchema": tool.inputSchema
                ])
            }
        return .object(["tools": .array(entries)])
    }

    private func handleToolsCall(_ params: JSONValue?) async throws -> JSONValue {
        guard let obj = params?.objectValue,
              let name = obj["name"]?.stringValue
        else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "tools/call requires `name`"
            )
        }
        let arguments = obj["arguments"] ?? .object([:])
        guard let tool = tools[name] else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.methodNotFound,
                message: "Unknown tool: \(name)"
            )
        }

        let result: JSONValue
        do {
            result = try await tool.handler(arguments)
        } catch let payload as JSONRPCErrorPayload {
            // Structured tool error → JSON-RPC error envelope (visible as an
            // exception to the LLM client).
            throw payload
        } catch {
            // Tool threw something unexpected — wrap as an `isError: true`
            // content block per MCP convention. The client can read it but
            // it doesn't fail the whole RPC.
            return .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("Error: \(error)")
                    ])
                ]),
                "isError": .bool(true)
            ])
        }

        // Wrap the result as a single text content block whose text is the
        // JSON-encoded result. This is the documented MCP convention; LLM
        // clients parse this back automatically.
        let resultJSON: String
        do {
            let data = try JSONEncoder().encode(result)
            resultJSON = String(data: data, encoding: .utf8) ?? "null"
        } catch {
            resultJSON = "null"
        }
        return .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(resultJSON)
                ])
            ]),
            "isError": .bool(false)
        ])
    }

    // MARK: — Helpers

    private func encode(_ resp: JSONRPCResponse) -> Data {
        do {
            return try JSONEncoder().encode(resp)
        } catch {
            // Fall back to a minimal error envelope; should never happen.
            return Data(
                #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"encode failed"}}"#.utf8
            )
        }
    }
}

/// One registered tool: name, description (the LLM sees this), input JSON
/// Schema, and the async handler that produces its result.
struct MCPTool: Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue
    let handler: @Sendable (JSONValue) async throws -> JSONValue
}

enum MCPDispatchResult: Sendable {
    /// A JSON-RPC response envelope to send back as HTTP 200.
    case response(Data)
    /// A JSON-RPC notification — no response (HTTP 202 with empty body).
    case notification
}
