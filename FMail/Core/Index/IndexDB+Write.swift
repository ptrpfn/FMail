import Foundation
import SQLite3

/// Bulk write / mutation API for the index. Kept in its own extension so the
/// large upsert/replace/delete block stays separate from the read and
/// thread-list query paths. All methods reach SQLite through the file-private
/// `db` seam exposed by IndexDB's low-level helpers (`exec`, `inTransaction`,
/// `prepare`, `stepDone`, `bind*`).
extension IndexDB {

    func upsertAccounts(_ accounts: [(uuid: String, displayName: String, email: String?)]) throws {
        let sql = """
        INSERT INTO accounts(uuid, display_name, email_address) VALUES (?, ?, ?)
        ON CONFLICT(uuid) DO UPDATE SET display_name = excluded.display_name, email_address = excluded.email_address
        """
        try inTransaction {
            var stmt: OpaquePointer?
            try prepare(sql, into: &stmt)
            defer { sqlite3_finalize(stmt) }
            for a in accounts {
                sqlite3_reset(stmt)
                bind(stmt, 1, a.uuid)
                bind(stmt, 2, a.displayName)
                bindOptional(stmt, 3, a.email)
                try stepDone(stmt)
            }
        }
    }

    func upsertMailboxes(_ mailboxes: [Mailbox]) throws {
        let sql = """
        INSERT INTO mailboxes(apple_rowid, account_uuid, path, name, hidden, total_count, unread_count, kind)
        VALUES (?,?,?,?,?,?,?,?)
        ON CONFLICT(apple_rowid) DO UPDATE SET
          account_uuid = excluded.account_uuid,
          path = excluded.path,
          name = excluded.name,
          hidden = excluded.hidden,
          total_count = excluded.total_count,
          unread_count = excluded.unread_count,
          kind = excluded.kind
        """
        try inTransaction {
            var stmt: OpaquePointer?
            try prepare(sql, into: &stmt)
            defer { sqlite3_finalize(stmt) }
            for m in mailboxes {
                sqlite3_reset(stmt)
                bind(stmt, 1, Int64(m.rowId))
                bind(stmt, 2, m.accountUUID)
                bind(stmt, 3, m.pathComponents.joined(separator: "/"))
                bind(stmt, 4, m.displayName)
                bind(stmt, 5, m.hidden ? 1 : 0)
                bind(stmt, 6, Int64(m.totalCount))
                bind(stmt, 7, Int64(m.unreadCount))
                bind(stmt, 8, mailboxKind(for: m).rawValue)
                try stepDone(stmt)
            }
        }
    }

    /// Bulk upsert messages. Caller is responsible for chunking; this method
    /// handles its own transaction.
    func upsertMessages(_ rows: [IndexedMessage]) throws {
        let sql = """
        INSERT INTO messages(
            apple_rowid, apple_message_id_hash, mailbox_rowid, account_uuid,
            subject, subject_prefix, subject_normalized,
            sender_address, sender_display,
            date_sent, date_received,
            is_read, is_flagged, has_attachment, rfc_message_id, imap_uid
        )
        VALUES (?,?,?,?, ?,?,?, ?,?, ?,?, ?,?,?,?,?)
        ON CONFLICT(apple_rowid) DO UPDATE SET
            mailbox_rowid = excluded.mailbox_rowid,
            account_uuid = excluded.account_uuid,
            subject = excluded.subject,
            subject_prefix = excluded.subject_prefix,
            subject_normalized = excluded.subject_normalized,
            sender_address = excluded.sender_address,
            sender_display = excluded.sender_display,
            date_sent = excluded.date_sent,
            date_received = excluded.date_received,
            is_read = excluded.is_read,
            is_flagged = excluded.is_flagged,
            has_attachment = excluded.has_attachment,
            rfc_message_id = excluded.rfc_message_id,
            imap_uid = excluded.imap_uid
        """
        try inTransaction {
            var stmt: OpaquePointer?
            try prepare(sql, into: &stmt)
            defer { sqlite3_finalize(stmt) }
            for r in rows {
                sqlite3_reset(stmt)
                bind(stmt, 1, Int64(r.appleRowId))
                bind(stmt, 2, r.appleMessageIdHash)
                bind(stmt, 3, Int64(r.mailboxRowId))
                bind(stmt, 4, r.accountUUID)
                bind(stmt, 5, r.subject)
                bind(stmt, 6, r.subjectPrefix)
                bind(stmt, 7, r.subjectNormalized)
                bindOptional(stmt, 8, r.senderAddress)
                bindOptional(stmt, 9, r.senderDisplay)
                bindOptional(stmt, 10, r.dateSent)
                bindOptional(stmt, 11, r.dateReceived)
                bind(stmt, 12, r.isRead ? 1 : 0)
                bind(stmt, 13, r.isFlagged ? 1 : 0)
                bind(stmt, 14, r.hasAttachment ? 1 : 0)
                bindOptional(stmt, 15, r.rfcMessageId)
                bindOptional(stmt, 16, r.imapUID)
                try stepDone(stmt)
            }
        }
    }

