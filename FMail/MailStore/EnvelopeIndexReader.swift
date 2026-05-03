import Foundation
import SQLite3

enum EnvelopeIndexError: Error, CustomStringConvertible {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case noRow

    var description: String {
        switch self {
        case .openFailed(let m): return "Could not open Envelope Index: \(m)"
        case .prepareFailed(let m): return "Could not prepare statement: \(m)"
        case .stepFailed(let m): return "Step failed: \(m)"
        case .noRow: return "No row returned"
        }
    }
}

/// Read-only reader for Apple Mail's `Envelope Index` SQLite database.
final class EnvelopeIndexReader {
    private var db: OpaquePointer?

    init(path: String) throws {
        // Read-only. Don't use `?immutable=1` — Mail.app is actively writing,
        // and immutable mode would give us a stale snapshot.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        if rc != SQLITE_OK {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown (rc=\(rc))"
            sqlite3_close(handle)
            throw EnvelopeIndexError.openFailed(msg)
        }
        self.db = handle
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: — Smoke queries (Phase 0)

    func messageCount() throws -> Int {
        try scalarInt("SELECT count(*) FROM messages")
    }

    func mailboxCount() throws -> Int {
        try scalarInt("SELECT count(*) FROM mailboxes")
    }

    // MARK: — Phase 1 queries

    /// Loads every mailbox row, parses the URL into account UUID + path
    /// components, computes our own unread count (Apple's stored count drifts),
    /// and returns Mailbox values.
    func loadMailboxes() throws -> [Mailbox] {
        var stmt: OpaquePointer?
        let sql = "SELECT ROWID, url FROM mailboxes ORDER BY ROWID"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EnvelopeIndexError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var mailboxes: [Mailbox] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = Int(sqlite3_column_int64(stmt, 0))
            guard let urlCStr = sqlite3_column_text(stmt, 1) else { continue }
            let urlStr = String(cString: urlCStr)
            guard let parsed = MailboxURL.parse(urlStr) else { continue }
            let total = (try? perMailboxCount(rowid: rowid, onlyUnread: false)) ?? 0
            let unread = (try? perMailboxCount(rowid: rowid, onlyUnread: true)) ?? 0
            let hidden = MailboxFilter.isHiddenByDefault(pathComponents: parsed.pathComponents)
            mailboxes.append(Mailbox(
                rowId: rowid,
                accountUUID: parsed.accountUUID,
                pathComponents: parsed.pathComponents,
                totalCount: total,
                unreadCount: unread,
                hidden: hidden,
                kind: "other"
            ))
        }
        return mailboxes
    }

    /// Counts messages in a mailbox. `onlyUnread` further restricts to
    /// `read = 0`. Always excludes soft-deleted.
    func perMailboxCount(rowid: Int, onlyUnread: Bool) throws -> Int {
        let sql: String
        if onlyUnread {
            sql = "SELECT count(*) FROM messages WHERE mailbox = ? AND read = 0 AND deleted = 0"
        } else {
            sql = "SELECT count(*) FROM messages WHERE mailbox = ? AND deleted = 0"
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EnvelopeIndexError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(rowid))
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw EnvelopeIndexError.noRow }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Loads recent messages in a mailbox. Joins subject + sender address +
    /// sender display name in one query for speed. Sorted newest first.
    func loadMessages(mailboxRowId: Int, limit: Int = 500) throws -> [MessageHeader] {
        let sql = """
        SELECT m.ROWID, m.subject_prefix, s.subject, m.date_sent, m.date_received,
               m.read, m.flagged, a.address, a.comment
        FROM messages m
        LEFT JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN addresses a ON a.ROWID = m.sender
        WHERE m.mailbox = ? AND m.deleted = 0
        ORDER BY m.date_received DESC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EnvelopeIndexError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(mailboxRowId))
        sqlite3_bind_int64(stmt, 2, sqlite3_int64(limit))

        var out: [MessageHeader] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = Int(sqlite3_column_int64(stmt, 0))
            let prefix = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let subjectRaw = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let dateSentTs = sqlite3_column_int64(stmt, 3)
            let dateRecvTs = sqlite3_column_int64(stmt, 4)
            let read = sqlite3_column_int(stmt, 5) != 0
            let flagged = sqlite3_column_int(stmt, 6) != 0
            let address = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""
            let comment = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""

            let subjectFull = (prefix + subjectRaw)
            let subject = EncodedWord.decode(subjectFull)
            let display = comment.isEmpty ? address : EncodedWord.decode(comment)

            out.append(MessageHeader(
                rowId: rowid,
                mailboxRowId: mailboxRowId,
                subject: subject,
                senderAddress: address,
                senderDisplay: display,
                dateSent: dateSentTs > 0 ? Date(timeIntervalSince1970: TimeInterval(dateSentTs)) : nil,
                dateReceived: dateRecvTs > 0 ? Date(timeIntervalSince1970: TimeInterval(dateRecvTs)) : nil,
                isRead: read,
                isFlagged: flagged,
                rfcMessageId: nil
            ))
        }
        return out
    }

    private func scalarInt(_ sql: String) throws -> Int {
        var stmt: OpaquePointer?
        let prep = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if prep != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw EnvelopeIndexError.prepareFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }

        let step = sqlite3_step(stmt)
        guard step == SQLITE_ROW else {
            if step == SQLITE_DONE { throw EnvelopeIndexError.noRow }
            let msg = String(cString: sqlite3_errmsg(db))
            throw EnvelopeIndexError.stepFailed(msg)
        }
        return Int(sqlite3_column_int64(stmt, 0))
    }
}
