import Foundation

/// Tool registry — wires tool names + descriptions + JSON Schemas to their
/// handler implementations in `MCPHandlers`. Registration happens once per
/// MCP server start.
///
/// Each tool's `description` is what the LLM sees in `tools/list`. Be
/// pragmatic, not poetic. The `search_emails` description embeds the FMail
/// DSL grammar so the LLM can compose queries without external knowledge.
enum MCPTools {
    /// Register Phase A2 read tools. Phase A3 also calls
    /// `registerUnansweredAndMarkReadTools`.
    static func registerReadTools(on dispatcher: MCPDispatcher, context: MCPContext) async {
        await dispatcher.register(searchEmailsTool(context: context))
        await dispatcher.register(listThreadsTool(context: context))
        await dispatcher.register(getThreadTool(context: context))
        await dispatcher.register(getEmailTool(context: context))
    }

    /// Register `find_unanswered_threads` and `mark_read`. Call this only
    /// after the context has its `markReadHandler` set; otherwise `mark_read`
    /// will return an error to every caller.
    static func registerUnansweredAndMarkReadTools(on dispatcher: MCPDispatcher, context: MCPContext) async {
        await dispatcher.register(findUnansweredTool(context: context))
        await dispatcher.register(markReadTool(context: context))
    }

    /// Register `delete_messages` and `move_to_junk`. Both invoke
    /// AppleScript on Mail.app, so the same timeout caveat as `mark_read`
    /// applies — keep batches small.
    static func registerMoveTools(on dispatcher: MCPDispatcher, context: MCPContext) async {
        await dispatcher.register(deleteMessagesTool(context: context))
        await dispatcher.register(moveToJunkTool(context: context))
    }

    /// Register `diagnose_junk_mailboxes`. Read-only, no inputs — useful
    /// when move_to_junk doesn't take effect, to confirm what Mail.app
    /// reports as the junk mailbox per account.
    static func registerDiagnosticTools(on dispatcher: MCPDispatcher, context: MCPContext) async {
        await dispatcher.register(diagnoseJunkMailboxesTool(context: context))
    }

    // MARK: — search_emails