    func upsertRecipients(_ rows: [IndexedRecipient]) throws {
        // Replace all recipients per message in one go. Caller is expected to
        // pass all recipients of a batch, including ones for messages with no
        // recipients (just skip those).
        try inTransaction {
            // Delete old recipients for affected messages, then insert.
            let messageIds = Array(Set(rows.map(\.messageRowId)))
            try deleteRecipients(messageIds: messageIds)
            let sql = "INSERT INTO recipients(message_rowid, kind, position, address, display) VALUES(?,?,?,?,?)"
            var stmt: OpaquePointer?
            try prepare(sql, into: &stmt)
            defer { sqlite3_finalize(stmt) }
            for r in rows {
                sqlite3_reset(stmt)
                bind(stmt, 1, Int64(r.messageRowId))
                bind(stmt, 2, Int64(r.kind))
                bind(stmt, 3, Int64(r.position))
                bind(stmt, 4, r.address)
                bindOptional(stmt, 5, r.display)
                try stepDone(stmt)
            }
        }
    }

    /// Optimistic delete from FMail's index after the UI / MCP layer has
    /// dispatched an AppleScript delete to Mail.app. Removes the message
    /// rows plus their dependents (recipients, labels, links, FTS) so any
    /// subsequent UI navigation or MCP read reflects the post-delete state
    /// immediately — without waiting for the FSEvent-driven sync to
    /// re-mirror Apple's Envelope Index.
    ///
    /// Safe on AppleScript failure: the next full sync re-reads Apple's
    /// Envelope Index and upserts any row that's still there, restoring
    /// the deleted entries automatically (the indexer's `pruneMessagesNotIn`
    /// pass only drops rowids no longer present in Apple's index).
    func deleteMessagesByRowid(_ rowids: [Int]) throws {
        guard !rowids.isEmpty else { return }
        try inTransaction {
            // Chunk to keep `?` placeholder count below SQLite's variable
            // limit (default 32766). 500 leaves headroom for any future
            // multi-bind columns.
            var idx = 0
            while idx < rowids.count {
                let end = min(idx + 500, rowids.count)
                let chunk = Array(rowids[idx..<end])
                idx = end
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let statements = [
                    "DELETE FROM recipients WHERE message_rowid IN (\(placeholders))",
                    "DELETE FROM message_labels WHERE message_rowid IN (\(placeholders))",
                    "DELETE FROM message_links WHERE from_message_rowid IN (\(placeholders))",
                    "DELETE FROM messages_fts WHERE rowid IN (\(placeholders))",
                    "DELETE FROM messages WHERE apple_rowid IN (\(placeholders))"
                ]
                for sql in statements {
                    var stmt: OpaquePointer?
                    try prepare(sql, into: &stmt)
                    for (i, rowid) in chunk.enumerated() {
                        bind(stmt, Int32(i + 1), Int64(rowid))
                    }
                    try stepDone(stmt)
                    sqlite3_finalize(stmt)
                }
            }
        }
    }

