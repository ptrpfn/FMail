import Foundation

/// Dependencies an MCP handler needs. The shape stays small so handlers
/// don't reach into MainActor-only state — everything they touch is actor-
/// isolated and Sendable.
struct MCPContext: Sendable {
    let indexDB: IndexDB
    let bodyLoader: BodyLoader
    /// Optional write thunks. Nil means the matching tool is unavailable.
    let markReadHandler: MCPMarkReadHandler?
    let deleteHandler: MCPMoveHandler?
    let junkHandler: MCPMoveHandler?

    init(
        indexDB: IndexDB,
        bodyLoader: BodyLoader,
        markReadHandler: MCPMarkReadHandler? = nil,
        deleteHandler: MCPMoveHandler? = nil,
        junkHandler: MCPMoveHandler? = nil
    ) {
        self.indexDB = indexDB
        self.bodyLoader = bodyLoader
        self.markReadHandler = markReadHandler
        self.deleteHandler = deleteHandler
        self.junkHandler = junkHandler
    }
}

/// `@Sendable` thunk that performs `mark_read` on behalf of the MCP handler,
/// returning the count applied and an optional error string. Wired in
/// MailModel.applyMCPSettings so the MCP layer doesn't need to know about
/// MainActor / ReadStatusController directly.
typealias MCPMarkReadHandler = @Sendable (_ rowids: [Int], _ isRead: Bool) async -> (applied: Int, error: String?)

/// `@Sendable` thunk for `delete_messages` and `move_to_junk` — same shape,
/// only the underlying AppleScript action differs.
typealias MCPMoveHandler = @Sendable (_ rowids: [Int]) async -> (applied: Int, error: String?)

/// One async function per tool. Each validates input, calls into context,
/// and returns a JSON tree that the dispatcher will JSON-encode into the
/// `text` field of an MCP content block.
enum MCPHandlers {

    // MARK: — search_emails

    static func searchEmails(_ args: JSONValue, context: MCPContext) async throws -> JSONValue {
        guard let obj = args.objectValue else {
            throw JSONRPCErrorPayload(code: JSONRPCErrorCode.invalidParams, message: "search_emails: arguments must be an object")
        }
        guard let rawQuery = obj["query"]?.stringValue, !rawQuery.isEmpty else {
            throw JSONRPCErrorPayload(code: JSONRPCErrorCode.invalidParams, message: "search_emails: `query` is required")
        }
        let limit = clampInt(obj["limit"]?.intValue ?? 50, min: 1, max: 500)

        // Optional since/until — fold into the DSL by prefixing with after:/before:.
        var compiled = rawQuery
        if let since = obj["since"]?.stringValue, !since.isEmpty {
            compiled = "after:\(since) " + compiled
        }
        if let until = obj["until"]?.stringValue, !until.isEmpty {
            compiled = "before:\(until) " + compiled
        }

        let ast = QueryParser.parse(compiled)
        let compiledQ = Evaluator.compile(ast)
        guard compiledQ.hasAnyConstraint else {
            return try JSONValue.encoding(SearchEmailsResult(results: []))
        }

        let messages = try await context.indexDB.search(compiledQ, limit: limit)
        let rowids = messages.map(\.rowId)
        let enrichments = try await context.indexDB.enrichForMCP(rowids: rowids)

        let refs = messages.map { m -> EmailRef in
            let e = enrichments[m.rowId]
            return EmailRef(
                rowid: m.rowId,
                subject: m.subject,
                sender_display: m.senderDisplay,
                sender_address: m.senderAddress,
                date_sent: m.dateSent.mcpISO8601(),
                date_received: m.dateReceived.mcpISO8601(),
                mailbox_path: e?.mailboxPath ?? "",
                is_read: m.isRead,
                is_flagged: m.isFlagged,
                has_attachment: e?.hasAttachment ?? false,
                thread_id: e?.threadId ?? m.rowId
            )
        }
        return try JSONValue.encoding(SearchEmailsResult(results: refs))
    }

    // MARK: — list_threads

