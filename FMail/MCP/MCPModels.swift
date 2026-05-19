import Foundation

/// MCP DTOs — the stable JSON shapes returned to LLM clients. Decoupled from
/// internal types so refactors of `MessageHeader` / `ThreadSummary` don't
/// silently change the contract. Field names are snake_case to match what
/// LLMs typically expect from JSON APIs.

struct EmailRef: Codable, Sendable {
    let rowid: Int
    let subject: String
    let sender_display: String
    let sender_address: String
    let date_sent: String?
    let date_received: String?
    let mailbox_path: String
    /// The email address of the account this message belongs to (e.g.
    /// `felix@gmail.com`). Disambiguates "is this two copies of the same
    /// message across accounts" vs "are these distinct messages" when
    /// the same RFC Message-ID appears under multiple mailboxes.
    let account_email: String?
    let is_read: Bool
    let is_flagged: Bool
    let has_attachment: Bool
    let thread_id: Int
    /// RFC 2822 Message-ID. Useful for cross-system reference (e.g.
    /// tying back to a Notion item that captured an email URL).
    let rfc_message_id: String?
    /// True when the `.emlx` for this message has been parsed by
    /// FMail's body indexer. `get_email` / `get_thread` / `get_attachment`
    /// can return body / attachment content for these rows without
    /// requiring Mail.app to do an IMAP fetch. `false` rows may still
    /// work but can also fail with "body not on disk" — the LLM should
    /// prefer `body_on_disk:true` rows when there's a choice.
    let body_on_disk: Bool
    /// Per-attachment metadata (no bytes). Only present when
    /// `include_attachment_metadata: true` was passed to `search_emails`
    /// — gated because populating this requires loading the body of
    /// every result row from disk and would balloon row size on
    /// 100-result searches.
    let attachments: [AttachmentRef]?
}

struct AttachmentRef: Codable, Sendable {
    let name: String
    let content_type: String
    let byte_count: Int
}

/// Attachment bytes returned by `get_attachment` *without* `save_to_path`.
/// `data_base64` holds the decoded (post-MIME-decode) raw file contents,
/// base64-encoded for safe JSON transport. `truncated` is true when the
/// caller's `max_bytes` was below `byte_count` — re-call with a larger
/// cap (or pass `save_to_path` to skip the size cap entirely).
struct AttachmentContent: Codable, Sendable {
    let rowid: Int
    let attachment_index: Int
    let name: String
    let content_type: String
    let byte_count: Int
    let data_base64: String
    let truncated: Bool
}

/// Attachment metadata returned by `get_attachment` when `save_to_path`
/// was supplied. No `data_base64` — the bytes are on disk at `saved_path`.
/// Lets MCP clients sidestep the per-tool-call result-size cap that
/// would otherwise force them to three-hop (tool → disk → shell decode)
/// for any non-trivial PDF.
struct AttachmentSaved: Codable, Sendable {
    let rowid: Int
    let attachment_index: Int
    let name: String
    let content_type: String
    let byte_count: Int
    let saved_path: String
}

/// One row in the result of `get_attachments_for_rowids`. Either `saved`
/// is set (success) or `error` is (couldn't fetch body, no such index,
/// I/O failure on write, etc.) — never both.
struct BulkAttachmentRow: Codable, Sendable {
    let rowid: Int
    let attachment_index: Int
    let name: String?
    let content_type: String?
    let byte_count: Int?
    let saved_path: String?
    let error: String?
}

struct BulkAttachmentResult: Codable, Sendable {
    let saved: [BulkAttachmentRow]
    let errors: [BulkAttachmentRow]
}

struct EmailFull: Codable, Sendable {
    let rowid: Int
    let thread_id: Int
    let mailbox_path: String
    /// Account email address. Same field as on `EmailRef`.
    let account_email: String?
    let subject: String
    let sender_display: String
    let sender_address: String
    let to: [String]
    let cc: [String]
    let bcc: [String]
    let date_sent: String?
    let date_received: String?
    let is_read: Bool
    let is_flagged: Bool
    let rfc_message_id: String?
    /// rowid of the message this one is in-reply-to, resolved via Apple
    /// Mail's `message_links` table. nil when this message is the root
    /// of its thread, or when the in-reply-to message isn't in the
    /// local index. Useful for reconstructing parallel sub-conversations
    /// inside long threads.
    let in_reply_to_rowid: Int?
    /// See `EmailRef.body_on_disk`. Useful when the LLM is fanning out
    /// across thread members and wants to know which ones need a fetch.
    let body_on_disk: Bool
    let plain_text_body: String
    let plain_text_truncated: Bool
    let plain_text_full_chars: Int
    let html_body_present: Bool
    let attachments: [AttachmentRef]
}