    /// Remove every message (and its dependent rows) whose `apple_rowid`
    /// is not in `keep`. Called by the indexer after a full upsert pass to
    /// drop rows that Apple's Envelope Index no longer exposes — either
    /// because the message was deleted, or because it's now filtered out
    /// (e.g. draft autosaves with `type=5`, which the reader skips).
    ///
    /// Uses a TEMP table to avoid a 150k-element IN clause. One transaction
    /// so the deletes across the four dependent tables stay consistent.
    func pruneMessagesNotIn(_ keep: Set<Int>) throws {
        try inTransaction {
            try exec("CREATE TEMP TABLE IF NOT EXISTS _keep_rowids(apple_rowid INTEGER PRIMARY KEY)")
            try exec("DELETE FROM _keep_rowids")
            var ins: OpaquePointer?
            try prepare("INSERT INTO _keep_rowids(apple_rowid) VALUES (?)", into: &ins)
            defer { sqlite3_finalize(ins) }
            for rowid in keep {
                sqlite3_reset(ins)
                bind(ins, 1, Int64(rowid))
                try stepDone(ins)
            }
            let staleSubquery = "SELECT apple_rowid FROM messages WHERE apple_rowid NOT IN (SELECT apple_rowid FROM _keep_rowids)"
            try exec("DELETE FROM recipients WHERE message_rowid IN (\(staleSubquery))")
            try exec("DELETE FROM message_labels WHERE message_rowid IN (\(staleSubquery))")
            try exec("DELETE FROM message_links WHERE from_message_rowid IN (\(staleSubquery))")
            try exec("DELETE FROM messages WHERE apple_rowid NOT IN (SELECT apple_rowid FROM _keep_rowids)")
            try exec("DELETE FROM _keep_rowids")
        }
    }

    /// Replace the message_labels rows. Caller passes ALL labels (we DELETE
    /// all then re-INSERT in one transaction). Cheap enough at our scale
    /// (~250k labels) and avoids drift on missed updates.
    func replaceAllMessageLabels(_ pairs: [(messageRowId: Int, mailboxRowId: Int)]) throws {
        try inTransaction {
            try exec("DELETE FROM message_labels;")
            let sql = "INSERT OR IGNORE INTO message_labels(message_rowid, mailbox_rowid) VALUES (?, ?)"
            var stmt: OpaquePointer?
            try prepare(sql, into: &stmt)
            defer { sqlite3_finalize(stmt) }
            for p in pairs {
                sqlite3_reset(stmt)
                bind(stmt, 1, Int64(p.messageRowId))
                bind(stmt, 2, Int64(p.mailboxRowId))
                try stepDone(stmt)
            }
        }
    }

    func upsertMessageLinks(_ rows: [IndexedMessageLink]) throws {
        try inTransaction {
            let froms = Array(Set(rows.map(\.fromMessageRowId)))
            try deleteMessageLinks(fromMessageIds: froms)
            let sql = "INSERT INTO message_links(from_message_rowid, to_message_id_hash, is_parent) VALUES(?,?,?)"
            var stmt: OpaquePointer?
            try prepare(sql, into: &stmt)
            defer { sqlite3_finalize(stmt) }
            for l in rows {
                sqlite3_reset(stmt)
                bind(stmt, 1, Int64(l.fromMessageRowId))
                bind(stmt, 2, l.toMessageIdHash)
                bind(stmt, 3, l.isParent ? 1 : 0)
                try stepDone(stmt)
            }
        }
    }