    static func listThreads(_ args: JSONValue, context: MCPContext) async throws -> JSONValue {
        let obj = args.objectValue ?? [:]
        let limit = clampInt(obj["limit"]?.intValue ?? 100, min: 1, max: 600)
        let unreadOnly = obj["unread_only"]?.boolValue ?? false

        // since/until are post-filtered in Swift since loadAllThreadSummaries /
        // loadThreadSummaries don't accept date predicates. Fine at limit ≤ 600.
        let sinceDate = obj["since"]?.stringValue.flatMap(parseISODate)
        let untilDate = obj["until"]?.stringValue.flatMap(parseISODate)

        let summaries: [ThreadSummary]
        switch obj["scope"] {
        case .some(.string("all_mailboxes")), .none:
            summaries = try await context.indexDB.loadAllThreadSummaries(limit: limit)
        case .some(.object(let scopeObj)):
            guard let mailboxRowId = scopeObj["mailbox_rowid"]?.intValue else {
                throw JSONRPCErrorPayload(code: JSONRPCErrorCode.invalidParams, message: "list_threads: scope.mailbox_rowid must be an integer")
            }
            summaries = try await context.indexDB.loadThreadSummaries(mailboxRowId: mailboxRowId, limit: limit)
        case .some(let other):
            throw JSONRPCErrorPayload(code: JSONRPCErrorCode.invalidParams, message: "list_threads: invalid scope: \(other)")
        }

        let filtered = summaries.filter { s in
            if unreadOnly, s.unreadCount == 0 { return false }
            if let sinceDate, let d = s.latestDateReceived, d < sinceDate { return false }
            if let untilDate, let d = s.latestDateReceived, d > untilDate { return false }
            return true
        }

        let refs = filtered.map { s in
            ThreadRef(
                thread_id: s.threadId,
                latest_subject: s.latestSubject,
                latest_sender_display: s.latestSenderDisplay,
                latest_date_received: s.latestDateReceived.mcpISO8601(),
                message_count: s.messageCount,
                unread_count: s.unreadCount,
                flagged_count: s.flaggedCount,
                latest_is_outgoing: s.latestIsOutgoing
            )
        }
        return try JSONValue.encoding(ListThreadsResult(threads: refs))
    }

    // MARK: — get_thread

    static func getThread(_ args: JSONValue, context: MCPContext) async throws -> JSONValue {
        guard let obj = args.objectValue,
              let threadId = obj["thread_id"]?.intValue
        else {
            throw JSONRPCErrorPayload(code: JSONRPCErrorCode.invalidParams, message: "get_thread: `thread_id` (integer) is required")
        }
        let includeBodies = obj["include_bodies"]?.boolValue ?? true
        let maxBodyChars = clampInt(obj["max_body_chars"]?.intValue ?? 8000, min: 0, max: 200_000)

        let messages = try await context.indexDB.loadThreadMessages(threadId: threadId, scope: .excludeDrafts)
        let full = try await buildEmailFulls(
            for: messages,
            includeBodies: includeBodies,
            maxBodyChars: maxBodyChars,
            context: context
        )
        return try JSONValue.encoding(GetThreadResult(messages: full))
    }

    // MARK: — get_email

    static func getEmail(_ args: JSONValue, context: MCPContext) async throws -> JSONValue {
        guard let obj = args.objectValue,
              let rowid = obj["rowid"]?.intValue
        else {
            throw JSONRPCErrorPayload(code: JSONRPCErrorCode.invalidParams, message: "get_email: `rowid` (integer) is required")
        }
        let maxBodyChars = clampInt(obj["max_body_chars"]?.intValue ?? 8000, min: 0, max: 200_000)

        guard let msg = try await context.indexDB.loadMessage(rowid: rowid) else {
            throw JSONRPCErrorPayload(code: JSONRPCErrorCode.invalidParams, message: "get_email: no message with rowid \(rowid)")
        }
        let full = try await buildEmailFulls(
            for: [msg],
            includeBodies: true,
            maxBodyChars: maxBodyChars,
            context: context
        )
        guard let one = full.first else {
            throw JSONRPCErrorPayload(code: JSONRPCErrorCode.internalError, message: "get_email: failed to build EmailFull")
        }
        return try JSONValue.encoding(one)
    }

