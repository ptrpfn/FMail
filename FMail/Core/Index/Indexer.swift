import Foundation
import SQLite3

struct IndexProgress: Sendable, Equatable {
    var stage: String
    var done: Int
    var total: Int  // 0 = indeterminate

    static let idle = IndexProgress(stage: "Idle", done: 0, total: 0)
}

/// Mirrors Apple's Envelope Index into FMail's own DB. Single bulk pass per
/// table; results held in memory while we iterate chunks into IndexDB.
/// Memory peak ≈ 70 MB on a 150k-message mailbox; acceptable.
final class Indexer: Sendable {
    let envelopePath: String
    let indexDB: IndexDB
    let mailVersionDir: URL

    init(envelopePath: String, indexDB: IndexDB, mailVersionDir: URL) {
        self.envelopePath = envelopePath
        self.indexDB = indexDB
        self.mailVersionDir = mailVersionDir
    }

    /// One full mirror pass. Idempotent (uses ON CONFLICT upserts).
    func runFullSync(progress: @MainActor @escaping (IndexProgress) -> Void) async throws {
        let env = try EnvelopeReadOnly(path: envelopePath)
        defer { env.close() }

        await report(progress, "Reading mailboxes")

        let mailboxes = try env.loadMailboxes()
        try await indexDB.upsertMailboxes(mailboxes)

        let acctUUIDs = Array(Set(mailboxes.map(\.accountUUID))).sorted()
        let accounts: [(uuid: String, displayName: String, email: String?)] = acctUUIDs.map { uuid in
            let email = (try? env.likelyEmailAddress(forAccountUUID: uuid, mailboxes: mailboxes)) ?? nil
            let display = email ?? "Account \(uuid.prefix(8))"
            return (uuid, display, email)
        }
        try await indexDB.upsertAccounts(accounts)

        await report(progress, "Reading message metadata")
        let allMessages = try env.fetchAllMessages()
        let total = allMessages.count
        await report(progress, "Indexing messages", done: 0, total: total)
        try await chunked(allMessages, size: 2000) { batch, doneSoFar in
            let rows = batch.map(Self.makeIndexedMessage)
            try await self.indexDB.upsertMessages(rows)
            await self.report(progress, "Indexing messages", done: doneSoFar, total: total)
        }

        await report(progress, "Reading recipients")
        let allRcpts = try env.fetchAllRecipients()
        await report(progress, "Indexing recipients", done: 0, total: allRcpts.count)
        // Group by message rowid so per-message replace works correctly.
        let groupedR = Dictionary(grouping: allRcpts, by: \.messageRowId)
        var msgRcptKeys = Array(groupedR.keys)
        msgRcptKeys.sort()
        var rcptDone = 0
        try await chunked(msgRcptKeys, size: 1000) { keysBatch, _ in
            var rows: [IndexedRecipient] = []
            rows.reserveCapacity(keysBatch.count * 2)
            for key in keysBatch {
                for r in groupedR[key] ?? [] {
                    rows.append(IndexedRecipient(
                        messageRowId: r.messageRowId, kind: r.kind, position: r.position,
                        address: r.address, display: r.display.isEmpty ? nil : r.display
                    ))
                }
            }
            try await self.indexDB.upsertRecipients(rows)
            rcptDone += rows.count
            await self.report(progress, "Indexing recipients", done: rcptDone, total: allRcpts.count)
        }

        await report(progress, "Reading labels")
        let allLabels = try env.fetchAllLabels()
        try await indexDB.replaceAllMessageLabels(allLabels)

        await report(progress, "Reading references")
        let allRefs = try env.fetchAllReferences()
        await report(progress, "Indexing references", done: 0, total: allRefs.count)
        let groupedF = Dictionary(grouping: allRefs, by: \.fromRowId)
        var fromKeys = Array(groupedF.keys)
        fromKeys.sort()
        var refDone = 0
        try await chunked(fromKeys, size: 1000) { keysBatch, _ in
            var rows: [IndexedMessageLink] = []
            rows.reserveCapacity(keysBatch.count * 3)
            for key in keysBatch {
                for f in groupedF[key] ?? [] {
                    rows.append(IndexedMessageLink(
                        fromMessageRowId: f.fromRowId,
                        toMessageIdHash: f.toHash,
                        isParent: f.isParent
                    ))
                }
            }
            try await self.indexDB.upsertMessageLinks(rows)
            refDone += rows.count
            await self.report(progress, "Indexing references", done: refDone, total: allRefs.count)
        }

        await report(progress, "Building threads")
        let snapshotMessages = try await indexDB.snapshotMessagesForThreading()
        let snapshotLinks = try await indexDB.snapshotMessageLinks()
        let threads = ThreadGrouper.build(messages: snapshotMessages, links: snapshotLinks)
        try await indexDB.replaceThreads(threads)

        await report(progress, "Recomputing counts")
        try await indexDB.recomputeMailboxCounts()

        await report(progress, "Updating FTS index")
        try await indexDB.incrementalUpdateFTS()

        try await indexDB.setMeta("last_full_sync_at", String(Int(Date().timeIntervalSince1970)))
        try await indexDB.setMeta("schema_version_at_sync", String(Schema.currentVersion))

        await report(progress, "Done", done: total, total: total)
    }