    /// Replaces all rows in `threads` and updates `messages.thread_id`.
    func replaceThreads(_ threads: [IndexedThread]) throws {
        try inTransaction {
            try exec("DELETE FROM threads;")
            try exec("UPDATE messages SET thread_id = 0;")
            let insertThread = "INSERT INTO threads(thread_id, root_message_rowid, latest_date_received, message_count, unread_count, flagged_count) VALUES(?,?,?,?,?,?)"
            let updateMessage = "UPDATE messages SET thread_id = ? WHERE apple_rowid = ?"
            var insStmt: OpaquePointer?
            var updStmt: OpaquePointer?
            try prepare(insertThread, into: &insStmt)
            defer { sqlite3_finalize(insStmt) }
            try prepare(updateMessage, into: &updStmt)
            defer { sqlite3_finalize(updStmt) }

            for t in threads {
                sqlite3_reset(insStmt)
                bind(insStmt, 1, Int64(t.threadId))
                bind(insStmt, 2, Int64(t.rootMessageRowId))
                bind(insStmt, 3, Int64(t.latestDateReceived))
                bind(insStmt, 4, Int64(t.messageCount))
                bind(insStmt, 5, Int64(t.unreadCount))
                bind(insStmt, 6, Int64(t.flaggedCount))
                try stepDone(insStmt)
                for rowid in t.memberRowIds {
                    sqlite3_reset(updStmt)
                    bind(updStmt, 1, Int64(t.threadId))
                    bind(updStmt, 2, Int64(rowid))
                    try stepDone(updStmt)
                }
            }
        }
    }

    func recomputeMailboxCounts() throws {
        // Counts include both messages whose canonical mailbox is this one AND
        // messages labeled into this mailbox (Gmail labels: a Gmail INBOX
        // message lives canonically in `[Gmail]/All Mail` and is labeled INBOX).
        try exec("""
            UPDATE mailboxes SET
                total_count = (
                    SELECT COUNT(*) FROM (
                        SELECT m.apple_rowid FROM messages m WHERE m.mailbox_rowid = mailboxes.apple_rowid
                        UNION
                        SELECT message_rowid FROM message_labels WHERE message_labels.mailbox_rowid = mailboxes.apple_rowid
                    )
                ),
                unread_count = (
                    SELECT COUNT(*) FROM (
                        SELECT m.apple_rowid FROM messages m
                          WHERE m.mailbox_rowid = mailboxes.apple_rowid AND m.is_read = 0
                        UNION
                        SELECT m.apple_rowid FROM messages m
                          JOIN message_labels l ON l.message_rowid = m.apple_rowid
                          WHERE l.mailbox_rowid = mailboxes.apple_rowid AND m.is_read = 0
                    )
                )
            """)
    }

    /// Incremental FTS update: inserts FTS rows for new messages, removes
    /// rows for messages that no longer exist. Existing rows are NOT touched,
    /// so body content the BodyIndexer populated survives across syncs.
    ///
    /// (Older versions of this method DELETEd everything and re-INSERTed —
    /// which wiped body content every sync, see Schema v5 for the recovery.)
    func incrementalUpdateFTS() throws {
        try inTransaction {
            try exec("""
            INSERT INTO messages_fts(rowid, subject, body_text, sender, recipients, attachment_names)
            SELECT m.apple_rowid,
                   COALESCE(m.subject_prefix, '') || COALESCE(m.subject, ''),
                   '',
                   COALESCE(m.sender_address, '') || ' ' || COALESCE(m.sender_display, ''),
                   COALESCE((
                       SELECT GROUP_CONCAT(COALESCE(r.address, '') || ' ' || COALESCE(r.display, ''), ' ')
                       FROM recipients r WHERE r.message_rowid = m.apple_rowid
                   ), ''),
                   ''
            FROM messages m
            WHERE m.apple_rowid NOT IN (SELECT rowid FROM messages_fts)
            """)
            try exec("""
            DELETE FROM messages_fts
            WHERE rowid NOT IN (SELECT apple_rowid FROM messages)
            """)
        }
    }

