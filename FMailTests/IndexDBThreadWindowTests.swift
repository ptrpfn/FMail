import XCTest
@testable import FMail

/// Coverage for the thread-list windowing invariant in
/// `loadAllThreadSummaries` / `loadThreadSummaries`:
///
/// The unread badge (`countAllUnreadExcludingDrafts`) counts every unread
/// message with no recency limit. The thread list, for performance, only
/// loads the most-recent `limit` threads. If those two disagree, the user
/// sees "N unread" in the badge but the matching messages never appear in
/// the unfiltered list (only `is:unread` search surfaces them) — the bug
/// these tests guard against.
///
/// Invariant under test: an unread thread is ALWAYS included in the list,
/// even when it is older than the most-recent `limit` window. A read thread
/// beyond the window stays excluded.
final class IndexDBThreadWindowTests: XCTestCase {

    /// Builds a DB with `recentRead` read threads (newest-first) plus one
    /// unread thread dated *older* than all of them. Each message is its own
    /// thread (thread_id stays 0 → synthetic id = apple_rowid). Senders are
    /// external so the outgoing-dedup pass never fires.
    private func makeDB(recentRead: Int) async throws -> (db: IndexDB, cleanup: () -> Void,
                                                          inboxRowId: Int, oldUnreadRowId: Int,
                                                          recentRowIds: [Int]) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmail-window-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbURL = tmpDir.appendingPathComponent("index.sqlite")
        let db = try IndexDB(path: dbURL.path)
        let cleanup = { _ = try? FileManager.default.removeItem(at: tmpDir) }

        try await db.upsertAccounts([
            (uuid: "ACCT-FELIX", displayName: "Felix iCloud", email: "felix@example.com")
        ])
        let inboxRowId = 100
        try await db.upsertMailboxes([
            Mailbox(rowId: inboxRowId, accountUUID: "ACCT-FELIX", pathComponents: ["INBOX"],
                    totalCount: 0, unreadCount: 0, hidden: false, kind: .inbox)
        ])

        // Fixed epoch so the test never depends on wall-clock "now".
        let base = 2_000_000_000

        var messages: [IndexedMessage] = []
        var recipients: [IndexedRecipient] = []
        var recentRowIds: [Int] = []
        for i in 0..<recentRead {
            let rowid = 2001 + i
            recentRowIds.append(rowid)
            let date = base - i                 // strictly newest-first
            messages.append(makeMessage(rowid: rowid, mailbox: inboxRowId,
                                        subject: "Recent \(i)", date: date, isRead: true))
            recipients.append(IndexedRecipient(messageRowId: rowid, kind: 0, position: 0,
                                               address: "felix@example.com", display: "Felix"))
        }
        let oldUnreadRowId = 9001
        messages.append(makeMessage(rowid: oldUnreadRowId, mailbox: inboxRowId,
                                    subject: "Ancient unread", date: base - 1_000_000, isRead: false))
        recipients.append(IndexedRecipient(messageRowId: oldUnreadRowId, kind: 0, position: 0,
                                           address: "felix@example.com", display: "Felix"))

        try await db.upsertMessages(messages)
        try await db.upsertRecipients(recipients)
        return (db, cleanup, inboxRowId, oldUnreadRowId, recentRowIds)
    }

    private func makeMessage(rowid: Int, mailbox: Int, subject: String,
                             date: Int, isRead: Bool) -> IndexedMessage {
        IndexedMessage(
            appleRowId: rowid,
            appleMessageIdHash: Int64(rowid),
            mailboxRowId: mailbox,
            accountUUID: "ACCT-FELIX",
            subject: subject,
            subjectPrefix: "",
            subjectNormalized: subject.lowercased(),
            senderAddress: "sender\(rowid)@example.com",   // external → incoming
            senderDisplay: "Sender \(rowid)",
            dateSent: date,
            dateReceived: date,
            isRead: isRead,
            isFlagged: false,
            hasAttachment: false,
            rfcMessageId: "<msg-\(rowid)@example.com>",
            imapUID: rowid
        )
    }

    /// All-Mailboxes view: old unread is included; read threads past the
    /// limit are not. Uses `recentRead` > `limit * 2` so the unread thread is
    /// also outside the SQL fetch headroom — exercising the SQL-side
    /// `unread_count > 0` clause, not just the Swift-side cap.
    func testAllMailboxesIncludesUnreadBeyondLimit() async throws {
        let f = try await makeDB(recentRead: 7)
        defer { f.cleanup() }
        let limit = 3

        let summaries = try await f.db.loadAllThreadSummaries(limit: limit)
        let ids = Set(summaries.map(\.threadId))

        XCTAssertTrue(ids.contains(f.oldUnreadRowId),
                      "old unread thread must appear despite being older than the recent window")
        // The three newest read threads are within the window.
        for rowid in f.recentRowIds.prefix(limit) {
            XCTAssertTrue(ids.contains(rowid), "recent read thread \(rowid) should be in the window")
        }
        // Read threads beyond the limit stay excluded (the cap still applies to reads).
        for rowid in f.recentRowIds.dropFirst(limit) {
            XCTAssertFalse(ids.contains(rowid),
                           "read thread \(rowid) beyond the limit must NOT appear")
        }

        // The invariant itself: every unread message the badge counts has a
        // home in the list.
        let badge = try await f.db.countAllUnreadExcludingDrafts()
        let listedUnread = summaries.reduce(0) { $0 + $1.unreadCount }
        XCTAssertEqual(badge, listedUnread,
                       "unread badge count must equal unread shown in the thread list")
    }

    /// Same invariant for the per-mailbox view.
    func testMailboxViewIncludesUnreadBeyondLimit() async throws {
        let f = try await makeDB(recentRead: 7)
        defer { f.cleanup() }
        let limit = 3

        let summaries = try await f.db.loadThreadSummaries(mailboxRowId: f.inboxRowId, limit: limit)
        let ids = Set(summaries.map(\.threadId))

        XCTAssertTrue(ids.contains(f.oldUnreadRowId),
                      "old unread thread must appear in the per-mailbox list too")
        for rowid in f.recentRowIds.dropFirst(limit) {
            XCTAssertFalse(ids.contains(rowid),
                           "read thread \(rowid) beyond the limit must NOT appear")
        }
    }

    /// Sanity: ordering stays strict newest-first, so the old unread lands at
    /// the bottom (its natural date position) rather than being floated up.
    func testOrderingStaysDateDescending() async throws {
        let f = try await makeDB(recentRead: 7)
        defer { f.cleanup() }

        let summaries = try await f.db.loadAllThreadSummaries(limit: 3)
        let dates = summaries.map { $0.latestDateReceived ?? .distantPast }
        XCTAssertEqual(dates, dates.sorted(by: >), "thread list must remain newest-first")
        XCTAssertEqual(summaries.last?.threadId, f.oldUnreadRowId,
                       "the old unread thread should sit at the bottom in date order")
    }
}