    private static func searchEmailsTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "search_emails",
            description: searchEmailsDescription,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("FMail DSL query — see the tool description for grammar.")
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "maximum": .int(500),
                        "default": .int(50),
                        "description": .string("Max results to return.")
                    ]),
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("Optional ISO date (YYYY-MM-DD or YYYY-MM or YYYY). Folded into the query as `after:`.")
                    ]),
                    "until": .object([
                        "type": .string("string"),
                        "description": .string("Optional ISO date. Folded into the query as `before:`.")
                    ])
                ]),
                "required": .array([.string("query")])
            ]),
            handler: { args in try await MCPHandlers.searchEmails(args, context: context) }
        )
    }

    // MARK: — list_threads

    private static func listThreadsTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "list_threads",
            description: """
            List threads in a mailbox (or "All Mailboxes"), newest first.
            Returns thread summaries — call `get_thread` to read messages.

            Excludes drafts, trash, and junk in the All Mailboxes scope.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "scope": .object([
                        "description": .string("Either the literal string \"all_mailboxes\", or {\"mailbox_rowid\": <int>} to scope to one mailbox. Defaults to \"all_mailboxes\".")
                    ]),
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("Optional ISO date (YYYY-MM-DD); only threads with `latest_date_received >= since` are returned.")
                    ]),
                    "until": .object([
                        "type": .string("string"),
                        "description": .string("Optional ISO date; only threads with `latest_date_received <= until` are returned.")
                    ]),
                    "unread_only": .object([
                        "type": .string("boolean"),
                        "default": .bool(false)
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "maximum": .int(600),
                        "default": .int(100)
                    ])
                ])
            ]),
            handler: { args in try await MCPHandlers.listThreads(args, context: context) }
        )
    }

    // MARK: — get_thread

    private static func getThreadTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "get_thread",
            description: """
            Get all messages in a thread, oldest first. Returns full message
            content including plain-text body and attachment metadata.

            Body text is plain (HTML stripped). Bytes for attachments are not
            shipped — only name / content_type / byte_count.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "thread_id": .object(["type": .string("integer")]),
                    "include_bodies": .object([
                        "type": .string("boolean"),
                        "default": .bool(true)
                    ]),
                    "max_body_chars": .object([
                        "type": .string("integer"),
                        "minimum": .int(0),
                        "maximum": .int(200000),
                        "default": .int(8000),
                        "description": .string("Per-message plain-text truncation cap. 0 disables body content (still returns headers/attachments).")
                    ])
                ]),
                "required": .array([.string("thread_id")])
            ]),
            handler: { args in try await MCPHandlers.getThread(args, context: context) }
        )
    }

    // MARK: — get_email

    private static func getEmailTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "get_email",
            description: """
            Fetch one message by rowid. Returns the same shape as items in
            `get_thread.messages`. Use after `search_emails` when you want to
            read a single result in detail.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "rowid": .object(["type": .string("integer")]),
                    "max_body_chars": .object([
                        "type": .string("integer"),
                        "minimum": .int(0),
                        "maximum": .int(200000),
                        "default": .int(8000)
                    ])
                ]),
                "required": .array([.string("rowid")])
            ]),
            handler: { args in try await MCPHandlers.getEmail(args, context: context) }
        )
    }

    // MARK: — find_unanswered_threads

    private static func findUnansweredTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "find_unanswered_threads",
            description: """
            Threads where YOU sent the latest message and haven't heard back.
            "You sent" matches the sender against your account email addresses,
            or against `our_address` if supplied.

            Excludes drafts/trash/junk. A reply later than your outgoing message
            removes the thread from the result. `days_silent` is computed from
            the latest outgoing message's `date_received`.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "since": .object([
                        "type": .string("string"),
                        "description": .string("ISO date (YYYY-MM-DD / YYYY-MM / YYYY). Only outgoing messages on/after this date count.")
                    ]),
                    "our_address": .object([
                        "type": .string("string"),
                        "description": .string("Optional: restrict to one specific sender address. Defaults to any account email.")
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "maximum": .int(500),
                        "default": .int(50)
                    ])
                ]),
                "required": .array([.string("since")])
            ]),
            handler: { args in try await MCPHandlers.findUnansweredThreads(args, context: context) }
        )
    }

    // MARK: — mark_read

    private static func markReadTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "mark_read",
            description: """
            Mark messages read or unread by rowid. Routes through the same
            pipeline FMail's UI uses: optimistic flip + DB persist + AppleScript
            dispatch to Mail.app.

            Bound: keep batches ≤ ~50 messages. Mail.app linearly scans
            per-mailbox messages by `whose id is N`; 100+ messages across
            multiple Gmail accounts can take 30s+ and may exceed your client's
            HTTP timeout. The work may still complete on Mail.app's side even
            if the call times out — re-call with the same rowids to confirm.

            Returns `applied` (count Mail.app matched) and `error` (string when
            the AppleScript dispatch failed).
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "rowids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("integer")]),
                        "description": .string("Apple Mail rowids — get them from search_emails / get_thread results.")
                    ]),
                    "is_read": .object([
                        "type": .string("boolean"),
                        "default": .bool(true),
                        "description": .string("true to mark read, false to mark unread.")
                    ])
                ]),
                "required": .array([.string("rowids")])
            ]),
            handler: { args in try await MCPHandlers.markRead(args, context: context) }
        )
    }

    // MARK: — delete_messages

    private static func deleteMessagesTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "delete_messages",
            description: """
            Delete messages by rowid — Mail.app moves them to the Trash
            mailbox of the relevant account, matching the Delete key in
            Mail.app's UI. Reversible from Trash.

            **VERIFYING THE DELETE — IMPORTANT.** Like `move_to_junk`, Gmail
            (and most IMAP servers) reassigns the rowid when the message
            moves to Trash. The original rowid is invalid after success.

            ✗ Do NOT verify by `get_email {rowid: <original>}`.
            ✓ DO verify by `search_emails {query: "from:<sender>
              subject:<subj>"}` showing fewer matches in the source mailbox
              after a 5–10s delay (FMail triggers an index sync immediately
              after a successful delete).

            Same time-bound caveat as `mark_read`: keep batches ≤ ~5 to
            avoid client HTTP timeouts. The work may still complete on
            Mail.app's side after a timeout — re-call is safe (no-op if
            already deleted).

            Returns `applied` (count Mail.app matched) and `error` (string
            when AppleScript dispatch failed).
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "rowids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("integer")]),
                        "description": .string("Apple Mail rowids — get them from search_emails / get_thread results.")
                    ])
                ]),
                "required": .array([.string("rowids")])
            ]),
            handler: { args in try await MCPHandlers.deleteMessages(args, context: context) }
        )
    }

    // MARK: — move_to_junk

    private static func moveToJunkTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "move_to_junk",
            description: """
            Move messages by rowid to the Junk (Spam) mailbox of their
            account.

            **REQUIRES authorized backend.** Each message's account must
            have a server-direct writeback backend configured:
              - **Gmail accounts:** authorize via FMail Settings → Gmail
                accounts → "Authorize…". Uses Gmail REST API directly.
                Sub-second per message; rock solid.
              - **Other accounts (iCloud, IMAP):** Phase B2 (not shipped
                yet). Until then, move-to-junk is unavailable for these
                accounts.

            **AppleScript fallback was REMOVED.** macOS Tahoe broke the
            underlying AppleScript path for junk-mailbox resolution
            (universally — verified against every account in a real setup),
            so it stayed timing out forever even with retries. Now if no
            authorized backend exists for a message's account, the call
            fails immediately with a clear error rather than hanging.

            **Verifying the move (Gmail).** Gmail reassigns rowids when a
            message changes mailboxes (label change → new internal id).
            The original rowid you passed in is invalid after success.
              ✗ Do NOT verify with `get_email {rowid: <original>}`.
              ✓ Verify with `search_emails {query: "from:<sender>
                subject:<subj>"}` after a 5–10s delay; FMail triggers an
                immediate sync after a successful move so the new state
                is usually visible within 5 seconds.

            **Errors.** If `error` is set, the most likely cause is that
            the account holding the message isn't authorized for Gmail
            API. Suggest the user open FMail Settings and authorize. Tell
            them which account address the rowid belongs to (visible via
            `get_email {rowid:}` in the `to` field) so they know which
            account to authorize.

            Returns `applied` (count successfully moved) and `error`
            (string when any message failed).
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "rowids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("integer")]),
                        "description": .string("Apple Mail rowids — get them from search_emails / get_thread results.")
                    ])
                ]),
                "required": .array([.string("rowids")])
            ]),
            handler: { args in try await MCPHandlers.moveToJunk(args, context: context) }
        )
    }

    // MARK: — diagnose_junk_mailboxes

    private static func diagnoseJunkMailboxesTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "diagnose_junk_mailboxes",
            description: """
            Asks Mail.app directly what each configured account's
            `junk mailbox` is, and lists every mailbox name in each account
            that looks like Spam/Junk. Use this when `move_to_junk` doesn't
            actually move the message — the output tells us whether the
            target mailbox resolution is the problem.

            Returns `{ "output": "<plain-text dump>" }`. No side effects.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:])
            ]),
            handler: { args in try await MCPHandlers.diagnoseJunkMailboxes(args, context: context) }
        )
    }

    // MARK: — search_emails description (the LLM-visible DSL grammar)

    private static let searchEmailsDescription: String = """
    Search the FMail index using a query DSL. Returns matching messages
    newest first. Drafts, trash, and junk are excluded.

    DSL GRAMMAR
    ===========
    Operators: AND (implicit), OR, NOT or `-`, parentheses, "quoted phrases".

    Field operators (each takes a single value or a quoted phrase):
      from:       sender address or display name
      to:         recipient address or display name
      cc:         cc recipient
      subject:    subject line
      body:       body text (aliases: content:, text:)
      attachment: attachment filename
      account:    account display name (e.g. "icloud", "gmail")
      in:         mailbox kind ("inbox", "sent", "archive", "all", or any path)
      has:        "attachment" only
      is:         "read", "unread", "flagged"
      before:     date — see DATE FORMS
      after:, since:  date
      on:, during:    date range matching the precision of the date

    Bareword tokens match anywhere (subject + body + sender + recipients).

    No-colon shortcuts: hasattachment, isunread, isread, isflagged.

    DATE FORMS
    ----------
      ISO:         2024-03-15, 2024-03, 2024
      Single word: today, yesterday, tomorrow
      Compact:     7d, 2w, 3m, 1y
      Quoted:      "last 30 days", "last week", "this year"
      Month name:  march, march 2024

    DATE SEMANTICS
    --------------
      before:DATE    < start of period containing DATE
      after:DATE     for partial dates: >= start of NEXT period (so after:2024 is >= 2025-01-01)
                     for full dates: >= DATE (Gmail-style inclusive)
      during:/on:    [start, start of next period) — matches the precision of DATE

    Bareword search and field values match by token PREFIX
    (e.g. `subject:v` matches "vermont"). Quote for exact match: "vermont".

    EXAMPLES
    --------
      from:anna school trip
      from:anna@gmail.com after:2024-01
      to:me from:bank invoice
      (anna OR kyoko) school -homework
      "exact phrase" has:attachment
      isunread last 7d

    INPUTS
    ------
      query     (required) the DSL string above
      limit     1–500, default 50
      since     optional ISO date — folded in as after:
      until     optional ISO date — folded in as before:

    NOTES
    -----
    - Body content is searchable as it gets indexed in the background; a
      very recent message may not match by body text yet, but always matches
      by subject/sender/recipient/attachment-name immediately.
    - Returns subject, sender, dates, mailbox path, thread_id, has_attachment,
      is_read, is_flagged. Call `get_email` to read body content.
    """
}
