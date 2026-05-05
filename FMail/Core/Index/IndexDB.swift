import Foundation
import SQLite3

/// Actor wrapping FMail's own SQLite database. Not thread-safe externally;
/// all access goes through actor methods.
actor IndexDB {
    nonisolated(unsafe) private var db: OpaquePointer?

    /// Returns `~/Library/Application Support/FMail/index.sqlite`. Creates the
    /// directory if needed.
    static func defaultPath() throws -> String {
        let supportDir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("FMail", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        return supportDir.appendingPathComponent("index.sqlite").path
    }

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        if rc != SQLITE_OK {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            sqlite3_close(handle)
            throw IndexDBError.openFailed(msg)
        }
        self.db = handle
        try Schema.apply(to: handle!)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: — Metadata

    func setMeta(_ key: String, _ value: String) throws {
        let sql = "INSERT INTO index_metadata(key, value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value"
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, key)
        bind(stmt, 2, value)
        try stepDone(stmt)
    }

    func getMeta(_ key: String) throws -> String? {
        var stmt: OpaquePointer?
        try prepare("SELECT value FROM index_metadata WHERE key = ?", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, key)
        if sqlite3_step(stmt) == SQLITE_ROW, let cstr = sqlite3_column_text(stmt, 0) {
            return String(cString: cstr)
        }
        return nil
    }

    // MARK: — Bulk write API

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
                bind(stmt, 8, mailboxKind(for: m))
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

    /// Replace the message_labels rows. Caller passes ALL labels (we DELETE
    /// all then re-INSERT in one transaction). Cheap enough at our scale
    /// (~250k labels) and avoids drift on missed updates.
    func replaceAllMessageLabels(_ pairs: [(messageRowId: Int, mailboxRowId: Int)]) throws {
        try inTransaction {
            try Schema.exec(db!, "DELETE FROM message_labels;")
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
            try Schema.exec(db!, "DELETE FROM threads;")
            try Schema.exec(db!, "UPDATE messages SET thread_id = 0;")
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
        try Schema.exec(db!, """
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
            try Schema.exec(db!, """
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
            try Schema.exec(db!, """
            DELETE FROM messages_fts
            WHERE rowid NOT IN (SELECT apple_rowid FROM messages)
            """)
        }
    }

    /// Force full rebuild — used by manual "Rebuild Index" actions or schema
    /// migrations. Wipes body content; BodyIndexer must be re-run to restore it.
    func rebuildFTS() throws {
        try inTransaction {
            try Schema.exec(db!, "DELETE FROM messages_fts;")
        }
        try incrementalUpdateFTS()
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

    /// Unread messages whose body hasn't been indexed yet AND aren't in a
    /// drafts/trash/junk mailbox. Used by the post-sync auto-fetch hook —
    /// we ask Mail.app to download these so they're readable when the user
    /// opens them. Newest first, so freshly arrived mail wins.
    func fetchUnreadMissingBody(limit: Int) throws -> [(rowid: Int, mailboxRowId: Int, imapUID: Int?, rfcMessageId: String?)] {
        let sql = """
        SELECT m.apple_rowid, m.mailbox_rowid, m.imap_uid, m.rfc_message_id
        FROM messages m
        WHERE m.is_read = 0
          AND m.body_indexed = 0
          AND m.mailbox_rowid NOT IN (SELECT apple_rowid FROM mailboxes WHERE kind IN ('drafts', 'trash', 'junk'))
        ORDER BY m.date_received DESC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, Int64(limit))
        var out: [(Int, Int, Int?, String?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = Int(sqlite3_column_int64(stmt, 0))
            let mboxId = Int(sqlite3_column_int64(stmt, 1))
            let uid: Int? = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 2))
            let rfc = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            out.append((rowid, mboxId, uid, rfc))
        }
        return out.map { (rowid: $0.0, mailboxRowId: $0.1, imapUID: $0.2, rfcMessageId: $0.3) }
    }

    /// Returns up to `limit` messages where body_indexed = 0, oldest-first
    /// (newer mail tends to already be parseable; older mail may need on-demand
    /// fetch from Mail.app and we want to surface gaps early).
    func fetchUnindexedBodyMessages(limit: Int) throws -> [(rowid: Int, mailboxRowId: Int)] {
        var stmt: OpaquePointer?
        try prepare("""
            SELECT apple_rowid, mailbox_rowid
            FROM messages
            WHERE body_indexed = 0
            ORDER BY apple_rowid DESC
            LIMIT ?
            """, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, Int64(limit))
        var out: [(Int, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((Int(sqlite3_column_int64(stmt, 0)), Int(sqlite3_column_int64(stmt, 1))))
        }
        return out.map { (rowid: $0.0, mailboxRowId: $0.1) }
    }

    func countUnindexedBody() throws -> Int {
        var stmt: OpaquePointer?
        try prepare("SELECT COUNT(*) FROM messages WHERE body_indexed = 0", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: — Contact address preferences (Phase 4)

    struct ContactPrefs: Sendable, Equatable {
        let contactId: String
        let preferredAddress: String?
        let blockedAddresses: Set<String>
    }

    func loadContactPrefs(contactId: String) throws -> ContactPrefs {
        var stmt: OpaquePointer?
        try prepare("SELECT preferred_address, blocked_addresses FROM contact_prefs WHERE contact_id = ?", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, contactId)
        if sqlite3_step(stmt) == SQLITE_ROW {
            let preferred = sqlite3_column_text(stmt, 0).map { String(cString: $0) }
            let blockedJson = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "[]"
            let blocked = Self.decodeStringArray(blockedJson)
            return ContactPrefs(contactId: contactId, preferredAddress: preferred, blockedAddresses: Set(blocked))
        }
        return ContactPrefs(contactId: contactId, preferredAddress: nil, blockedAddresses: [])
    }

    func setPreferredAddress(contactId: String, address: String?) throws {
        let existing = try loadContactPrefs(contactId: contactId)
        try writeContactPrefs(ContactPrefs(
            contactId: contactId,
            preferredAddress: address,
            blockedAddresses: existing.blockedAddresses
        ))
    }

    func addBlockedAddress(contactId: String, address: String) throws {
        var existing = try loadContactPrefs(contactId: contactId)
        var blocked = existing.blockedAddresses
        blocked.insert(address.lowercased())
        try writeContactPrefs(ContactPrefs(
            contactId: contactId,
            preferredAddress: existing.preferredAddress == address ? nil : existing.preferredAddress,
            blockedAddresses: blocked
        ))
        _ = existing
    }

    func removeBlockedAddress(contactId: String, address: String) throws {
        let existing = try loadContactPrefs(contactId: contactId)
        var blocked = existing.blockedAddresses
        blocked.remove(address.lowercased())
        try writeContactPrefs(ContactPrefs(
            contactId: contactId,
            preferredAddress: existing.preferredAddress,
            blockedAddresses: blocked
        ))
    }

    func loadAllContactPrefs() throws -> [ContactPrefs] {
        var stmt: OpaquePointer?
        try prepare("SELECT contact_id, preferred_address, blocked_addresses FROM contact_prefs", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        var out: [ContactPrefs] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let cid = String(cString: sqlite3_column_text(stmt, 0))
            let preferred = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let blockedJson = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "[]"
            out.append(ContactPrefs(
                contactId: cid,
                preferredAddress: preferred,
                blockedAddresses: Set(Self.decodeStringArray(blockedJson))
            ))
        }
        return out
    }

    private func writeContactPrefs(_ p: ContactPrefs) throws {
        let blockedJson = Self.encodeStringArray(Array(p.blockedAddresses).sorted())
        let sql = """
        INSERT INTO contact_prefs(contact_id, preferred_address, blocked_addresses)
        VALUES (?, ?, ?)
        ON CONFLICT(contact_id) DO UPDATE SET
            preferred_address = excluded.preferred_address,
            blocked_addresses = excluded.blocked_addresses
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, p.contactId)
        bindOptional(stmt, 2, p.preferredAddress)
        bind(stmt, 3, blockedJson)
        try stepDone(stmt)
    }

    private static func encodeStringArray(_ a: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: a, options: []) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func decodeStringArray(_ s: String) -> [String] {
        guard let data = s.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return arr
    }

    /// Optimistic local update for is_read after a successful AppleScript
    /// write to Mail.app. The next FSEvents-triggered sync confirms it.
    func setIsRead(rowid: Int, isRead: Bool) throws {
        var stmt: OpaquePointer?
        try prepare("UPDATE messages SET is_read = ? WHERE apple_rowid = ?", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, isRead ? 1 : 0)
        bind(stmt, 2, Int64(rowid))
        try stepDone(stmt)
    }

    func threadId(forMessage rowid: Int) throws -> Int? {
        var stmt: OpaquePointer?
        try prepare("SELECT thread_id FROM messages WHERE apple_rowid = ?", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, Int64(rowid))
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return nil
    }

    func countTotalMessages() throws -> Int {
        var stmt: OpaquePointer?
        try prepare("SELECT COUNT(*) FROM messages", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Run a compiled search query and return matched messages, newest first
    /// (or by FTS rank when an FTS expression was supplied).
    func search(_ q: CompiledQuery, limit: Int = 200) throws -> [MessageHeader] {
        var sql: String
        var bindings: [SQLBinding] = []

        // Search always excludes drafts/trash/junk (canonical or label),
        // matching the All Mailboxes view. To search inside one of those
        // explicitly, navigate to that mailbox first — search is global
        // by design.
        if !q.ftsExpression.isEmpty {
            // FTS5's MATCH operator requires the literal table name on the LHS;
            // an alias is interpreted as a column, hence the join uses the full
            // table name throughout.
            sql = """
            SELECT m.apple_rowid, m.mailbox_rowid,
                   COALESCE(m.subject_prefix, '') || m.subject,
                   m.sender_address, m.sender_display,
                   m.date_sent, m.date_received,
                   m.is_read, m.is_flagged, m.rfc_message_id, m.imap_uid
            FROM messages_fts
            JOIN messages m ON m.apple_rowid = messages_fts.rowid
            WHERE messages_fts MATCH ?
              AND \(Self.systemMailboxExcludeFilter)
            """
            bindings.append(.text(q.ftsExpression))
            if !q.sqlConditions.isEmpty {
                sql += " AND " + q.sqlConditions
                bindings.append(contentsOf: q.bindings)
            }
            sql += " ORDER BY m.date_received DESC LIMIT ?"
        } else if !q.sqlConditions.isEmpty {
            sql = """
            SELECT m.apple_rowid, m.mailbox_rowid,
                   COALESCE(m.subject_prefix, '') || m.subject,
                   m.sender_address, m.sender_display,
                   m.date_sent, m.date_received,
                   m.is_read, m.is_flagged, m.rfc_message_id, m.imap_uid
            FROM messages m
            WHERE \(q.sqlConditions)
              AND \(Self.systemMailboxExcludeFilter)
            ORDER BY m.date_received DESC LIMIT ?
            """
            bindings.append(contentsOf: q.bindings)
        } else {
            return []
        }
        bindings.append(.int(Int64(limit)))

        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        for (i, b) in bindings.enumerated() {
            switch b {
            case .int(let v): sqlite3_bind_int64(stmt, Int32(i + 1), v)
            case .text(let s): bind(stmt, Int32(i + 1), s)
            }
        }

        var out: [MessageHeader] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = Int(sqlite3_column_int64(stmt, 0))
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
            out.append(MessageHeader(
                rowId: rowid, mailboxRowId: mboxId, subject: subject,
                senderAddress: sa, senderDisplay: sd,
                dateSent: ds > 0 ? Date(timeIntervalSince1970: TimeInterval(ds)) : nil,
                dateReceived: dr > 0 ? Date(timeIntervalSince1970: TimeInterval(dr)) : nil,
                isRead: read, isFlagged: flagged, rfcMessageId: rfcId, imapUID: uid
            ))
        }
        return out
    }

    // MARK: — Read API for UI

    func loadMailboxes() throws -> [Mailbox] {
        var stmt: OpaquePointer?
        try prepare("SELECT apple_rowid, account_uuid, path, name, hidden, total_count, unread_count, kind FROM mailboxes ORDER BY name", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        var out: [Mailbox] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = Int(sqlite3_column_int64(stmt, 0))
            let acctUUID = String(cString: sqlite3_column_text(stmt, 1))
            let path = String(cString: sqlite3_column_text(stmt, 2))
            let pathComponents = path.split(separator: "/").map(String.init)
            let total = Int(sqlite3_column_int64(stmt, 5))
            let unread = Int(sqlite3_column_int64(stmt, 6))
            let hidden = sqlite3_column_int(stmt, 4) != 0
            let kind = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "other"
            out.append(Mailbox(
                rowId: rowid,
                accountUUID: acctUUID,
                pathComponents: pathComponents,
                totalCount: total,
                unreadCount: unread,
                hidden: hidden,
                kind: kind
            ))
        }
        return out
    }

    func loadAccounts() throws -> [MailAccount] {
        var stmt: OpaquePointer?
        try prepare("SELECT uuid, display_name, email_address FROM accounts ORDER BY display_name", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        var out: [MailAccount] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let uuid = String(cString: sqlite3_column_text(stmt, 0))
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let email = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            out.append(MailAccount(uuid: uuid, displayName: name, emailAddress: email))
        }
        return out
    }

    /// Count of unread messages across the entire index, excluding
    /// drafts/trash/junk — badge for the "All Mailboxes" sidebar row.
    /// Filters by *both* canonical mailbox kind *and* labels (Gmail's spam
    /// lives canonically in `[Gmail]/All Mail` and is only marked spam via
    /// a label in the `message_labels` table).
    func countAllUnreadExcludingDrafts() throws -> Int {
        var stmt: OpaquePointer?
        try prepare("""
            SELECT COUNT(*) FROM messages m
            WHERE m.is_read = 0
              AND \(Self.systemMailboxExcludeFilter)
            """, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// SQL fragment that filters out messages whose canonical mailbox OR any
    /// of its labels is a drafts / trash / junk / spam mailbox. Inlined into
    /// every "user-facing list" query so junk-folder mail doesn't bleed into
    /// global views.
    private static let systemMailboxExcludeFilter = """
        m.mailbox_rowid NOT IN (
            SELECT apple_rowid FROM mailboxes WHERE kind IN ('drafts', 'trash', 'junk')
        )
        AND m.apple_rowid NOT IN (
            SELECT message_rowid FROM message_labels
            WHERE mailbox_rowid IN (
                SELECT apple_rowid FROM mailboxes WHERE kind IN ('drafts', 'trash', 'junk')
            )
        )
        """

    /// "All Mailboxes" view: every thread that contains at least one message
    /// outside drafts/trash/junk, newest first.
    func loadAllThreadSummaries(limit: Int = 500) throws -> [ThreadSummary] {
        let sql = """
        WITH visible AS (
            SELECT m.apple_rowid, m.thread_id, m.date_received, m.is_read, m.is_flagged
            FROM messages m
            WHERE \(Self.systemMailboxExcludeFilter)
        ),
        thread_data AS (
            SELECT thread_id,
                   MAX(date_received) AS latest,
                   COUNT(apple_rowid) AS local_count,
                   SUM(CASE WHEN is_read = 0 THEN 1 ELSE 0 END) AS unread_count,
                   SUM(CASE WHEN is_flagged = 1 THEN 1 ELSE 0 END) AS flagged_count
            FROM visible
            GROUP BY thread_id
        )
        SELECT thread_id, latest, local_count, unread_count, flagged_count
        FROM thread_data
        ORDER BY latest DESC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, Int64(limit))
        var out: [ThreadSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let tid = Int(sqlite3_column_int64(stmt, 0))
            let latest = Int(sqlite3_column_int64(stmt, 1))
            let local = Int(sqlite3_column_int64(stmt, 2))
            let unread = Int(sqlite3_column_int64(stmt, 3))
            let flagged = Int(sqlite3_column_int64(stmt, 4))
            let repr = try latestNonDraftMessageOfThread(threadId: tid)
            out.append(ThreadSummary(
                threadId: tid,
                latestDateReceived: latest > 0 ? Date(timeIntervalSince1970: TimeInterval(latest)) : nil,
                messageCount: local,
                unreadCount: unread,
                flaggedCount: flagged,
                latestSubject: repr?.subject ?? "",
                latestSenderDisplay: repr?.sender ?? "",
                latestMessageRowId: repr?.rowId ?? 0
            ))
        }
        return out
    }

    private func latestNonDraftMessageOfThread(threadId: Int) throws -> (rowId: Int, subject: String, sender: String)? {
        let sql = """
        SELECT m.apple_rowid, m.subject_prefix, m.subject, COALESCE(m.sender_display, m.sender_address, '')
        FROM messages m
        WHERE m.thread_id = ?
          AND \(Self.systemMailboxExcludeFilter)
        ORDER BY m.date_received DESC
        LIMIT 1
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, Int64(threadId))
        if sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = Int(sqlite3_column_int64(stmt, 0))
            let prefix = String(cString: sqlite3_column_text(stmt, 1))
            let subj = String(cString: sqlite3_column_text(stmt, 2))
            let sender = String(cString: sqlite3_column_text(stmt, 3))
            return (rowid, prefix + subj, sender)
        }
        return nil
    }

    /// Returns thread summaries in a mailbox, newest thread first.
    /// Includes messages whose canonical mailbox is this one OR which are
    /// labelled into this mailbox (Gmail).
    func loadThreadSummaries(mailboxRowId: Int, limit: Int = 500) throws -> [ThreadSummary] {
        let sql = """
        WITH mailbox_messages AS (
            SELECT apple_rowid FROM messages WHERE mailbox_rowid = ?
            UNION
            SELECT message_rowid AS apple_rowid FROM message_labels WHERE mailbox_rowid = ?
        ),
        thread_data AS (
            SELECT t.thread_id,
                   t.message_count,
                   t.unread_count,
                   t.flagged_count,
                   MAX(m.date_received) AS latest,
                   COUNT(m.apple_rowid) AS local_count
            FROM threads t
            JOIN messages m ON m.thread_id = t.thread_id
            WHERE m.apple_rowid IN (SELECT apple_rowid FROM mailbox_messages)
            GROUP BY t.thread_id
        )
        SELECT thread_id, latest, local_count, unread_count, flagged_count
        FROM thread_data
        ORDER BY latest DESC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, Int64(mailboxRowId))
        bind(stmt, 2, Int64(mailboxRowId))
        bind(stmt, 3, Int64(limit))
        var out: [ThreadSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let tid = Int(sqlite3_column_int64(stmt, 0))
            let latest = Int(sqlite3_column_int64(stmt, 1))
            let local = Int(sqlite3_column_int64(stmt, 2))
            let unread = Int(sqlite3_column_int64(stmt, 3))
            let flagged = Int(sqlite3_column_int64(stmt, 4))
            // Pull representative message info (latest in the thread within this mailbox).
            let repr = try latestMessageOfThreadInMailbox(threadId: tid, mailboxRowId: mailboxRowId)
            out.append(ThreadSummary(
                threadId: tid,
                latestDateReceived: latest > 0 ? Date(timeIntervalSince1970: TimeInterval(latest)) : nil,
                messageCount: local,
                unreadCount: unread,
                flaggedCount: flagged,
                latestSubject: repr?.subject ?? "",
                latestSenderDisplay: repr?.sender ?? "",
                latestMessageRowId: repr?.rowId ?? 0
            ))
        }
        return out
    }

    enum ThreadViewScope {
        /// User is browsing the Drafts/Trash/Junk mailbox itself — show
        /// everything in the thread including those.
        case includeAll
        /// Default: hide drafts only (the messages still being composed).
        case excludeDrafts
        /// "All Mailboxes" view: hide drafts AND trash AND junk.
        case excludeAllSystem
    }

    func loadThreadMessages(threadId: Int, scope: ThreadViewScope = .excludeDrafts) throws -> [MessageHeader] {
        let filter: String
        switch scope {
        case .includeAll:
            filter = ""
        case .excludeDrafts:
            filter = " AND m.mailbox_rowid NOT IN (SELECT apple_rowid FROM mailboxes WHERE kind = 'drafts')"
        case .excludeAllSystem:
            filter = " AND \(Self.systemMailboxExcludeFilter)"
        }
        let sql = """
        SELECT m.apple_rowid, m.mailbox_rowid, m.subject, m.subject_prefix,
               m.sender_address, m.sender_display, m.date_sent, m.date_received,
               m.is_read, m.is_flagged, m.rfc_message_id, m.imap_uid
        FROM messages m
        WHERE m.thread_id = ?\(filter)
        ORDER BY m.date_received ASC
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, Int64(threadId))
        return try collectMessages(stmt)
    }

    func loadMessagesInMailbox(mailboxRowId: Int, limit: Int = 500) throws -> [MessageHeader] {
        let sql = """
        SELECT apple_rowid, mailbox_rowid, subject, subject_prefix,
               sender_address, sender_display, date_sent, date_received,
               is_read, is_flagged, rfc_message_id
        FROM messages
        WHERE mailbox_rowid = ?
           OR apple_rowid IN (SELECT message_rowid FROM message_labels WHERE mailbox_rowid = ?)
        ORDER BY date_received DESC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, Int64(mailboxRowId))
        bind(stmt, 2, Int64(mailboxRowId))
        bind(stmt, 3, Int64(limit))
        return try collectMessages(stmt)
    }

    // MARK: — Internals used by ThreadGrouper

    /// Streams (apple_rowid, apple_message_id_hash, date_received, is_read, is_flagged)
    /// for all messages. Used by ThreadGrouper to build components in memory.
    func snapshotMessagesForThreading() throws -> [(rowid: Int, hash: Int64, date: Int, isRead: Bool, isFlagged: Bool)] {
        var stmt: OpaquePointer?
        try prepare("SELECT apple_rowid, apple_message_id_hash, COALESCE(date_received, 0), is_read, is_flagged FROM messages", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        var out: [(Int, Int64, Int, Bool, Bool)] = []
        out.reserveCapacity(200_000)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((
                Int(sqlite3_column_int64(stmt, 0)),
                sqlite3_column_int64(stmt, 1),
                Int(sqlite3_column_int64(stmt, 2)),
                sqlite3_column_int(stmt, 3) != 0,
                sqlite3_column_int(stmt, 4) != 0
            ))
        }
        return out.map { (rowid: $0.0, hash: $0.1, date: $0.2, isRead: $0.3, isFlagged: $0.4) }
    }

    func snapshotMessageLinks() throws -> [(from: Int, toHash: Int64)] {
        var stmt: OpaquePointer?
        try prepare("SELECT from_message_rowid, to_message_id_hash FROM message_links", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        var out: [(Int, Int64)] = []
        out.reserveCapacity(200_000)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((Int(sqlite3_column_int64(stmt, 0)), sqlite3_column_int64(stmt, 1)))
        }
        return out.map { (from: $0.0, toHash: $0.1) }
    }

    // MARK: — Helpers

    private func latestMessageOfThreadInMailbox(threadId: Int, mailboxRowId: Int) throws -> (rowId: Int, subject: String, sender: String)? {
        let sql = """
        SELECT m.apple_rowid, m.subject_prefix, m.subject, COALESCE(m.sender_display, m.sender_address, '')
        FROM messages m
        WHERE m.thread_id = ?
          AND (m.mailbox_rowid = ?
               OR m.apple_rowid IN (SELECT message_rowid FROM message_labels WHERE mailbox_rowid = ?))
        ORDER BY m.date_received DESC
        LIMIT 1
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, Int64(threadId))
        bind(stmt, 2, Int64(mailboxRowId))
        bind(stmt, 3, Int64(mailboxRowId))
        if sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = Int(sqlite3_column_int64(stmt, 0))
            let prefix = String(cString: sqlite3_column_text(stmt, 1))
            let subj = String(cString: sqlite3_column_text(stmt, 2))
            let sender = String(cString: sqlite3_column_text(stmt, 3))
            return (rowid, prefix + subj, sender)
        }
        return nil
    }

    private func collectMessages(_ stmt: OpaquePointer?) throws -> [MessageHeader] {
        var out: [MessageHeader] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = Int(sqlite3_column_int64(stmt, 0))
            let mailboxRowId = Int(sqlite3_column_int64(stmt, 1))
            let subject = String(cString: sqlite3_column_text(stmt, 2))
            let prefix = String(cString: sqlite3_column_text(stmt, 3))
            let sa = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let sd = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
            let ds = sqlite3_column_int64(stmt, 6)
            let dr = sqlite3_column_int64(stmt, 7)
            let read = sqlite3_column_int(stmt, 8) != 0
            let flagged = sqlite3_column_int(stmt, 9) != 0
            let rfcId = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
            let uidVal = sqlite3_column_int64(stmt, 11)
            let uid: Int? = sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : Int(uidVal)
            out.append(MessageHeader(
                rowId: rowid,
                mailboxRowId: mailboxRowId,
                subject: prefix + subject,
                senderAddress: sa,
                senderDisplay: sd,
                dateSent: ds > 0 ? Date(timeIntervalSince1970: TimeInterval(ds)) : nil,
                dateReceived: dr > 0 ? Date(timeIntervalSince1970: TimeInterval(dr)) : nil,
                isRead: read,
                isFlagged: flagged,
                rfcMessageId: rfcId,
                imapUID: uid
            ))
        }
        return out
    }

    private func deleteRecipients(messageIds: [Int]) throws {
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

    private func deleteMessageLinks(fromMessageIds: [Int]) throws {
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

    private func mailboxKind(for m: Mailbox) -> String {
        switch m.displayName {
        case "INBOX": return "inbox"
        case "Sent Messages", "Sent Mail": return "sent"
        case "Drafts": return "drafts"
        case "Junk", "Spam": return "junk"
        case "Deleted Messages", "Trash": return "trash"
        case "Archive": return "archive"
        case "All Mail": return "all"
        default: return "other"
        }
    }

    // MARK: — Low-level helpers

    private func inTransaction(_ work: () throws -> Void) throws {
        try Schema.exec(db!, "BEGIN TRANSACTION;")
        do {
            try work()
            try Schema.exec(db!, "COMMIT;")
        } catch {
            try? Schema.exec(db!, "ROLLBACK;")
            throw error
        }
    }

    private func prepare(_ sql: String, into stmt: inout OpaquePointer?) throws {
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc != SQLITE_OK {
            throw IndexDBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func stepDone(_ stmt: OpaquePointer?) throws {
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            throw IndexDBError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private nonisolated func bind(_ stmt: OpaquePointer?, _ pos: Int32, _ value: String) {
        sqlite3_bind_text(stmt, pos, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private nonisolated func bind(_ stmt: OpaquePointer?, _ pos: Int32, _ value: Int) {
        sqlite3_bind_int64(stmt, pos, Int64(value))
    }

    private nonisolated func bind(_ stmt: OpaquePointer?, _ pos: Int32, _ value: Int64) {
        sqlite3_bind_int64(stmt, pos, value)
    }

    private nonisolated func bindOptional(_ stmt: OpaquePointer?, _ pos: Int32, _ value: String?) {
        if let v = value {
            bind(stmt, pos, v)
        } else {
            sqlite3_bind_null(stmt, pos)
        }
    }

    private nonisolated func bindOptional(_ stmt: OpaquePointer?, _ pos: Int32, _ value: Int?) {
        if let v = value {
            bind(stmt, pos, v)
        } else {
            sqlite3_bind_null(stmt, pos)
        }
    }
}

// MARK: — Wire types

struct IndexedMessage {
    let appleRowId: Int
    let appleMessageIdHash: Int64
    let mailboxRowId: Int
    let accountUUID: String
    let subject: String
    let subjectPrefix: String
    let subjectNormalized: String
    let senderAddress: String?
    let senderDisplay: String?
    let dateSent: Int?
    let dateReceived: Int?
    let isRead: Bool
    let isFlagged: Bool
    let hasAttachment: Bool
    let rfcMessageId: String?
    let imapUID: Int?
}

struct IndexedRecipient {
    let messageRowId: Int
    let kind: Int       // 0=to, 1=cc, 2=bcc, 3=from
    let position: Int
    let address: String
    let display: String?
}

struct IndexedMessageLink {
    let fromMessageRowId: Int
    let toMessageIdHash: Int64
    let isParent: Bool
}

struct IndexedThread {
    let threadId: Int
    let rootMessageRowId: Int
    let latestDateReceived: Int
    let messageCount: Int
    let unreadCount: Int
    let flaggedCount: Int
    let memberRowIds: [Int]
}

struct ThreadSummary: Identifiable, Hashable {
    let threadId: Int
    let latestDateReceived: Date?
    let messageCount: Int
    let unreadCount: Int
    let flaggedCount: Int
    let latestSubject: String
    let latestSenderDisplay: String
    let latestMessageRowId: Int
    var id: Int { threadId }
}
