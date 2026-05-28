import Foundation
import SQLite3

/// Thread-list assembly for the sidebar: the All-Mailboxes and per-mailbox
/// summary queries, their shared decode loop, the outgoing-thread dedup, and
/// the representative-message lookups + SQL fragments they depend on. Split
/// out so the (substantial) thread-summary logic doesn't crowd the core read
/// API. Shared SQL fragments that other files also need
/// (`effectiveThreadIdExpr`, `systemMailboxExcludeFilter`,
/// `threadScopePredicate`) live in `IndexDB.swift`.
extension IndexDB {

    /// "All Mailboxes" view: the most-recent `limit` threads outside
    /// drafts/trash/junk, newest first, **plus every thread that still has an
    /// unread message** regardless of age. The unread badge
    /// (`countAllUnreadExcludingDrafts`) counts every unread message with no
    /// recency limit; if the list only showed the recent window, an unread
    /// email older than that window would be counted but never displayed —
    /// the user sees "N unread" with nothing to click. Including unread
    /// threads unconditionally keeps the badge and the list reconciled.
    ///
    /// Synthetic thread ids: a message that hasn't been threaded yet
    /// (thread_id = 0, the schema default in the gap between `upsertMessages`
    /// and `replaceThreads`) gets its own row keyed on its own apple_rowid
    /// rather than collapsing every unthreaded message into one synthetic
    /// "thread 0" bucket. Real thread ids are `min(memberRowIds)`, so a
    /// rowid only equals a thread id when the message is in that thread —
    /// which by definition can't happen for an unthreaded message. The
    /// synthetic id also matches what `ThreadGrouper` will compute for the
    /// singleton on the next sync, so the transition is seamless.
    func loadAllThreadSummaries(limit: Int = 500) throws -> [ThreadSummary] {
        let sql = """
        WITH visible AS (
            SELECT m.apple_rowid,
                   \(Self.effectiveThreadIdExpr) AS thread_id,
                   m.date_received, m.is_read, m.is_flagged
            FROM messages m
            WHERE \(Self.systemMailboxExcludeFilter)
        ),
        thread_data AS MATERIALIZED (
            SELECT thread_id,
                   MAX(date_received) AS latest,
                   COUNT(apple_rowid) AS local_count,
                   SUM(CASE WHEN is_read = 0 THEN 1 ELSE 0 END) AS unread_count,
                   SUM(CASE WHEN is_flagged = 1 THEN 1 ELSE 0 END) AS flagged_count
            FROM visible
            GROUP BY thread_id
        )
        -- Recent window OR any unread thread (see method doc). MATERIALIZED so
        -- the GROUP BY over `visible` is computed once, not re-run for the IN
        -- subquery.
        SELECT thread_id, latest, local_count, unread_count, flagged_count
        FROM thread_data
        WHERE unread_count > 0
           OR thread_id IN (
               SELECT thread_id FROM thread_data ORDER BY latest DESC LIMIT ?
           )
        ORDER BY latest DESC
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, Int64(Self.threadFetchLimit(for: limit)))
        return try decodeThreadSummaries(stmt, limit: limit) { tid in
            try self.latestNonDraftMessageOfThread(threadId: tid)
        }
    }

    /// Returns thread summaries in a mailbox, newest thread first.
    /// Includes messages whose canonical mailbox is this one OR which are
    /// labelled into this mailbox (Gmail).
    ///
    /// Implementation note: aggregates are computed directly from `messages`
    /// (no JOIN with `threads`). Joining with `threads` would silently drop
    /// any message whose `thread_id = 0` — i.e. a message that has been
    /// indexed but hasn't been threaded yet, which is the default state for
    /// freshly-arrived mail in the gap between `upsertMessages` and
    /// `replaceThreads`. Such messages would still be counted in the
    /// sidebar's unread badge (counts read `messages` directly) and would
    /// still match search, but their thread row would be missing from this
    /// list — visible symptom: "list is behind, unread count is fresh".
    /// Treating thread_id=0 as a single synthetic bucket keeps them visible
    /// (and the rep-message picker still picks the most recent of them, so
    /// the user sees the latest arrival).
    func loadThreadSummaries(mailboxRowId: Int, limit: Int = 500) throws -> [ThreadSummary] {
        let sql = """
        WITH mailbox_messages AS (
            SELECT apple_rowid FROM messages WHERE mailbox_rowid = ?
            UNION
            SELECT message_rowid AS apple_rowid FROM message_labels WHERE mailbox_rowid = ?
        ),
        visible AS (
            SELECT m.apple_rowid,
                   \(Self.effectiveThreadIdExpr) AS thread_id,
                   m.date_received, m.is_read, m.is_flagged
            FROM messages m
            WHERE m.apple_rowid IN (SELECT apple_rowid FROM mailbox_messages)
        ),
        thread_data AS MATERIALIZED (
            SELECT thread_id,
                   MAX(date_received) AS latest,
                   COUNT(apple_rowid) AS local_count,
                   SUM(CASE WHEN is_read = 0 THEN 1 ELSE 0 END) AS unread_count,
                   SUM(CASE WHEN is_flagged = 1 THEN 1 ELSE 0 END) AS flagged_count
            FROM visible
            GROUP BY thread_id
        )
        -- Recent window OR any unread thread, so this mailbox's list can never
        -- fall behind its unread badge (same invariant as the All-Mailboxes
        -- view). MATERIALIZED so the GROUP BY runs once.
        SELECT thread_id, latest, local_count, unread_count, flagged_count
        FROM thread_data
        WHERE unread_count > 0
           OR thread_id IN (
               SELECT thread_id FROM thread_data ORDER BY latest DESC LIMIT ?
           )
        ORDER BY latest DESC
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, Int64(mailboxRowId))
        bind(stmt, 2, Int64(mailboxRowId))
        bind(stmt, 3, Int64(Self.threadFetchLimit(for: limit)))
        return try decodeThreadSummaries(stmt, limit: limit) { tid in
            try self.latestMessageOfThreadInMailbox(threadId: tid, mailboxRowId: mailboxRowId)
        }
    }

    /// Fetch headroom so the outgoing-dedup pass can skip rows without
    /// shrinking the recent window below the caller's expected `limit`.
    private static func threadFetchLimit(for limit: Int) -> Int { min(limit * 2, 1500) }

    /// Shared decode for both thread-summary queries (All Mailboxes / single
    /// mailbox). Rows must be `(thread_id, latest, local_count, unread_count,
    /// flagged_count)` ordered newest-first. `representative` supplies the
    /// thread's display message; it differs per query (whole index vs scoped
    /// to one mailbox).
    private func decodeThreadSummaries(
        _ stmt: OpaquePointer?,
        limit: Int,
        representative: (Int) throws -> RepresentativeMessage?
    ) rethrows -> [ThreadSummary] {
        var out: [ThreadSummary] = []
        var seenOutgoingKeys: Set<String> = []
        var readThreadCount = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let tid = Int(sqlite3_column_int64(stmt, 0))
            let latest = Int(sqlite3_column_int64(stmt, 1))
            let local = Int(sqlite3_column_int64(stmt, 2))
            let unread = Int(sqlite3_column_int64(stmt, 3))
            let flagged = Int(sqlite3_column_int64(stmt, 4))
            // Cap only fully-read threads at `limit`; unread threads are always
            // kept so the list can never fall behind the unread badge. Rows
            // arrive newest-first, so an old unread thread still lands in its
            // natural date position rather than being dropped.
            if unread == 0 && readThreadCount >= limit { continue }
            let repr = try representative(tid)
            // Outgoing dedup only collapses fully-read duplicates — never drop
            // an unread thread, or the badge and list would disagree again.
            if unread == 0, let key = Self.outgoingDedupKey(for: repr) {
                if seenOutgoingKeys.contains(key) { continue }
                seenOutgoingKeys.insert(key)
            }
            if unread == 0 { readThreadCount += 1 }
            out.append(ThreadSummary(
                threadId: tid,
                latestDateReceived: latest > 0 ? Date(timeIntervalSince1970: TimeInterval(latest)) : nil,
                messageCount: local,
                unreadCount: unread,
                flaggedCount: flagged,
                latestSubject: repr?.subject ?? "",
                latestSenderDisplay: repr?.correspondent ?? "",
                latestMessageRowId: repr?.rowId ?? 0,
                latestIsOutgoing: repr?.isOutgoing ?? false
            ))
        }
        return out
    }

    /// Dedup key for outgoing threads: lowercased recipient address +
    /// normalized subject. Returns nil for incoming threads, threads with
    /// no resolvable recipient, or threads with an empty normalized subject
    /// (so we don't collapse every "(no subject)" sent message into one row).
    /// Apple Mail's auto-save creates intermediate draft revisions that
    /// land in Sent / All Mail (Gmail's canonical store) with distinct
    /// Message-IDs but identical (recipient, subject) — this key folds
    /// them into one row, keeping only the most recent (the SQL above
    /// orders by `latest DESC`, so the first-seen key wins).
    private static func outgoingDedupKey(for repr: RepresentativeMessage?) -> String? {
        guard let repr, repr.isOutgoing,
              let recipient = repr.dedupRecipient, !recipient.isEmpty
        else { return nil }
        let subject = repr.subjectNormalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else { return nil }
        return "\(recipient)|\(subject)"
    }

    private func latestNonDraftMessageOfThread(threadId: Int) throws -> RepresentativeMessage? {
        let sql = """
        SELECT \(Self.representativeSelectList)
        FROM messages m
        WHERE \(Self.threadScopePredicate)
          AND \(Self.systemMailboxExcludeFilter)
        ORDER BY m.date_received DESC
        LIMIT 1
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, Int64(threadId))
        bind(stmt, 2, Int64(threadId))
        return try Self.decodeRepresentative(stmt)
    }

    private func latestMessageOfThreadInMailbox(threadId: Int, mailboxRowId: Int) throws -> RepresentativeMessage? {
        let sql = """
        SELECT \(Self.representativeSelectList)
        FROM messages m
        WHERE \(Self.threadScopePredicate)
          AND (m.mailbox_rowid = ?
               OR m.apple_rowid IN (SELECT message_rowid FROM message_labels WHERE mailbox_rowid = ?))
        ORDER BY m.date_received DESC
        LIMIT 1
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, Int64(threadId))
        bind(stmt, 2, Int64(threadId))
        bind(stmt, 3, Int64(mailboxRowId))
        bind(stmt, 4, Int64(mailboxRowId))
        return try Self.decodeRepresentative(stmt)
    }

    /// Per-thread representative-message info used to populate one row in
    /// the thread list. `correspondent` is the sender for incoming mail and
    /// the first To-recipient for outgoing mail (sender matches one of our
    /// account email addresses). `subjectNormalized` and `dedupRecipient`
    /// feed the outgoing-thread dedup pass — see `outgoingDedupKey(for:)`.
    private struct RepresentativeMessage {
        let rowId: Int
        let subject: String
        let subjectNormalized: String
        let correspondent: String
        let isOutgoing: Bool
        /// Lowercased primary To-recipient address for outgoing messages,
        /// nil for incoming. Used for dedup, not display.
        let dedupRecipient: String?
    }

    /// SQL expression: `1` when the row's sender matches one of our account
    /// email addresses (case-insensitive), else `0`.
    private static let outgoingFlagExpr = """
        CASE WHEN LOWER(m.sender_address) IN (
            SELECT LOWER(email_address) FROM accounts WHERE email_address IS NOT NULL
        ) THEN 1 ELSE 0 END
        """

    /// SQL expression: when the row is outgoing, the first To-recipient's
    /// display (or address if no display); otherwise the sender's display
    /// (or sender address if no display). Empty string fallback.
    private static let correspondentExpr = """
        CASE
            WHEN LOWER(m.sender_address) IN (
                SELECT LOWER(email_address) FROM accounts WHERE email_address IS NOT NULL
            )
            THEN COALESCE(
                (SELECT COALESCE(NULLIF(r.display, ''), r.address)
                 FROM recipients r
                 WHERE r.message_rowid = m.apple_rowid AND r.kind = \(RecipientKind.to.rawValue)
                 ORDER BY r.position
                 LIMIT 1),
                ''
            )
            ELSE COALESCE(NULLIF(m.sender_display, ''), m.sender_address, '')
        END
        """

    /// SQL expression: lowercased primary To-recipient address for outgoing
    /// rows, NULL otherwise. Feeds the outgoing-dedup key.
    private static let dedupRecipientExpr = """
        CASE
            WHEN LOWER(m.sender_address) IN (
                SELECT LOWER(email_address) FROM accounts WHERE email_address IS NOT NULL
            )
            THEN (SELECT LOWER(r.address)
                  FROM recipients r
                  WHERE r.message_rowid = m.apple_rowid AND r.kind = \(RecipientKind.to.rawValue)
                  ORDER BY r.position
                  LIMIT 1)
            ELSE NULL
        END
        """

    /// Common SELECT-list shared by both representative-message queries.
    private static let representativeSelectList = """
        m.apple_rowid,
        m.subject_prefix,
        m.subject,
        m.subject_normalized,
        \(outgoingFlagExpr) AS is_outgoing,
        \(correspondentExpr) AS correspondent,
        \(dedupRecipientExpr) AS dedup_recipient
        """

    private static func decodeRepresentative(_ stmt: OpaquePointer?) throws -> RepresentativeMessage? {
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let rowid = Int(sqlite3_column_int64(stmt, 0))
        let prefix = String(cString: sqlite3_column_text(stmt, 1))
        let subj = String(cString: sqlite3_column_text(stmt, 2))
        let normalized = String(cString: sqlite3_column_text(stmt, 3))
        let outgoing = sqlite3_column_int(stmt, 4) != 0
        let correspondent = String(cString: sqlite3_column_text(stmt, 5))
        let dedupRecipient = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
        return RepresentativeMessage(
            rowId: rowid,
            subject: prefix + subj,
            subjectNormalized: normalized,
            correspondent: correspondent,
            isOutgoing: outgoing,
            dedupRecipient: dedupRecipient
        )
    }
}
