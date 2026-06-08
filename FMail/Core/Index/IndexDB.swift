import Foundation
import SQLite3

/// Actor wrapping FMail's own SQLite database. Not thread-safe externally;
/// all access goes through actor methods.
actor IndexDB {
    // Immutable after init. `unsafe` only because the nonisolated deinit
    // closes the (non-Sendable) handle; `let` makes the immutability explicit
    // and lets every call site use `db` directly instead of `db!`.
    nonisolated(unsafe) private let db: OpaquePointer

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
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            sqlite3_close(handle)
            throw IndexDBError.openFailed(msg)
        }
        self.db = handle
        try Schema.apply(to: handle)
        // Connection-scoped scratch tables holding the current "priority
        // senders" set: exact lowercased addresses (`priority_addr`) and
        // lowercased GLOB patterns like `*savills*` (`priority_pat`). Rebuilt by
        // `updatePrioritySet`; joined against by the menu's Priority/Other
        // split. Created here so the split queries can reference them before the
        // first update.
        try Schema.exec(handle, "CREATE TEMP TABLE IF NOT EXISTS priority_addr(addr TEXT PRIMARY KEY)")
        try Schema.exec(handle, "CREATE TEMP TABLE IF NOT EXISTS priority_pat(pat TEXT PRIMARY KEY)")
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

    // MARK: — Body-index read queries

    /// Unread messages whose body hasn't been indexed yet AND aren't in a
    /// drafts/trash/junk mailbox. Used by the post-sync auto-fetch hook —
    /// we ask Mail.app to download these so they're readable when the user
    /// opens them. Newest first, so freshly arrived mail wins. `limit: nil`
    /// means no LIMIT clause — fetch everything.
    func fetchUnreadMissingBody(limit: Int?) throws -> [(rowid: Int, mailboxRowId: Int, imapUID: Int?, rfcMessageId: String?)] {
        let sql = """
        SELECT m.apple_rowid, m.mailbox_rowid, m.imap_uid, m.rfc_message_id
        FROM messages m
        WHERE m.is_read = 0
          AND m.body_indexed = 0
          AND m.mailbox_rowid NOT IN (SELECT apple_rowid FROM mailboxes WHERE kind IN ('drafts', 'trash', 'junk'))
        ORDER BY m.date_received DESC
        \(limit.map { "LIMIT \($0)" } ?? "")
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
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

    /// One-shot rowid → effective-thread-id map. Used by the optimistic-flip
    /// path to update every affected thread's summary in
    /// `threadsForSelectedMailbox`, not just the currently open one. Returns
    /// the synthetic singleton id (apple_rowid) for unthreaded messages so
    /// the keys match the ids displayed in the thread list.
    func threadIds(forMessages rowids: [Int]) throws -> [Int: Int] {
        guard !rowids.isEmpty else { return [:] }
        let placeholders = rowids.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT apple_rowid, \(Self.effectiveThreadIdExpr) FROM messages m WHERE apple_rowid IN (\(placeholders))"
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        for (i, id) in rowids.enumerated() {
            bind(stmt, Int32(i + 1), Int64(id))
        }
        var out: [Int: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = Int(sqlite3_column_int64(stmt, 0))
            let tid = Int(sqlite3_column_int64(stmt, 1))
            out[rowid] = tid
        }
        return out
    }

    /// Run a compiled search query and return matched messages. The
    /// compiled query is a single SQL boolean expression on `messages m`;
    /// text predicates compile to `apple_rowid IN (SELECT rowid FROM messages_fts ...)`
    /// subqueries, so AND / OR / NOT all compose natively here. Search always
    /// excludes drafts/trash/junk (canonical or label) — to search inside one
    /// of those, navigate to that mailbox first.
    ///
    /// `sort`:
    ///   .newestFirst (default): ORDER BY date_received DESC
    ///   .oldestFirst:           ORDER BY date_received ASC
    ///   .relevance:             ORDER BY rowid (proxy — true relevance
    ///                           would need bm25() through messages_fts,
    ///                           which requires restructuring the query
    ///                           since text predicates compile to IN subqueries)
    func search(_ q: CompiledQuery, limit: Int = 200, sort: SearchSort = .newestFirst) throws -> [MessageHeader] {
        guard q.hasAnyConstraint else { return [] }

        let orderBy: String
        switch sort {
        case .newestFirst: orderBy = "m.date_received DESC"
        case .oldestFirst: orderBy = "m.date_received ASC"
        case .relevance:   orderBy = "m.date_received DESC"  // fallback
        }

        let sql = """
        SELECT \(Self.messageHeaderSelectList)
        FROM messages m
        WHERE (\(q.whereClause))
          AND \(Self.systemMailboxExcludeFilter)
        ORDER BY \(orderBy) LIMIT ?
        """
        var bindings = q.bindings
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
        return Self.collectMessageHeaders(stmt)
    }

    // MARK: — Read API for UI

    // NOTE: the bare `String(cString:)` reads below (and in `loadAccounts` /
    // `decodeRepresentative`) are crash-safe only because these columns are
    // declared `NOT NULL DEFAULT ''` in `Schema`. A future migration that
    // makes one of them nullable must switch that read to the NULL-safe
    // `.map { String(cString:) } ?? ""` form.
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
            let kindStr = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
            let kind = kindStr.flatMap(MailboxKind.init(rawValue:)) ?? .other
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
    static let systemMailboxExcludeFilter = """
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
        SELECT \(Self.messageHeaderSelectList)
        FROM messages m
        WHERE \(Self.threadScopePredicate)\(filter)
        ORDER BY m.date_received ASC
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, Int64(threadId))
        bind(stmt, 2, Int64(threadId))
        return Self.collectMessageHeaders(stmt)
    }

    // MARK: — Internals used by ThreadGrouper

    /// `apple_rowid → is_read` for every indexed message. Backs the flag-only
    /// reconcile (compared against Apple's Envelope Index `read` column).
    func snapshotReadFlags() throws -> [Int: Bool] {
        var stmt: OpaquePointer?
        try prepare("SELECT apple_rowid, is_read FROM messages", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        var out: [Int: Bool] = [:]
        out.reserveCapacity(200_000)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out[Int(sqlite3_column_int64(stmt, 0))] = sqlite3_column_int(stmt, 1) != 0
        }
        return out
    }

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

    /// SQL expression: the effective thread id for a row. Real thread_id
    /// when set (>0); apple_rowid as a synthetic id when the message hasn't
    /// been threaded yet (thread_id = 0). Real thread ids are
    /// `min(memberRowIds)`, so a rowid never equals a real thread id unless
    /// the message is in that thread — by definition impossible for an
    /// unthreaded message. So the namespaces don't overlap.
    static let effectiveThreadIdExpr = """
        CASE WHEN m.thread_id = 0 THEN m.apple_rowid ELSE m.thread_id END
        """

    /// SQL fragment used in the thread-scoped lookups (latest representative,
    /// load thread messages). Matches both real-thread members and a single
    /// synthetic-id message (an unthreaded one whose apple_rowid equals the
    /// supplied id). Bind the same value to both `?`s.
    static let threadScopePredicate = """
        (m.thread_id = ? OR (m.thread_id = 0 AND m.apple_rowid = ?))
        """

    /// Shared SELECT list for the 12 columns `decodeMessageHeader` expects,
    /// with the `m.` alias and the subject prefix already concatenated.
    /// Reused by `search`, `loadThreadMessages`, and `loadMessage` so the
    /// column order can't drift between query and decoder.
    static let messageHeaderSelectList = """
        m.apple_rowid, m.mailbox_rowid,
        COALESCE(m.subject_prefix, '') || m.subject,
        m.sender_address, m.sender_display,
        m.date_sent, m.date_received,
        m.is_read, m.is_flagged, m.rfc_message_id, m.imap_uid,
        m.has_attachment
        """

    /// Decode one `MessageHeader` from a row shaped like
    /// `messageHeaderSelectList`. Caller must have stepped to `SQLITE_ROW`.
    nonisolated static func decodeMessageHeader(_ stmt: OpaquePointer?) -> MessageHeader {
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
        let uid: Int? = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 10))
        let hasAttachment = sqlite3_column_int(stmt, 11) != 0
        return MessageHeader(
            rowId: rowid, mailboxRowId: mboxId, subject: subject,
            senderAddress: sa, senderDisplay: sd,
            dateSent: ds > 0 ? Date(timeIntervalSince1970: TimeInterval(ds)) : nil,
            dateReceived: dr > 0 ? Date(timeIntervalSince1970: TimeInterval(dr)) : nil,
            isRead: read, isFlagged: flagged, hasAttachment: hasAttachment,
            rfcMessageId: rfcId, imapUID: uid
        )
    }

    /// Decode every remaining row as a `MessageHeader`.
    nonisolated static func collectMessageHeaders(_ stmt: OpaquePointer?) -> [MessageHeader] {
        var out: [MessageHeader] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(decodeMessageHeader(stmt))
        }
        return out
    }

    // MARK: — Low-level helpers
    //
    // `db` is private to this file; the helpers below (`exec`, `inTransaction`,
    // `prepare`, `stepDone`, `bind*`) are the only seam through which the
    // IndexDB extensions in other files (IndexDB+Write, IndexDB+ThreadList,
    // IndexDB+MCP) reach SQLite. External callers should still go through the
    // typed APIs.

    /// Run a single statement with no bindings/results.
    func exec(_ sql: String) throws {
        try Schema.exec(db, sql)
    }

    func inTransaction(_ work: () throws -> Void) throws {
        try exec("BEGIN TRANSACTION;")
        do {
            try work()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    func prepare(_ sql: String, into stmt: inout OpaquePointer?) throws {
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc != SQLITE_OK {
            throw IndexDBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func stepDone(_ stmt: OpaquePointer?) throws {
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            throw IndexDBError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    nonisolated func bind(_ stmt: OpaquePointer?, _ pos: Int32, _ value: String) {
        sqlite3_bind_text(stmt, pos, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    nonisolated func bind(_ stmt: OpaquePointer?, _ pos: Int32, _ value: Int) {
        sqlite3_bind_int64(stmt, pos, Int64(value))
    }

    nonisolated func bind(_ stmt: OpaquePointer?, _ pos: Int32, _ value: Int64) {
        sqlite3_bind_int64(stmt, pos, value)
    }

    nonisolated func bindOptional(_ stmt: OpaquePointer?, _ pos: Int32, _ value: String?) {
        if let v = value {
            bind(stmt, pos, v)
        } else {
            sqlite3_bind_null(stmt, pos)
        }
    }

    nonisolated func bindOptional(_ stmt: OpaquePointer?, _ pos: Int32, _ value: Int?) {
        if let v = value {
            bind(stmt, pos, v)
        } else {
            sqlite3_bind_null(stmt, pos)
        }
    }
}
