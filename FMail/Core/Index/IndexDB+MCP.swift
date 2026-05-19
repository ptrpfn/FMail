import Foundation
import SQLite3

/// Read helpers used by the MCP server. Kept in their own extension so the
/// MCP plumbing stays isolated from the rest of the index API.
///
/// The `messages` table column list shapes match those used by `search()`
/// (`IndexDB.swift:506`) so that callers can mix results from `search` and
/// `loadMessage` interchangeably.
extension IndexDB {

    /// Single-message lookup by `apple_rowid`. Returns nil if the message
    /// no longer exists in the index (e.g. the user trashed it before this
    /// call).
    func loadMessage(rowid: Int) throws -> MessageHeader? {
        let sql = """
        SELECT m.apple_rowid, m.mailbox_rowid,
               COALESCE(m.subject_prefix, '') || m.subject,
               m.sender_address, m.sender_display,
               m.date_sent, m.date_received,
               m.is_read, m.is_flagged, m.rfc_message_id, m.imap_uid
        FROM messages m
        WHERE m.apple_rowid = ?
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, Int64(rowid))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let mboxId = Int(sqlite3_column_int64(stmt, 1))
        let subject = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let sa = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
        let sd = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
        let ds = sqlite3_column_int64(stmt, 5)
        let dr = sqlite3_column_int64(stmt, 6)
        let read = sqlite3_column_int(stmt, 7) != 0
        let flagged = sqlite3_column_int(stmt, 8) != 0
        let rfcId = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
        let uidVal = sqlite3_column_int64(stmt, 10)
        let uid: Int? = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : Int(uidVal)
        return MessageHeader(
            rowId: rowid, mailboxRowId: mboxId, subject: subject,
            senderAddress: sa, senderDisplay: sd,
            dateSent: ds > 0 ? Date(timeIntervalSince1970: TimeInterval(ds)) : nil,
            dateReceived: dr > 0 ? Date(timeIntervalSince1970: TimeInterval(dr)) : nil,
            isRead: read, isFlagged: flagged, rfcMessageId: rfcId, imapUID: uid
        )
    }

    /// Single-mailbox lookup by `apple_rowid`. Returns nil if the mailbox is
    /// gone (rare but possible after an account removal).
    func loadMailbox(rowid: Int) throws -> Mailbox? {
        let sql = """
        SELECT account_uuid, path, hidden, total_count, unread_count, kind
        FROM mailboxes WHERE apple_rowid = ?
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, Int64(rowid))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let acctUUID = String(cString: sqlite3_column_text(stmt, 0))
        let path = String(cString: sqlite3_column_text(stmt, 1))
        let pathComponents = path.split(separator: "/").map(String.init)
        let hidden = sqlite3_column_int(stmt, 2) != 0
        let total = Int(sqlite3_column_int64(stmt, 3))
        let unread = Int(sqlite3_column_int64(stmt, 4))
        let kindStr = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
        let kind = kindStr.flatMap(MailboxKind.init(rawValue:)) ?? .other
        return Mailbox(
            rowId: rowid,
            accountUUID: acctUUID,
            pathComponents: pathComponents,
            totalCount: total,
            unreadCount: unread,
            hidden: hidden,
            kind: kind
        )
    }

    /// All recipients of `messageRowId`, ordered by (kind, position).
    /// `kind`: 0=to, 1=cc, 2=bcc, 3=from (informational, rarely used).
    func loadRecipients(messageRowId: Int) throws -> [MCPRecipient] {
        let sql = """
        SELECT kind, address, COALESCE(display, '')
        FROM recipients
        WHERE message_rowid = ?
        ORDER BY kind ASC, position ASC
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, Int64(messageRowId))
        var out: [MCPRecipient] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let kind = Int(sqlite3_column_int64(stmt, 0))
            let address = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let display = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            out.append(MCPRecipient(kind: kind, address: address, display: display.isEmpty ? nil : display))
        }
        return out
    }

    /// Bulk fetch the columns the MCP DTOs need that aren't on `MessageHeader`:
    /// mailbox path, effective thread id, has_attachment. One SQL with
    /// `apple_rowid IN (...)` so a 50-row search result costs one round-trip.
    func enrichForMCP(rowids: [Int]) throws -> [Int: MCPMessageEnrichment] {
        guard !rowids.isEmpty else { return [:] }
        let placeholders = rowids.map { _ in "?" }.joined(separator: ",")
        // Effective thread id: real thread_id when set, apple_rowid as a
        // synthetic singleton id otherwise. Matches IndexDB.effectiveThreadIdExpr.
        let sql = """
        SELECT m.apple_rowid,
               COALESCE(mb.path, '') AS mailbox_path,
               CASE WHEN m.thread_id = 0 THEN m.apple_rowid ELSE m.thread_id END AS thread_id,
               m.has_attachment,
               m.body_indexed,
               a.email_address
        FROM messages m
        LEFT JOIN mailboxes mb ON mb.apple_rowid = m.mailbox_rowid
        LEFT JOIN accounts  a  ON a.uuid         = m.account_uuid
        WHERE m.apple_rowid IN (\(placeholders))
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        for (i, id) in rowids.enumerated() {
            bind(stmt, Int32(i + 1), Int64(id))
        }
        var out: [Int: MCPMessageEnrichment] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = Int(sqlite3_column_int64(stmt, 0))
            let path = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let tid = Int(sqlite3_column_int64(stmt, 2))
            let hasA = sqlite3_column_int(stmt, 3) != 0
            // `body_indexed` is set to 1 by BodyIndexer once the `.emlx`
            // has been parsed. Used as a proxy for "body fetch will
            // succeed without a Mail.app IMAP round-trip" — surfaced as
            // `body_on_disk` in MCP result shapes.
            let bodyOnDisk = sqlite3_column_int(stmt, 4) != 0
            let accountEmail = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            out[rowid] = MCPMessageEnrichment(
                mailboxPath: path,
                threadId: tid,
                hasAttachment: hasA,
                bodyOnDisk: bodyOnDisk,
                accountEmail: accountEmail
            )
        }
        return out
    }

    /// Resolve "this message replied to ..." via Apple's `message_links`
    /// table. The join chain: `m → message_links (from_message_rowid =
    /// m.apple_rowid, is_parent = 1) → messages (where
    /// apple_message_id_hash = to_message_id_hash)`. Returns the
    /// parent's `apple_rowid` per input rowid (nil when no parent is
    /// known locally — root-of-thread, or the parent is unindexed).
    func inReplyToRowids(_ rowids: [Int]) throws -> [Int: Int] {
        guard !rowids.isEmpty else { return [:] }
        let placeholders = rowids.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT l.from_message_rowid, parent.apple_rowid
        FROM message_links l
        JOIN messages parent ON parent.apple_message_id_hash = l.to_message_id_hash
        WHERE l.is_parent = 1
          AND l.from_message_rowid IN (\(placeholders))
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        for (i, id) in rowids.enumerated() {
            bind(stmt, Int32(i + 1), Int64(id))
        }
        var out: [Int: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let from = Int(sqlite3_column_int64(stmt, 0))
            let to = Int(sqlite3_column_int64(stmt, 1))
            // Multiple parents per message can exist (rare); first one wins.
            if out[from] == nil { out[from] = to }
        }
        return out
    }

    /// Threads where we sent the latest message and haven't heard back.
    /// "We sent" = sender matches one of our account email addresses (or
    /// `ourAddress` when supplied). System mailboxes (drafts/trash/junk) are
    /// excluded from the latest-message lookup so a draft revision can't
    /// look like an unanswered send.
    ///
    /// Algorithm: per-thread latest message → keep if it's outgoing AND its
    /// `date_received >= since`. Threads where someone replied after our
    /// outgoing message naturally drop out because the latest message is no
    /// longer outgoing.
    func findUnansweredThreads(since: Date, ourAddress: String?, limit: Int) throws -> [UnansweredThread] {
        let sinceTs = Int64(since.timeIntervalSince1970)

        let outgoingPredicate: String
        if ourAddress != nil {
            outgoingPredicate = "LOWER(et.sender_address) = ?"
        } else {
            outgoingPredicate = """
            LOWER(et.sender_address) IN (
                SELECT LOWER(email_address) FROM accounts WHERE email_address IS NOT NULL
            )
            """
        }

        let sql = """
        WITH effective AS (
            SELECT m.apple_rowid,
                   CASE WHEN m.thread_id = 0 THEN m.apple_rowid ELSE m.thread_id END AS tid,
                   m.date_received,
                   COALESCE(m.subject_prefix, '') || COALESCE(m.subject, '') AS subj,
                   COALESCE(m.sender_address, '') AS sender_address
            FROM messages m
            WHERE m.mailbox_rowid NOT IN (
                  SELECT apple_rowid FROM mailboxes WHERE kind IN ('drafts', 'trash', 'junk')
              )
              AND m.apple_rowid NOT IN (
                  SELECT message_rowid FROM message_labels
                  WHERE mailbox_rowid IN (
                      SELECT apple_rowid FROM mailboxes WHERE kind IN ('drafts', 'trash', 'junk')
                  )
              )
        ),
        thread_latest AS (
            SELECT tid, MAX(date_received) AS latest_date FROM effective GROUP BY tid
        ),
        candidates AS (
            SELECT et.apple_rowid, et.tid, et.subj, et.sender_address, et.date_received
            FROM effective et
            JOIN thread_latest tl ON tl.tid = et.tid AND tl.latest_date = et.date_received
            WHERE et.date_received >= ?
              AND \(outgoingPredicate)
        )
        SELECT c.apple_rowid, c.tid, c.subj, c.sender_address, c.date_received,
               COALESCE((
                   SELECT GROUP_CONCAT(LOWER(r.address), ',')
                   FROM recipients r
                   WHERE r.message_rowid = c.apple_rowid AND r.kind = 0
               ), '') AS to_addresses
        FROM candidates c
        ORDER BY c.date_received DESC
        LIMIT ?
        """

        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }

        var pos: Int32 = 1
        bind(stmt, pos, sinceTs); pos += 1
        if let ourAddress {
            bind(stmt, pos, ourAddress.lowercased()); pos += 1
        }
        bind(stmt, pos, Int64(limit))

        var out: [UnansweredThread] = []
        let now = Date()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let tid = Int(sqlite3_column_int64(stmt, 1))
            let subj = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let sender = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let dr = sqlite3_column_int64(stmt, 4)
            let toStr = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
            let date = dr > 0 ? Date(timeIntervalSince1970: TimeInterval(dr)) : nil
            let daysSilent = date.map { Int(now.timeIntervalSince($0) / 86400) } ?? 0
            let recipients = toStr.split(separator: ",").map(String.init).filter { !$0.isEmpty }
            out.append(UnansweredThread(
                thread_id: tid,
                latest_subject: subj,
                latest_outgoing_address: sender,
                latest_date_received: date.mcpISO8601(),
                days_silent: daysSilent,
                recipient_addresses: recipients
            ))
        }
        return out
    }

    /// Mailbox path lookup for a single rowid — convenience wrapper.
    /// Returns nil for unknown mailboxes.
    func mailboxPath(rowid: Int) throws -> String? {
        var stmt: OpaquePointer?
        try prepare("SELECT path FROM mailboxes WHERE apple_rowid = ?", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, Int64(rowid))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
    }
}

/// Wire types passed back from the MCP-only IndexDB read helpers.

struct MCPRecipient: Sendable, Hashable {
    let kind: Int  // 0=to, 1=cc, 2=bcc, 3=from
    let address: String
    let display: String?
}

struct MCPMessageEnrichment: Sendable, Hashable {
    let mailboxPath: String
    let threadId: Int
    let hasAttachment: Bool
    let bodyOnDisk: Bool
    let accountEmail: String?
}