    /// Update one message's body text in FTS. Called by BodyIndexer.
    /// Performs DELETE+INSERT (FTS5 doesn't support partial UPDATEs cleanly).
    func setBodyText(messageRowId: Int, bodyText: String) throws {
        try inTransaction {
            // Pull current FTS row contents to preserve other columns.
            var sel: OpaquePointer?
            try prepare("SELECT subject, sender, recipients, attachment_names FROM messages_fts WHERE rowid = ?", into: &sel)
            defer { sqlite3_finalize(sel) }
            bind(sel, 1, Int64(messageRowId))
            var subject = "", sender = "", recipients = "", atts = ""
            if sqlite3_step(sel) == SQLITE_ROW {
                subject = sqlite3_column_text(sel, 0).map { String(cString: $0) } ?? ""
                sender = sqlite3_column_text(sel, 1).map { String(cString: $0) } ?? ""
                recipients = sqlite3_column_text(sel, 2).map { String(cString: $0) } ?? ""
                atts = sqlite3_column_text(sel, 3).map { String(cString: $0) } ?? ""
            }

            var del: OpaquePointer?
            try prepare("DELETE FROM messages_fts WHERE rowid = ?", into: &del)
            defer { sqlite3_finalize(del) }
            bind(del, 1, Int64(messageRowId))
            try stepDone(del)

            var ins: OpaquePointer?
            try prepare("INSERT INTO messages_fts(rowid, subject, body_text, sender, recipients, attachment_names) VALUES (?,?,?,?,?,?)", into: &ins)
            defer { sqlite3_finalize(ins) }
            bind(ins, 1, Int64(messageRowId))
            bind(ins, 2, subject)
            bind(ins, 3, bodyText)
            bind(ins, 4, sender)
            bind(ins, 5, recipients)
            bind(ins, 6, atts)
            try stepDone(ins)

            var upd: OpaquePointer?
            try prepare("UPDATE messages SET body_indexed = 1 WHERE apple_rowid = ?", into: &upd)
            defer { sqlite3_finalize(upd) }
            bind(upd, 1, Int64(messageRowId))
            try stepDone(upd)
        }
    }

    /// Optimistic local update for is_read after a successful AppleScript
    /// write to Mail.app. The next FSEvents-triggered sync confirms it. One
    /// transaction for all rowids — either the whole batch persists or none of
    /// it does, so callers can surface a single error to the user instead of N
    /// silent partial failures.
    func setIsReadBatch(rowids: [Int], isRead: Bool) throws {
        guard !rowids.isEmpty else { return }
        try inTransaction {
            var stmt: OpaquePointer?
            try prepare("UPDATE messages SET is_read = ? WHERE apple_rowid = ?", into: &stmt)
            defer { sqlite3_finalize(stmt) }
            for rowid in rowids {
                sqlite3_reset(stmt)
                bind(stmt, 1, isRead ? 1 : 0)
                bind(stmt, 2, Int64(rowid))
                try stepDone(stmt)
            }
        }
    }

    // MARK: — Write-only helpers

    func deleteRecipients(messageIds: [Int]) throws {
        guard !messageIds.isEmpty else { return }
        let placeholders = messageIds.map { _ in "?" }.joined(separator: ",")
        let sql = "DELETE FROM recipients WHERE message_rowid IN (\(placeholders))"
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        for (idx, id) in messageIds.enumerated() {
            bind(stmt, Int32(idx + 1), Int64(id))
        }
        try stepDone(stmt)
    }

    func deleteMessageLinks(fromMessageIds: [Int]) throws {
        guard !fromMessageIds.isEmpty else { return }
        let placeholders = fromMessageIds.map { _ in "?" }.joined(separator: ",")
        let sql = "DELETE FROM message_links WHERE from_message_rowid IN (\(placeholders))"
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        for (idx, id) in fromMessageIds.enumerated() {
            bind(stmt, Int32(idx + 1), Int64(id))
        }
        try stepDone(stmt)
    }

    func mailboxKind(for m: Mailbox) -> MailboxKind {
        switch m.displayName {
        case "INBOX": return .inbox
        case "Sent Messages", "Sent Mail": return .sent
        case "Drafts": return .drafts
        case "Junk", "Spam": return .junk
        case "Deleted Messages", "Trash": return .trash
        case "Archive": return .archive
        case "All Mail": return .all
        default: return .other
        }
    }
}