    // MARK: — Helpers

    private func chunked<T>(_ items: [T], size: Int, body: ([T], Int) async throws -> Void) async throws {
        var idx = 0
        while idx < items.count {
            let end = min(idx + size, items.count)
            try await body(Array(items[idx..<end]), end)
            idx = end
        }
    }

    private func report(_ closure: @MainActor @escaping (IndexProgress) -> Void, _ stage: String, done: Int = 0, total: Int = 0) async {
        await MainActor.run {
            closure(IndexProgress(stage: stage, done: done, total: total))
        }
    }

    private static func makeIndexedMessage(_ raw: EnvelopeReadOnly.RawMessage) -> IndexedMessage {
        let subject = EncodedWord.decode(raw.subjectText)
        let prefix = raw.subjectPrefix
        let normalized = normalizeSubject(prefix + subject)
        return IndexedMessage(
            appleRowId: raw.rowId,
            appleMessageIdHash: raw.messageIdHash,
            mailboxRowId: raw.mailboxRowId,
            accountUUID: raw.accountUUID,
            subject: subject,
            subjectPrefix: prefix,
            subjectNormalized: normalized,
            senderAddress: raw.senderAddress.isEmpty ? nil : raw.senderAddress,
            senderDisplay: raw.senderDisplay.isEmpty ? nil : EncodedWord.decode(raw.senderDisplay),
            dateSent: raw.dateSent,
            dateReceived: raw.dateReceived,
            isRead: raw.isRead,
            isFlagged: raw.isFlagged,
            hasAttachment: raw.hasAttachment,
            rfcMessageId: raw.rfcMessageId,
            imapUID: raw.imapUID
        )
    }

    /// Normalize for thread grouping fallback: strip "Re:"/"Fwd:" prefixes,
    /// collapse whitespace, lowercase.
    static func normalizeSubject(_ s: String) -> String {
        var t = s
        let prefixes = ["re:", "re :", "fwd:", "fw:", "fwd :", "fw :"]
        var changed = true
        while changed {
            changed = false
            let trimmed = t.trimmingCharacters(in: .whitespaces).lowercased()
            for p in prefixes {
                if trimmed.hasPrefix(p) {
                    t = String(t.trimmingCharacters(in: .whitespaces).dropFirst(p.count))
                    changed = true
                    break
                }
            }
        }
        return t.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: — Read-only Envelope wrapper for indexer use.

final class EnvelopeReadOnly {
    let db: OpaquePointer

    init(path: String) throws {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        if rc != SQLITE_OK {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            sqlite3_close(handle)
            throw EnvelopeIndexError.openFailed(msg)
        }
        self.db = handle!
    }

    func close() { sqlite3_close(db) }

    struct RawMessage {
        let rowId: Int
        let messageIdHash: Int64
        let mailboxRowId: Int
        let accountUUID: String
        let subjectPrefix: String
        let subjectText: String
        let senderAddress: String
        let senderDisplay: String
        let dateSent: Int?
        let dateReceived: Int?
        let isRead: Bool
        let isFlagged: Bool
        let hasAttachment: Bool
        let rfcMessageId: String?
        let imapUID: Int?
    }

    struct RawRecipient {
        let messageRowId: Int
        let kind: Int
        let position: Int
        let address: String
        let display: String
    }

    struct RawReference {
        let fromRowId: Int
        let toHash: Int64
        let isParent: Bool
    }

    func loadMailboxes() throws -> [Mailbox] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ROWID, url FROM mailboxes ORDER BY ROWID", -1, &stmt, nil) == SQLITE_OK else {
            throw EnvelopeIndexError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var out: [Mailbox] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = Int(sqlite3_column_int64(stmt, 0))
            guard let urlCStr = sqlite3_column_text(stmt, 1) else { continue }
            let urlStr = String(cString: urlCStr)
            guard let parsed = MailboxURL.parse(urlStr) else { continue }
            let hidden = MailboxFilter.isHiddenByDefault(pathComponents: parsed.pathComponents)
            // kind field is set by IndexDB.upsertMailboxes from displayName;
            // pass placeholder here since this Mailbox is only used for insert.
            out.append(Mailbox(
                rowId: rowid,
                accountUUID: parsed.accountUUID,
                pathComponents: parsed.pathComponents,
                totalCount: 0,
                unreadCount: 0,
                hidden: hidden,
                kind: "other"
            ))
        }
        return out
    }

