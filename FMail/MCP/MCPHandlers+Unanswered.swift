import Foundation

/// `find_unanswered_threads` — threads where the user sent the latest
/// message and hasn't heard back. Read-only.
extension MCPHandlers {

    static func findUnansweredThreads(_ args: JSONValue, context: MCPContext) async throws -> JSONValue {
        guard let obj = args.objectValue,
              let sinceStr = obj["since"]?.stringValue, !sinceStr.isEmpty
        else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "find_unanswered_threads: `since` (ISO date YYYY-MM-DD or YYYY-MM or YYYY) is required"
            )
        }
        guard let since = MCPHelpers.parseISODate(sinceStr) else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "find_unanswered_threads: `since` must be ISO YYYY-MM-DD / YYYY-MM / YYYY — got \"\(sinceStr)\""
            )
        }
        let limit = MCPHelpers.clampInt(obj["limit"]?.intValue ?? 50, min: 1, max: 500)
        let ourAddress = obj["our_address"]?.stringValue

        let rows = try await context.indexDB.findUnansweredThreads(
            since: since,
            ourAddress: ourAddress,
            limit: limit
        )
        return try JSONValue.encoding(FindUnansweredThreadsResult(threads: rows))
    }
}
