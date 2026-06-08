import Foundation
import SQLite3

// Backs the menu's "Priority Messages" / "Other Messages" split. A sender is
// *priority* when its address is in the connection-scoped `priority_addr`
// scratch table (exact matches) or matches a `priority_pat` GLOB pattern (e.g.
// `*savills*`). The model fills these from (everyone you've emailed) ∪ (the
// hand-edited supplemental list). These queries just join against them.
extension IndexDB {
    /// Distinct lowercased addresses you've sent mail to — the auto-prefill for
    /// the priority set. "Sent by you" = the message's sender is one of your
    /// accounts' addresses; recipients counted are To/Cc/Bcc (kinds 0/1/2).
    func sentToAddresses() throws -> Set<String> {
        let sql = """
        SELECT DISTINCT lower(r.address)
        FROM recipients r
        WHERE r.kind IN (0, 1, 2)
          AND r.address IS NOT NULL AND r.address <> ''
          AND r.message_rowid IN (
              SELECT m.apple_rowid FROM messages m
              WHERE m.sender_address IS NOT NULL
                AND lower(m.sender_address) IN (
                    SELECT lower(email_address) FROM accounts
                    WHERE email_address IS NOT NULL AND email_address <> ''
                )
          )
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        var out = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.insert(String(cString: c)) }
        }
        return out
    }

    /// Recent distinct senders you've *received* mail from — the pool the
    /// settings "add from recent" dropdown draws on. Incoming = sender isn't one
    /// of your own accounts; newest first; system mailboxes excluded.
    func recentReceivedFromAddresses(limit: Int) throws -> [RecentSender] {
        // `COALESCE(sender_display,'')` is a bare column alongside a single
        // MAX() aggregate: SQLite takes it from the row holding that MAX, so the
        // display name comes from the most recent message — no correlated
        // subquery needed.
        let sql = """
        SELECT m.sender_address, COALESCE(m.sender_display, ''), MAX(m.date_received) AS latest
        FROM messages m
        WHERE m.sender_address IS NOT NULL AND m.sender_address <> ''
          AND lower(m.sender_address) NOT IN (
              SELECT lower(email_address) FROM accounts
              WHERE email_address IS NOT NULL AND email_address <> ''
          )
          AND \(Self.systemMailboxExcludeFilter)
        GROUP BY lower(m.sender_address)
        ORDER BY latest DESC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, limit)
        var out: [RecentSender] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let address = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let display = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            if !address.isEmpty { out.append(RecentSender(address: address, display: display)) }
        }
        return out
    }

    /// Replace the priority-sender set. Both lists should already be lowercased
    /// and trimmed; empties are ignored. `exact` are full addresses, `patterns`
    /// are GLOB strings (containing `*`/`?`).
    func updatePrioritySet(exact: [String], patterns: [String]) throws {
        try exec("DELETE FROM priority_addr")
        try exec("DELETE FROM priority_pat")
        try fill("INSERT OR IGNORE INTO priority_addr(addr) VALUES (?)", with: exact)
        try fill("INSERT OR IGNORE INTO priority_pat(pat) VALUES (?)", with: patterns)
    }

    private func fill(_ sql: String, with values: [String]) throws {
        let clean = values.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return }
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        try inTransaction {
            for v in clean {
                sqlite3_reset(stmt)
                bind(stmt, 1, v)
                try stepDone(stmt)
            }
        }
    }

    /// Run a query and partition the results into the priority block and the
    /// rest, each newest-first and capped at `limitPerBlock`. Both blocks are
    /// fetched directly from SQL (not split in memory) so a priority message
    /// older than the cap's worth of "other" mail is never dropped.
    func searchSplitByPriority(
        _ q: CompiledQuery, limitPerBlock: Int
    ) throws -> (priority: [MessageHeader], other: [MessageHeader]) {
        let priority = try searchClassified(q, priority: true, limit: limitPerBlock)
        let other = try searchClassified(q, priority: false, limit: limitPerBlock)
        return (priority, other)
    }

    /// Rowids matching `q` in the given block and read state — the working set
    /// for "Mark all Priority/Other Messages as read/unread". Not capped to the
    /// display limit: marking acts on every matching message, not just the
    /// visible rows.
    func rowidsMatching(
        _ q: CompiledQuery, priority: Bool, isRead: Bool, limit: Int = 5000
    ) throws -> [Int] {
        guard q.hasAnyConstraint else { return [] }
        let sql = """
        SELECT m.apple_rowid
        FROM messages m
        WHERE (\(q.whereClause))
          AND \(Self.systemMailboxExcludeFilter)
          AND m.is_read = ?
          AND \(Self.priorityMembership(priority))
        ORDER BY m.date_received DESC LIMIT ?
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bindAll(stmt, q.bindings, trailing: [.int(isRead ? 1 : 0), .int(Int64(limit))])
        var out: [Int] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Int(sqlite3_column_int64(stmt, 0)))
        }
        return out
    }

    // MARK: — Helpers

    private func searchClassified(
        _ q: CompiledQuery, priority: Bool, limit: Int
    ) throws -> [MessageHeader] {
        guard q.hasAnyConstraint else { return [] }
        let sql = """
        SELECT \(Self.messageHeaderSelectList)
        FROM messages m
        WHERE (\(q.whereClause))
          AND \(Self.systemMailboxExcludeFilter)
          AND \(Self.priorityMembership(priority))
        ORDER BY m.date_received DESC LIMIT ?
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bindAll(stmt, q.bindings, trailing: [.int(Int64(limit))])
        return Self.collectMessageHeaders(stmt)
    }

    /// Whether the sender is priority — exact-match in `priority_addr` OR a GLOB
    /// match against any `priority_pat`. For the "other" block the whole thing
    /// is negated. `COALESCE` so a NULL sender deterministically lands in the
    /// "other" block rather than vanishing from both via NULL comparison
    /// semantics.
    private static func priorityMembership(_ priority: Bool) -> String {
        let match = """
        (COALESCE(lower(m.sender_address), '') IN (SELECT addr FROM priority_addr)
         OR EXISTS (
             SELECT 1 FROM priority_pat p
             WHERE COALESCE(lower(m.sender_address), '') GLOB p.pat
         ))
        """
        return priority ? match : "NOT \(match)"
    }

    /// Bind `q`'s positional bindings followed by `trailing`, in order.
    private func bindAll(_ stmt: OpaquePointer?, _ bindings: [SQLBinding], trailing: [SQLBinding]) {
        for (i, b) in (bindings + trailing).enumerated() {
            switch b {
            case .int(let v): sqlite3_bind_int64(stmt, Int32(i + 1), v)
            case .text(let s): bind(stmt, Int32(i + 1), s)
            }
        }
    }
}
