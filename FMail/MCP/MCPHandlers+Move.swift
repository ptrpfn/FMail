import Foundation

/// `delete_messages` and `move_to_junk` MCP handlers. Both follow the same
/// validate → thunk → result-shape pattern; the only difference is which
/// thunk on `MCPContext` they invoke.
extension MCPHandlers {

    static func deleteMessages(_ args: JSONValue, context: MCPContext) async throws -> JSONValue {
        try await runMoveHandler(
            args: args,
            handler: context.deleteHandler,
            tool: "delete_messages"
        )
    }

    static func moveToJunk(_ args: JSONValue, context: MCPContext) async throws -> JSONValue {
        try await runMoveHandler(
            args: args,
            handler: context.junkHandler,
            tool: "move_to_junk"
        )
    }

    private static func runMoveHandler(
        args: JSONValue,
        handler: MCPMoveHandler?,
        tool: String
    ) async throws -> JSONValue {
        guard let obj = args.objectValue,
              let rowidsRaw = obj["rowids"]?.arrayValue
        else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "\(tool): `rowids` (array of integers) is required"
            )
        }
        let rowids = rowidsRaw.compactMap { $0.intValue }
        guard rowids.count == rowidsRaw.count else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "\(tool): `rowids` must contain integers only"
            )
        }
        guard !rowids.isEmpty else {
            return try JSONValue.encoding(MarkReadResult(applied: 0, error: nil))
        }
        guard let handler else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.indexNotReady,
                message: "\(tool): write thunk not wired (FMail UI may not be loaded)"
            )
        }
        let result = await handler(rowids)
        return try JSONValue.encoding(MarkReadResult(applied: result.applied, error: result.error))
    }
}