    // (find_unanswered_threads and mark_read live in MCPHandlers+A3.swift,
    //  added in Phase A3 once the SQL helper and write thunk exist.)

    // MARK: — Internals

    /// Build `EmailFull` for each message, optionally fetching bodies.
    /// Looks up each message's home mailbox individually (Gmail labels can
    /// put thread members in different mailboxes).
    private static func buildEmailFulls(
        for messages: [MessageHeader],
        includeBodies: Bool,
        maxBodyChars: Int,
        context: MCPContext
    ) async throws -> [EmailFull] {
        let rowids = messages.map(\.rowId)
        let enrichments = try await context.indexDB.enrichForMCP(rowids: rowids)

        // Cache mailbox lookups within this call (a thread often shares one).
        var mailboxCache: [Int: Mailbox?] = [:]
        var out: [EmailFull] = []
        out.reserveCapacity(messages.count)

        for m in messages {
            let recipients = (try? await context.indexDB.loadRecipients(messageRowId: m.rowId)) ?? []
            let to = recipients.filter { $0.kind == 0 }.map(\.address)
            let cc = recipients.filter { $0.kind == 1 }.map(\.address)
            let bcc = recipients.filter { $0.kind == 2 }.map(\.address)

            var plainText = ""
            var htmlPresent = false
            var attachments: [AttachmentRef] = []
            var truncated = false
            var fullChars = 0

            if includeBodies {
                let mb: Mailbox?
                if let cached = mailboxCache[m.mailboxRowId] {
                    mb = cached
                } else {
                    mb = try? await context.indexDB.loadMailbox(rowid: m.mailboxRowId)
                    mailboxCache[m.mailboxRowId] = mb
                }
                if let mb,
                   let body = try? await context.bodyLoader.loadBody(messageRowId: m.rowId, mailbox: mb) {
                    let displayText = body.displayText
                    fullChars = displayText.count
                    htmlPresent = body.html != nil && !(body.html ?? "").isEmpty
                    if maxBodyChars > 0 && displayText.count > maxBodyChars {
                        plainText = String(displayText.prefix(maxBodyChars))
                        truncated = true
                    } else {
                        plainText = displayText
                    }
                    attachments = body.attachments.map { a in
                        AttachmentRef(
                            name: a.name,
                            content_type: a.contentType,
                            byte_count: a.data.count
                        )
                    }
                }
                // body == nil happens when Mail.app fetched only the header.
                // We don't trigger an AppleScript fetch here — that's a 5–10s
                // round-trip per message and the UI handles it differently.
            }

            let e = enrichments[m.rowId]
            out.append(EmailFull(
                rowid: m.rowId,
                thread_id: e?.threadId ?? m.rowId,
                mailbox_path: e?.mailboxPath ?? "",
                subject: m.subject,
                sender_display: m.senderDisplay,
                sender_address: m.senderAddress,
                to: to,
                cc: cc,
                bcc: bcc,
                date_sent: m.dateSent.mcpISO8601(),
                date_received: m.dateReceived.mcpISO8601(),
                is_read: m.isRead,
                is_flagged: m.isFlagged,
                rfc_message_id: m.rfcMessageId,
                plain_text_body: plainText,
                plain_text_truncated: truncated,
                plain_text_full_chars: fullChars,
                html_body_present: htmlPresent,
                attachments: attachments
            ))
        }
        return out
    }
}

// MARK: — Helpers

private func clampInt(_ v: Int, min lo: Int, max hi: Int) -> Int {
    Swift.max(lo, Swift.min(hi, v))
}

/// Parse YYYY, YYYY-MM, or YYYY-MM-DD as a Date at start-of-period UTC.
/// Returns nil for anything else.
private func parseISODate(_ s: String) -> Date? {
    var components = DateComponents()
    components.timeZone = TimeZone(identifier: "UTC")
    let parts = s.split(separator: "-").map(String.init)
    guard let y = parts.first.flatMap(Int.init) else { return nil }
    components.year = y
    components.month = parts.count >= 2 ? Int(parts[1]) : 1
    components.day = parts.count >= 3 ? Int(parts[2]) : 1
    return Calendar(identifier: .gregorian).date(from: components)
}