struct ThreadRef: Codable, Sendable {
    let thread_id: Int
    let latest_subject: String
    let latest_sender_display: String
    let latest_date_received: String?
    let message_count: Int
    let unread_count: Int
    let flagged_count: Int
    let latest_is_outgoing: Bool
}

struct UnansweredThread: Codable, Sendable {
    let thread_id: Int
    let latest_subject: String
    let latest_outgoing_address: String
    let latest_date_received: String?
    let days_silent: Int
    let recipient_addresses: [String]
}

/// One row in `list_accounts` — the introspection tool that tells MCP
/// clients which `account:` values they can filter `search_emails` on.
struct AccountRef: Codable, Sendable {
    /// Stable per-account identifier — the UUID of the directory under
    /// `~/Library/Mail/V*/`. Same identifier as `account_email`'s row in
    /// FMail's internal `accounts` table.
    let uuid: String
    /// User-facing display name (typically the email address).
    let display_name: String
    /// The detected email address for this account, when available.
    /// `search_emails` accepts a substring of this on the `account:`
    /// operator (e.g. `account:icloud`, `account:gmail`).
    let email_address: String?
}

struct ListAccountsResult: Codable, Sendable {
    let accounts: [AccountRef]
}

// MARK: — Result envelopes (one per tool)

struct SearchEmailsResult: Codable, Sendable {
    let results: [EmailRef]
}

/// Sort orders for `search_emails`.
enum SearchSort: String, Sendable {
    case newestFirst = "newest_first"
    case oldestFirst = "oldest_first"
    case relevance

    static func parse(_ s: String?) -> SearchSort {
        guard let s = s?.lowercased() else { return .newestFirst }
        return SearchSort(rawValue: s) ?? .newestFirst
    }
}

struct ListThreadsResult: Codable, Sendable {
    let threads: [ThreadRef]
}

struct GetThreadResult: Codable, Sendable {
    let messages: [EmailFull]
    /// Number of messages dropped because of the `max_total_chars` budget.
    /// nil when no budget was supplied or no truncation was needed.
    let omitted_message_count: Int?
}

/// Body cleanup mode for `get_thread` / `get_email`. See
/// `MCPHandlers.buildEmailFulls` for what each option does.
enum BodyFormat: String, Sendable {
    case raw
    case plain
    case clean

    static func parse(_ s: String?) -> BodyFormat {
        guard let s = s?.lowercased() else { return .plain }
        return BodyFormat(rawValue: s) ?? .plain
    }
}

/// Message ordering inside a thread.
enum ThreadDirection: String, Sendable {
    case oldestFirst = "oldest_first"
    case newestFirst = "newest_first"

    static func parse(_ s: String?) -> ThreadDirection {
        guard let s = s?.lowercased() else { return .oldestFirst }
        return ThreadDirection(rawValue: s) ?? .oldestFirst
    }
}

struct FindUnansweredThreadsResult: Codable, Sendable {
    let threads: [UnansweredThread]
}

struct MarkReadResult: Codable, Sendable {
    let applied: Int
    let error: String?
}

// MARK: — Date / encoding helpers

private struct ISO8601: Sendable {
    static func format(_ date: Date) -> String { date.formatted(.iso8601) }
}

extension Date {
    /// ISO-8601 string with seconds precision, suitable for JSON DTOs.
    func mcpISO8601() -> String { ISO8601.format(self) }
}

extension Optional where Wrapped == Date {
    func mcpISO8601() -> String? {
        guard let self else { return nil }
        return ISO8601.format(self)
    }
}

extension JSONValue {
    /// Encode any `Encodable` Swift value to a `JSONValue` tree by way of
    /// JSONEncoder/JSONDecoder. Lossless for any Codable value that maps
    /// cleanly onto JSON.
    static func encoding<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
