import Foundation

/// Dependencies an MCP handler needs. The shape stays small so handlers
/// don't reach into MainActor-only state — everything they touch is actor-
/// isolated and Sendable. The MCP surface is read-only by design; there
/// are no write thunks here.
struct MCPContext: Sendable {
    let indexDB: IndexDB
    let bodyLoader: BodyLoader

    init(indexDB: IndexDB, bodyLoader: BodyLoader) {
        self.indexDB = indexDB
        self.bodyLoader = bodyLoader
    }
}

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
        let limit = MCPHelpers.clampInt(obj["limit"]?.intValue ?? 50, min: 1, max: 500)
        let sort = try SearchSort.parseStrict(obj["sort"]?.stringValue)
        let includeAttachments = obj["include_attachment_metadata"]?.boolValue ?? false

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

        let messages = try await context.indexDB.search(compiledQ, limit: limit, sort: sort)
        let rowids = messages.map(\.rowId)
        let enrichments = try await context.indexDB.enrichForMCP(rowids: rowids)

        // Optional pass to load per-message attachment metadata. Costs
        // one body-load per result row; gated to avoid blowing up
        // payload size on 100-row searches.
        //
        // We distinguish three states on each result row:
        //   - `attachments: nil`     → caller didn't request metadata
        //   - `attachments: []`      → caller asked AND we successfully
        //                              determined the message has none
        //   - `attachments_unavailable: true` → load failed (body not on
        //                              disk yet, etc.); the LLM should
        //                              not interpret missing as "none"
        var attachmentsByRowid: [Int: [AttachmentRef]] = [:]
        var attachmentsUnavailable: Set<Int> = []
        if includeAttachments {
            for m in messages {
                guard let mb = try? await context.indexDB.loadMailbox(rowid: m.mailboxRowId),
                      let body = try? await context.bodyLoader.loadBody(messageRowId: m.rowId, mailbox: mb)
                else {
                    attachmentsUnavailable.insert(m.rowId)
                    continue
                }
                attachmentsByRowid[m.rowId] = body.attachments.map {
                    AttachmentRef(name: $0.name, content_type: $0.contentType, byte_count: $0.data.count, locally_available: !$0.data.isEmpty)
                }
            }
        }

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
                account_email: e?.accountEmail,
                is_read: m.isRead,
                is_flagged: m.isFlagged,
                has_attachment: e?.hasAttachment ?? false,
                thread_id: e?.threadId ?? m.rowId,
                rfc_message_id: m.rfcMessageId,
                body_on_disk: e?.bodyOnDisk ?? false,
                attachments: attachmentsByRowid[m.rowId],
                attachments_unavailable: attachmentsUnavailable.contains(m.rowId) ? true : nil
            )
        }
        return try JSONValue.encoding(SearchEmailsResult(results: refs))
    }

    // MARK: — list_accounts

    static func listAccounts(_ args: JSONValue, context: MCPContext) async throws -> JSONValue {
        _ = args
        let accounts = try await context.indexDB.loadAccounts()
        let refs = accounts.map {
            AccountRef(uuid: $0.uuid, display_name: $0.displayName, email_address: $0.emailAddress)
        }
        return try JSONValue.encoding(ListAccountsResult(accounts: refs))
    }

    // MARK: — list_threads

    static func listThreads(_ args: JSONValue, context: MCPContext) async throws -> JSONValue {
        let obj = args.objectValue ?? [:]
        let limit = MCPHelpers.clampInt(obj["limit"]?.intValue ?? 100, min: 1, max: 600)
        let unreadOnly = obj["unread_only"]?.boolValue ?? false

        // since/until are post-filtered in Swift since loadAllThreadSummaries /
        // loadThreadSummaries don't accept date predicates. Fine at limit ≤ 600.
        let sinceDate = try obj["since"]?.stringValue.flatMap { try requireValidDate($0, field: "since") }
        let untilDate = try obj["until"]?.stringValue.flatMap { try requireValidDate($0, field: "until") }

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
        let maxBodyChars = MCPHelpers.clampInt(obj["max_body_chars"]?.intValue ?? 8000, min: 0, max: 200_000)
        let bodyFormat = try BodyFormat.parseStrict(obj["body_format"]?.stringValue)
        // 0 = no cap. Clamped to a sane max (1 MB) so a malicious caller
        // can't ask for the moon.
        let maxTotalChars = MCPHelpers.clampInt(obj["max_total_chars"]?.intValue ?? 0, min: 0, max: 1_000_000)
        let direction = try ThreadDirection.parseStrict(obj["direction"]?.stringValue)

        let messages = try await context.indexDB.loadThreadMessages(threadId: threadId, scope: .excludeDrafts)
        var full = try await buildEmailFulls(
            for: messages,
            includeBodies: includeBodies,
            maxBodyChars: maxBodyChars,
            bodyFormat: bodyFormat,
            context: context
        )

        // Apply direction. `messages` comes back chronological from the
        // index; flip when newest-first requested.
        if direction == .newestFirst {
            full.reverse()
        }

        // Apply total-budget truncation. Keep messages in the iteration
        // order set above (so newest-first prioritises latest, oldest-
        // first prioritises earliest). Drop overflow from the tail.
        var omittedCount = 0
        if maxTotalChars > 0 {
            var runningTotal = 0
            var kept: [EmailFull] = []
            kept.reserveCapacity(full.count)
            for msg in full {
                let nextTotal = runningTotal + msg.plain_text_body.count
                if nextTotal > maxTotalChars && !kept.isEmpty {
                    omittedCount = full.count - kept.count
                    break
                }
                kept.append(msg)
                runningTotal = nextTotal
            }
            full = kept
        }

        return try JSONValue.encoding(GetThreadResult(
            messages: full,
            omitted_message_count: omittedCount > 0 ? omittedCount : nil
        ))
    }

    // MARK: — get_email

    static func getEmail(_ args: JSONValue, context: MCPContext) async throws -> JSONValue {
        guard let obj = args.objectValue,
              let rowid = obj["rowid"]?.intValue
        else {
            throw JSONRPCErrorPayload(code: JSONRPCErrorCode.invalidParams, message: "get_email: `rowid` (integer) is required")
        }
        let maxBodyChars = MCPHelpers.clampInt(obj["max_body_chars"]?.intValue ?? 8000, min: 0, max: 200_000)
        let bodyFormat = try BodyFormat.parseStrict(obj["body_format"]?.stringValue)

        guard let msg = try await context.indexDB.loadMessage(rowid: rowid) else {
            throw JSONRPCErrorPayload(code: JSONRPCErrorCode.invalidParams, message: "get_email: no message with rowid \(rowid)")
        }
        let full = try await buildEmailFulls(
            for: [msg],
            includeBodies: true,
            maxBodyChars: maxBodyChars,
            bodyFormat: bodyFormat,
            context: context
        )
        guard let one = full.first else {
            throw JSONRPCErrorPayload(code: JSONRPCErrorCode.internalError, message: "get_email: failed to build EmailFull")
        }
        return try JSONValue.encoding(one)
    }

    // (find_unanswered_threads lives in MCPHandlers+Unanswered.swift.)

    // MARK: — Internals

    /// Build `EmailFull` for each message, optionally fetching bodies.
    /// Looks up each message's home mailbox individually (Gmail labels can
    /// put thread members in different mailboxes).
    ///
    /// `maxBodyChars` semantics:
    ///   0  → headers + attachment list only, plain_text_body is empty
    ///        (still triggers a body load to enumerate attachments)
    ///   N  → truncate plain text to N chars; `plain_text_truncated`
    ///        indicates whether content was cut
    /// `includeBodies=false` skips body parsing entirely (no attachments
    /// list, no plainText). Cheapest option for summary listings.
    ///
    /// `bodyFormat`:
    ///   .plain  → the HTML-stripped text as produced by `HTMLStripper`
    ///             (the historical default).
    ///   .clean  → additionally pass through `BodyCleaner`: truncate at
    ///             the first reply-chain marker and signature delimiter,
    ///             collapse known tracking-URL wrappers, collapse blank
    ///             lines. Designed for context-window-sensitive callers
    ///             pulling long threads.
    ///   .raw    → same as `.plain` for now (placeholder for if/when we
    ///             expose the original HTML in the future).
    static func buildEmailFulls(
        for messages: [MessageHeader],
        includeBodies: Bool,
        maxBodyChars: Int,
        bodyFormat: BodyFormat = .plain,
        context: MCPContext
    ) async throws -> [EmailFull] {
        let rowids = messages.map(\.rowId)
        let enrichments = try await context.indexDB.enrichForMCP(rowids: rowids)
        // Reply-chain lookup: per rowid → rowid of in-reply-to message.
        // One SQL for the whole set, joined to messages_links.
        let inReplyTo = (try? await context.indexDB.inReplyToRowids(rowids)) ?? [:]

        // Cache mailbox lookups within this call (a thread often shares one).
        var mailboxCache: [Int: Mailbox?] = [:]
        var out: [EmailFull] = []
        out.reserveCapacity(messages.count)

        for m in messages {
            let recipients = (try? await context.indexDB.loadRecipients(messageRowId: m.rowId)) ?? []
            let to = recipients.filter { $0.kind == RecipientKind.to.rawValue }.map(\.address)
            let cc = recipients.filter { $0.kind == RecipientKind.cc.rawValue }.map(\.address)
            let bcc = recipients.filter { $0.kind == RecipientKind.bcc.rawValue }.map(\.address)

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
                    let processed = Self.processBody(body, format: bodyFormat, maxBodyChars: maxBodyChars)
                    plainText = processed.text
                    truncated = processed.truncated
                    fullChars = processed.fullChars
                    htmlPresent = processed.htmlPresent
                    attachments = processed.attachments
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
                account_email: e?.accountEmail,
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
                in_reply_to_rowid: inReplyTo[m.rowId],
                body_on_disk: e?.bodyOnDisk ?? false,
                plain_text_body: plainText,
                plain_text_truncated: truncated,
                plain_text_full_chars: fullChars,
                html_body_present: htmlPresent,
                attachments: attachments
            ))
        }
        return out
    }

    /// Result of cleaning + truncating one loaded body for an `EmailFull`.
    private struct ProcessedBody {
        let text: String
        let truncated: Bool
        let fullChars: Int
        let htmlPresent: Bool
        let attachments: [AttachmentRef]
    }

    /// Apply the `body_format` pass, then truncate to `maxBodyChars`
    /// (0 = headers/attachments only). The cleaned length is what budgets
    /// work against, so `fullChars` is the post-clean character count.
    private static func processBody(
        _ body: MessageBody, format: BodyFormat, maxBodyChars: Int
    ) -> ProcessedBody {
        let processed: String
        switch format {
        case .clean: processed = BodyCleaner.clean(body.displayText)
        case .plain, .raw: processed = body.displayText
        }
        let text: String
        let truncated: Bool
        if maxBodyChars == 0 {
            text = ""
            truncated = processed.count > 0
        } else if processed.count > maxBodyChars {
            text = String(processed.prefix(maxBodyChars))
            truncated = true
        } else {
            text = processed
            truncated = false
        }
        return ProcessedBody(
            text: text,
            truncated: truncated,
            fullChars: processed.count,
            htmlPresent: body.html != nil && !(body.html ?? "").isEmpty,
            attachments: body.attachments.map {
                AttachmentRef(name: $0.name, content_type: $0.contentType, byte_count: $0.data.count, locally_available: !$0.data.isEmpty)
            }
        )
    }
}

// MARK: — Helpers

/// Parse a date supplied by the client; throw an `invalidParams` error
/// when the string is non-empty but unparseable so callers don't silently
/// degrade to nil (and skip the filter entirely).
private func requireValidDate(_ s: String, field: String) throws -> Date? {
    guard !s.isEmpty else { return nil }
    guard let date = MCPHelpers.parseISODate(s) else {
        throw JSONRPCErrorPayload(
            code: JSONRPCErrorCode.invalidParams,
            message: "\(field): expected ISO date (YYYY, YYYY-MM, or YYYY-MM-DD), got \"\(s)\""
        )
    }
    return date
}
