import Foundation

/// A user account, identified by the UUID directory under `~/Library/Mail/V*`.
struct MailAccount: Identifiable, Hashable {
    let uuid: String
    let displayName: String
    let emailAddress: String?
    var id: String { uuid }
}

/// Recipient role, mirroring Apple's `recipients.type` column (and FMail's
/// `IndexedRecipient.kind`). Avoids the magic 0/1/2/3 literals in SQL.
enum RecipientKind: Int {
    case to = 0
    case cc = 1
    case bcc = 2
    case from = 3
}

/// A mailbox (= folder, in old-Apple-Mail terms). Each mailbox lives under one
/// account directory; the path components map directly to nested `*.mbox`
/// directories on disk.
struct Mailbox: Identifiable, Hashable {
    let rowId: Int                // mailboxes.ROWID in Envelope Index
    let accountUUID: String
    let pathComponents: [String]  // e.g. ["[Gmail]", "All Mail"] or ["INBOX"]
    let totalCount: Int
    let unreadCount: Int          // computed by FMail, not Apple's drift-prone field
    let hidden: Bool
    let kind: MailboxKind
    var id: Int { rowId }

    var displayName: String { pathComponents.last ?? "(unnamed)" }

    /// Copy with adjusted counts (the only fields optimistic flips touch).
    func with(totalCount: Int? = nil, unreadCount: Int? = nil) -> Mailbox {
        Mailbox(
            rowId: rowId, accountUUID: accountUUID, pathComponents: pathComponents,
            totalCount: totalCount ?? self.totalCount,
            unreadCount: unreadCount ?? self.unreadCount,
            hidden: hidden, kind: kind
        )
    }

    /// Filesystem path to the .mbox directory tree for this mailbox.
    func diskURL(under accountRoot: URL) -> URL {
        var url = accountRoot
        for component in pathComponents {
            url.appendPathComponent("\(component).mbox")
        }
        return url
    }
}

/// Canonical category for a mailbox, derived from its display name. Stored
/// in the index DB as `rawValue` so SQL filters (`kind IN ('drafts',...)`)
/// keep working unchanged.
enum MailboxKind: String, Sendable, Hashable, CaseIterable {
    case inbox, sent, drafts, trash, junk, archive, all, other

    /// "System-isolated" kinds — drafts/trash/junk — that we hide from
    /// other mailboxes' thread views unless the user is browsing one of
    /// these mailboxes directly.
    var isSystemIsolated: Bool {
        switch self {
        case .drafts, .trash, .junk: return true
        case .inbox, .sent, .archive, .all, .other: return false
        }
    }

    /// Decide which `IndexDB.ThreadViewScope` applies for the current
    /// sidebar state. `selectedKind == nil` is treated as a non-system
    /// mailbox (default to `.excludeDrafts`).
    static func viewScope(forSelectedKind selectedKind: MailboxKind?, allMailboxesScope: Bool) -> IndexDB.ThreadViewScope {
        if allMailboxesScope { return .excludeAllSystem }
        if let kind = selectedKind, kind.isSystemIsolated { return .includeAll }
        return .excludeDrafts
    }
}

/// Lightweight header-only message info, suitable for showing in a list.
struct MessageHeader: Identifiable, Hashable {
    let rowId: Int                // messages.ROWID — also the .emlx filename
    let mailboxRowId: Int
    let subject: String           // RFC 2047 decoded
    let senderAddress: String
    let senderDisplay: String     // "Display Name" or address if no name
    let dateSent: Date?
    let dateReceived: Date?
    let isRead: Bool
    let isFlagged: Bool
    let hasAttachment: Bool       // a *real* file attachment (inline signature
                                  // images are filtered out at index time)
    let rfcMessageId: String?     // RFC 2822 Message-ID header (with angle brackets)
    let imapUID: Int?             // Apple Mail's per-mailbox IMAP UID; lets
                                  // AppleScript do O(1) `whose id is N` lookups
    var id: Int { rowId }

    /// Copy with a flipped read flag.
    func withIsRead(_ isRead: Bool) -> MessageHeader {
        MessageHeader(
            rowId: rowId, mailboxRowId: mailboxRowId, subject: subject,
            senderAddress: senderAddress, senderDisplay: senderDisplay,
            dateSent: dateSent, dateReceived: dateReceived,
            isRead: isRead, isFlagged: isFlagged, hasAttachment: hasAttachment,
            rfcMessageId: rfcMessageId, imapUID: imapUID
        )
    }
}

/// One attachment extracted from an `.emlx`. `data` holds the decoded bytes
/// (after Content-Transfer-Encoding decode), so saving via `NSSavePanel`
/// is just a `data.write(to:)`.
struct Attachment {
    let name: String
    let contentType: String
    let data: Data
}

/// Fully-parsed message body for display in the reader.
struct MessageBody: Equatable {
    let headers: ParsedHeaders
    let plainText: String?
    let html: String?
    let attachments: [Attachment]

    /// Names of attachments, in order. Convenience for code that only
    /// cares about display (FTS indexing, header line "paperclip + names").
    var attachmentNames: [String] { attachments.map(\.name) }

    /// Best text for rendering: plain if available, otherwise HTML stripped.
    var displayText: String {
        if let plainText, !plainText.isEmpty { return plainText }
        if let html, !html.isEmpty { return HTMLStripper.toPlainText(html) }
        return ""
    }

    static func == (lhs: MessageBody, rhs: MessageBody) -> Bool {
        // Only the textual content + attachment list matters for SwiftUI
        // change detection. Compare attachments by (name, byte count) — full
        // byte-equality on potentially-multi-MB blobs would be wasteful.
        guard lhs.plainText == rhs.plainText, lhs.html == rhs.html else { return false }
        guard lhs.attachments.count == rhs.attachments.count else { return false }
        for (a, b) in zip(lhs.attachments, rhs.attachments) {
            if a.name != b.name || a.data.count != b.data.count { return false }
        }
        return true
    }
}
