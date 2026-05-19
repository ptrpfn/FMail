import Foundation

/// Tool registry — wires tool names + descriptions + JSON Schemas to their
/// handler implementations in `MCPHandlers`. Registration happens once per
/// MCP server start.
///
/// Each tool's `description` is what the LLM sees in `tools/list`. Be
/// pragmatic, not poetic. The `search_emails` description embeds the FMail
/// DSL grammar so the LLM can compose queries without external knowledge.
enum MCPTools {
    /// Register the read-only MCP tools. By design the surface is
    /// non-destructive — Mail state changes happen through FMail's UI
    /// (or Mail.app directly), never through MCP. That makes it safe to
    /// expose the connector over a public tunnel: the worst an attacker
    /// who got past the bearer token could do is read mail.
    static func registerReadTools(on dispatcher: MCPDispatcher, context: MCPContext) async {
        await dispatcher.register(searchEmailsTool(context: context))
        await dispatcher.register(listThreadsTool(context: context))
        await dispatcher.register(listAccountsTool(context: context))
        await dispatcher.register(getThreadTool(context: context))
        await dispatcher.register(getEmailTool(context: context))
        await dispatcher.register(getAttachmentTool(context: context))
        await dispatcher.register(getAttachmentsForRowidsTool(context: context))
        await dispatcher.register(findUnansweredTool(context: context))
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
                    ]),
                    "sort": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("newest_first"),
                            .string("oldest_first"),
                            .string("relevance")
                        ]),
                        "default": .string("newest_first"),
                        "description": .string("Result ordering. newest_first is the default. `relevance` currently falls back to newest_first (FTS5 BM25 isn't surfaced through our IN-subquery shape yet).")
                    ]),
                    "include_attachment_metadata": .object([
                        "type": .string("boolean"),
                        "default": .bool(false),
                        "description": .string("When true, each result row includes `attachments: [{name, content_type, byte_count}]`. Costs one body load per result, so only enable when needed (e.g. 'find the email where Anita sent the contract PDF' workflows).")
                    ])
                ]),
                "required": .array([.string("query")])
            ]),
            handler: { args in try await MCPHandlers.searchEmails(args, context: context) }
        )
    }

    // MARK: — list_accounts

    private static func listAccountsTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "list_accounts",
            description: """
            Introspection: list the mail accounts FMail has indexed.
            Returns `{uuid, display_name, email_address}` per account.

            Use the email_address (or any substring of it) on the DSL
            `account:` operator to filter `search_emails`. Most useful
            when you're seeing two similar-looking results across
            different mailboxes and want to know whether they're the
            same message indexed under multiple accounts or actually
            different.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:])
            ]),
            handler: { args in try await MCPHandlers.listAccounts(args, context: context) }
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
            Get all messages in a thread. Returns full message content
            including plain-text body and attachment metadata. Bytes for
            attachments are not shipped — only name / content_type /
            byte_count.

            **body_format** controls how aggressively the body is
            cleaned before truncation:
              - `plain` (default): HTML stripped, otherwise verbatim.
                Preserves quoted reply chains and signatures.
              - `clean`: same as plain plus — strip everything below the
                first reply-chain marker (`On <date> ... wrote:`,
                `-----Original Message-----`, Outlook quoted-header
                block); strip below the first signature delimiter
                (`-- ` line, `Sent from my iPhone/iPad`, Outlook iOS
                signature); collapse known tracking URLs (Mimecast
                cybergraph, Outlook safelinks, Google AMP); collapse
                blank lines. Designed for context-window-sensitive
                callers pulling long threads — typically 5–10× smaller
                payload on threads with quoted-reply chains and legal
                disclaimer footers.
              - `raw`: same as `plain` today; reserved for future use.

            **max_total_chars**: cap on the SUM of plain-text bodies
            across the whole thread (0 = no cap). When the cap would be
            exceeded, messages are dropped from the tail of whatever
            order is in effect — so with `direction: newest_first` the
            oldest messages drop first. Response includes
            `omitted_message_count` when truncation kicked in.

            **direction**: `oldest_first` (default) or `newest_first`.
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
                    ]),
                    "body_format": .object([
                        "type": .string("string"),
                        "enum": .array([.string("plain"), .string("clean"), .string("raw")]),
                        "default": .string("plain")
                    ]),
                    "max_total_chars": .object([
                        "type": .string("integer"),
                        "minimum": .int(0),
                        "maximum": .int(1_000_000),
                        "default": .int(0),
                        "description": .string("Cap on the SUM of plain_text_body across all returned messages. 0 = no cap.")
                    ]),
                    "direction": .object([
                        "type": .string("string"),
                        "enum": .array([.string("oldest_first"), .string("newest_first")]),
                        "default": .string("oldest_first")
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

            `body_format` works the same as on `get_thread` — pass
            `clean` to strip quoted reply chains, signatures, and
            tracking URLs before truncation.
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
                    ]),
                    "body_format": .object([
                        "type": .string("string"),
                        "enum": .array([.string("plain"), .string("clean"), .string("raw")]),
                        "default": .string("plain")
                    ])
                ]),
                "required": .array([.string("rowid")])
            ]),
            handler: { args in try await MCPHandlers.getEmail(args, context: context) }
        )
    }

    // MARK: — get_attachment

    private static func getAttachmentTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "get_attachment",
            description: """
            Fetch one attachment's bytes by message rowid + 0-based index.
            Two output modes:

            **`save_to_path` (recommended for binary)** — the server writes
            the decoded bytes directly to that filesystem path and the
            response contains only `{rowid, attachment_index, name,
            content_type, byte_count, saved_path}`. No base64 round-trip,
            no per-call size cap, no truncation. Use this for any PDF /
            image / archive — base64-in-JSON tends to push anything
            above ~150 KB past MCP-client result-size caps. The path may
            start with `~` (expanded to your home) or be relative
            (resolved against your home). Missing parent directories are
            created.

            **No `save_to_path`** — bytes returned in `data_base64`, capped
            by `max_bytes` (default 10 MB). Convenient for small text /
            JSON attachments; awkward for binaries.

            Get the attachment index from `get_email` / `get_thread`'s
            `attachments` array (same order). The body must be on disk
            (check `body_on_disk` on the search result row); if not, the
            call errors and the user has to open the message in Mail.app
            once to trigger an IMAP fetch.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "rowid": .object(["type": .string("integer")]),
                    "attachment_index": .object([
                        "type": .string("integer"),
                        "minimum": .int(0),
                        "description": .string("0-based index into the attachments array returned by get_email / get_thread.")
                    ]),
                    "save_to_path": .object([
                        "type": .string("string"),
                        "description": .string("Filesystem path to write the decoded bytes to. Tilde-expanded; relative paths are resolved against $HOME. When set, the response omits data_base64 and includes saved_path. Recommended for any non-trivial binary.")
                    ]),
                    "max_bytes": .object([
                        "type": .string("integer"),
                        "minimum": .int(0),
                        "default": .int(10_000_000),
                        "description": .string("Only used when save_to_path is unset. Cap on raw (pre-base64) bytes returned. Larger attachments come back with truncated=true.")
                    ])
                ]),
                "required": .array([.string("rowid"), .string("attachment_index")])
            ]),
            handler: { args in try await MCPHandlers.getAttachment(args, context: context) }
        )
    }

    // MARK: — get_attachments_for_rowids (bulk)

    private static func getAttachmentsForRowidsTool(context: MCPContext) -> MCPTool {
        MCPTool(
            name: "get_attachments_for_rowids",
            description: """
            Bulk variant of `get_attachment` for fan-out workflows
            (e.g. "pull every invoice attachment from these 8 messages").
            Writes every attachment of every supplied rowid into
            `save_dir`, one subdirectory per rowid:

              <save_dir>/<rowid>/<original_filename>

            Returns `{saved: [...], errors: [...]}`. Each `saved` row has
            `{rowid, attachment_index, name, content_type, byte_count,
            saved_path}`. Each `errors` row has `{rowid, attachment_index,
            error}` and means *that message* (or that one attachment)
            couldn't be fetched — the rest of the batch keeps going.

            `save_dir` may start with `~` (expanded to your home) or be
            relative (resolved against $HOME). Created if missing.
            """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "rowids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("integer")]),
                        "description": .string("Apple Mail rowids — usually the output of `search_emails`. Messages without attachments contribute nothing to the result.")
                    ]),
                    "save_dir": .object([
                        "type": .string("string"),
                        "description": .string("Directory under which the per-rowid subdirectories will be created.")
                    ])
                ]),
                "required": .array([.string("rowids"), .string("save_dir")])
            ]),
            handler: { args in try await MCPHandlers.getAttachmentsForRowids(args, context: context) }
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

    // MARK: — search_emails description (the LLM-visible DSL grammar)

    private static let searchEmailsDescription: String = """
    Search the FMail index using a query DSL. Returns matching messages
    newest first. Drafts, trash, and junk are excluded.

    DSL GRAMMAR
    ===========
    Operators: AND (implicit), OR, NOT or `-`, parentheses, "quoted phrases".

    Field operators (each takes a single value or a quoted phrase):
      from:       sender address or display name (supports domain match)
      to:         recipient address or display name
      cc:         cc recipient
      subject:    subject line
      body:       body text (aliases: content:, text:)
      attachment: attachment filename
      account:    account display name (e.g. "icloud", "gmail")
      in:         mailbox kind ("inbox", "sent", "archive", "all", or any path)
      thread:     numeric thread_id (from previous search/get_thread results) —
                  narrows to one conversation. Combine with body:/from:/etc. to
                  grep within a thread.
      has:        "attachment" only
      is:         "read", "unread", "flagged"
      before:     date — see DATE FORMS
      after:, since:  date
      on:, during:    date range matching the precision of the date

    Bareword tokens match anywhere (subject + body + sender + recipients).

    No-colon shortcuts: hasattachment, isunread, isread, isflagged.

    ADDRESS / DOMAIN MATCHING
    -------------------------
    Values for `from:`/`to:`/`cc:`/`attachment:` are split on non-alphanumeric
    chars before searching, so `from:savills.com` matches any sender with
    "savills" AND "com" in their address column (i.e. all @savills.com
    addresses). `from:james@savills.com` ANDs four tokens. This catches
    senders even though FTS5 tokenises email addresses by `@` and `.`.

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
                     (so `before:2025` is `< 2025-01-01`)
      after:DATE     >= start of period containing DATE — INCLUSIVE
      since:DATE     synonym for after:
                     (so `after:2024` is `>= 2024-01-01`,
                      `after:2024-03` is `>= 2024-03-01`,
                      `after:2024-03-15` is `>= 2024-03-15`)
      during:/on:    [start, start of next period) — matches the precision of DATE
                     (so `during:2024-03` is all of March 2024)

    Bareword search and field values match by token PREFIX
    (e.g. `subject:v` matches "vermont"). Quote for exact match: "vermont".

    EXAMPLES
    --------
      from:anna school trip
      from:savills.com (matches any savills.com sender)
      from:anna@gmail.com after:2024-01
      to:me from:bank invoice
      thread:1234 body:"550k"            (grep within a conversation)
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
    - Each result row has `body_on_disk:true|false`. False means the .emlx
      hasn't been fetched yet — `get_email` / `get_attachment` may fail
      until the user opens the message in Mail.app once. Prefer rows with
      body_on_disk:true when there's a choice.
    """
}