    func likelyEmailAddress(forAccountUUID uuid: String, mailboxes: [Mailbox]) throws -> String? {
        if let s = sentHeuristic(uuid: uuid, mailboxes: mailboxes) {
            return s
        }
        return recipientHeuristic(uuid: uuid, mailboxes: mailboxes)
    }

    /// Most-common-sender from this account's Sent mailbox. Best signal
    /// when the user has actually sent mail from the account.
    private func sentHeuristic(uuid: String, mailboxes: [Mailbox]) -> String? {
        let sentRowIds = mailboxes
            .filter { $0.accountUUID == uuid && ($0.displayName == "Sent Messages" || $0.displayName == "Sent Mail") }
            .map(\.rowId)
        guard !sentRowIds.isEmpty else { return nil }
        let placeholders = sentRowIds.map { _ in "?" }.joined(separator: ",")
        // Gmail Sent mailboxes contain messages via labels, not direct
        // mailbox assignment. Query both paths.
        let sql = """
        WITH sent_msgs AS (
            SELECT m.ROWID
            FROM messages m
            WHERE m.mailbox IN (\(placeholders)) AND m.deleted = 0
            UNION
            SELECT l.message_id AS ROWID
            FROM labels l JOIN messages m ON m.ROWID = l.message_id
            WHERE l.mailbox_id IN (\(placeholders)) AND m.deleted = 0
        )
        SELECT a.address, COUNT(*) as c
        FROM messages m JOIN addresses a ON a.ROWID = m.sender
        WHERE m.ROWID IN (SELECT ROWID FROM sent_msgs)
        GROUP BY a.address
        ORDER BY c DESC
        LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        for id in sentRowIds {
            sqlite3_bind_int64(stmt, idx, Int64(id))
            idx += 1
        }
        for id in sentRowIds {
            sqlite3_bind_int64(stmt, idx, Int64(id))
            idx += 1
        }
        if sqlite3_step(stmt) == SQLITE_ROW, let cstr = sqlite3_column_text(stmt, 0) {
            return String(cString: cstr)
        }
        return nil
    }

    /// Fallback: most-common To-recipient across this account's incoming
    /// mail. Handles accounts with no Sent mailbox (receive-only, IMAP-only,
    /// secondary "Outbox"-named mailbox) — the user's own email is reliably
    /// the top recipient. Returns nil if the account has no mail at all.
    private func recipientHeuristic(uuid: String, mailboxes: [Mailbox]) -> String? {
        let mboxIds = mailboxes.filter { $0.accountUUID == uuid }.map(\.rowId)
        guard !mboxIds.isEmpty else { return nil }
        let placeholders = mboxIds.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT a.address, COUNT(*) as c
        FROM recipients r
        JOIN addresses a ON a.ROWID = r.address
        JOIN messages m ON m.ROWID = r.message
        WHERE m.mailbox IN (\(placeholders)) AND m.deleted = 0 AND r.type = 0
        GROUP BY a.address
        ORDER BY c DESC
        LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        for (idx, id) in mboxIds.enumerated() {
            sqlite3_bind_int64(stmt, Int32(idx + 1), Int64(id))
        }
        if sqlite3_step(stmt) == SQLITE_ROW, let cstr = sqlite3_column_text(stmt, 0) {
            return String(cString: cstr)
        }
        return nil
    }

    func fetchAllLabels() throws -> [(messageRowId: Int, mailboxRowId: Int)] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT message_id, mailbox_id FROM labels", -1, &stmt, nil) == SQLITE_OK else {
            throw EnvelopeIndexError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var out: [(Int, Int)] = []
        out.reserveCapacity(300_000)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((Int(sqlite3_column_int64(stmt, 0)), Int(sqlite3_column_int64(stmt, 1))))
        }
        return out.map { (messageRowId: $0.0, mailboxRowId: $0.1) }
    }

    func fetchAllMessages() throws -> [RawMessage] {
        // The RFC 2822 Message-ID header lives in `message_global_data`. The FK
        // is `messages.global_message_id` → `message_global_data.ROWID` (NOT
        // `mgd.message_id`, which is some other internal hash).
        let sql = """
        SELECT m.ROWID, m.message_id, m.mailbox, mb.url, COALESCE(m.subject_prefix, ''),
               COALESCE(s.subject, ''),
               COALESCE(a.address, ''),
               COALESCE(a.comment, ''),
               m.date_sent, m.date_received,
               m.read, m.flagged,
               EXISTS(SELECT 1 FROM attachments at WHERE at.message = m.ROWID),
               mgd.message_id_header,
               m.remote_id
        FROM messages m
        JOIN mailboxes mb ON mb.ROWID = m.mailbox
        LEFT JOIN subjects s ON s.ROWID = m.subject
        LEFT JOIN addresses a ON a.ROWID = m.sender
        LEFT JOIN message_global_data mgd ON mgd.ROWID = m.global_message_id
        WHERE m.deleted = 0
        ORDER BY m.ROWID
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EnvelopeIndexError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var out: [RawMessage] = []
        out.reserveCapacity(160_000)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = Int(sqlite3_column_int64(stmt, 0))
            let hash = sqlite3_column_int64(stmt, 1)
            let mboxId = Int(sqlite3_column_int64(stmt, 2))
            let urlStr = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let parsed = MailboxURL.parse(urlStr)
            let acct = parsed?.accountUUID ?? ""
            let prefix = String(cString: sqlite3_column_text(stmt, 4))
            let subj = String(cString: sqlite3_column_text(stmt, 5))
            let saddr = String(cString: sqlite3_column_text(stmt, 6))
            let sdisp = String(cString: sqlite3_column_text(stmt, 7))
            let ds = sqlite3_column_int64(stmt, 8)
            let dr = sqlite3_column_int64(stmt, 9)
            let read = sqlite3_column_int(stmt, 10) != 0
            let flagged = sqlite3_column_int(stmt, 11) != 0
            let hasAtt = sqlite3_column_int(stmt, 12) != 0
            let rfcId = sqlite3_column_text(stmt, 13).map { String(cString: $0) }
            let uidVal = sqlite3_column_int64(stmt, 14)
            let uid: Int? = sqlite3_column_type(stmt, 14) == SQLITE_NULL ? nil : Int(uidVal)

            out.append(RawMessage(
                rowId: rowid, messageIdHash: hash, mailboxRowId: mboxId, accountUUID: acct,
                subjectPrefix: prefix, subjectText: subj,
                senderAddress: saddr, senderDisplay: sdisp,
                dateSent: ds > 0 ? Int(ds) : nil,
                dateReceived: dr > 0 ? Int(dr) : nil,
                isRead: read, isFlagged: flagged, hasAttachment: hasAtt,
                rfcMessageId: rfcId,
                imapUID: uid
            ))
        }
        return out
    }

    func fetchAllRecipients() throws -> [RawRecipient] {
        let sql = """
        SELECT r.message, r.type, r.position, a.address, COALESCE(a.comment, '')
        FROM recipients r
        JOIN addresses a ON a.ROWID = r.address
        ORDER BY r.message
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EnvelopeIndexError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var out: [RawRecipient] = []
        out.reserveCapacity(250_000)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(RawRecipient(
                messageRowId: Int(sqlite3_column_int64(stmt, 0)),
                kind: Int(sqlite3_column_int64(stmt, 1)),
                position: Int(sqlite3_column_int64(stmt, 2)),
                address: String(cString: sqlite3_column_text(stmt, 3)),
                display: String(cString: sqlite3_column_text(stmt, 4))
            ))
        }
        return out
    }

    func fetchAllReferences() throws -> [RawReference] {
        let sql = "SELECT message, reference, is_originator FROM message_references ORDER BY message"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EnvelopeIndexError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var out: [RawReference] = []
        out.reserveCapacity(500_000)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(RawReference(
                fromRowId: Int(sqlite3_column_int64(stmt, 0)),
                toHash: sqlite3_column_int64(stmt, 1),
                isParent: sqlite3_column_int(stmt, 2) != 0
            ))
        }
        return out
    }
}
