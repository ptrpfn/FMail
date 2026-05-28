import XCTest
@testable import FMail

/// Behavioral coverage for the outgoing-thread dedup in
/// `loadAllThreadSummaries` (exercised through the public API, since the dedup
/// key is an implementation detail).
///
/// Apple Mail's auto-save lands intermediate revisions of a sent message in
/// Sent / All Mail with distinct Message-IDs but identical (recipient,
/// subject). The thread list folds *fully-read* outgoing duplicates into one
/// row, but must never collapse unread threads (or the badge and list disagree).
final class IndexDBDedupTests: XCTestCase {

    private let ourEmail = "felix@example.com"

    private func makeDB() async throws -> (db: IndexDB, cleanup: () -> Void, inbox: Int) {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmail-dedup-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let db = try IndexDB(path: tmpDir.appendingPathComponent("index.sqlite").path)
        let cleanup = { _ = try? FileManager.default.removeItem(at: tmpDir) }
        try await db.upsertAccounts([(uuid: "ACCT", displayName: "Felix", email: ourEmail)])
        let inbox = 100
        try await db.upsertMailboxes([
            Mailbox(rowId: inbox, accountUUID: "ACCT", pathComponents: ["INBOX"],
                    totalCount: 0, unreadCount: 0, hidden: false, kind: .inbox)
        ])
        return (db, cleanup, inbox)
    }

    /// An outgoing message (sender = one of our account addresses) to `to`.
    private func outgoing(rowid: Int, mailbox: Int, subject: String, to: String,
                          date: Int, isRead: Bool) -> (IndexedMessage, IndexedRecipient) {
        let msg = IndexedMessage(
            appleRowId: rowid, appleMessageIdHash: Int64(rowid), mailboxRowId: mailbox,
            accountUUID: "ACCT", subject: subject, subjectPrefix: "",
            subjectNormalized: Indexer.normalizeSubject(subject),
            senderAddress: ourEmail, senderDisplay: "Felix",
            dateSent: date, dateReceived: date, isRead: isRead, isFlagged: false,
            hasAttachment: false, rfcMessageId: "<\(rowid)@example.com>", imapUID: rowid
        )
        let rcpt = IndexedRecipient(messageRowId: rowid, kind: RecipientKind.to.rawValue,
                                    position: 0, address: to, display: nil)
        return (msg, rcpt)
    }

    func testCollapsesFullyReadOutgoingDuplicates() async throws {
        let f = try await makeDB(); defer { f.cleanup() }
        let base = 2_000_000_000
        // Two read sends to the same recipient with the same subject (distinct
        // rows = distinct synthetic threads) + one with a different subject.
        let rows = [
            outgoing(rowid: 3001, mailbox: f.inbox, subject: "Hello", to: "bob@example.com", date: base, isRead: true),
            outgoing(rowid: 3002, mailbox: f.inbox, subject: "Hello", to: "bob@example.com", date: base - 10, isRead: true),
            outgoing(rowid: 3003, mailbox: f.inbox, subject: "Different", to: "bob@example.com", date: base - 5, isRead: true),
        ]
        try await f.db.upsertMessages(rows.map(\.0))
        try await f.db.upsertRecipients(rows.map(\.1))

        let ids = Set(try await f.db.loadAllThreadSummaries(limit: 100).map(\.threadId))
        XCTAssertTrue(ids.contains(3001), "newest of the duplicate pair is kept")
        XCTAssertFalse(ids.contains(3002), "older duplicate must be folded away")
        XCTAssertTrue(ids.contains(3003), "distinct subject is a separate thread")
    }

    func testNeverCollapsesUnreadDuplicates() async throws {
        let f = try await makeDB(); defer { f.cleanup() }
        let base = 2_000_000_000
        let rows = [
            outgoing(rowid: 4001, mailbox: f.inbox, subject: "Ping", to: "bob@example.com", date: base, isRead: false),
            outgoing(rowid: 4002, mailbox: f.inbox, subject: "Ping", to: "bob@example.com", date: base - 10, isRead: false),
        ]
        try await f.db.upsertMessages(rows.map(\.0))
        try await f.db.upsertRecipients(rows.map(\.1))

        let ids = Set(try await f.db.loadAllThreadSummaries(limit: 100).map(\.threadId))
        XCTAssertTrue(ids.contains(4001) && ids.contains(4002),
                      "unread duplicates must both remain so the list can't fall behind the badge")
    }

    func testIncomingDuplicatesAreNotCollapsed() async throws {
        let f = try await makeDB(); defer { f.cleanup() }
        let base = 2_000_000_000
        // Incoming = sender is NOT one of our addresses; dedup must not fire.
        func incoming(_ rowid: Int) -> (IndexedMessage, IndexedRecipient) {
            let msg = IndexedMessage(
                appleRowId: rowid, appleMessageIdHash: Int64(rowid), mailboxRowId: f.inbox,
                accountUUID: "ACCT", subject: "Newsletter", subjectPrefix: "",
                subjectNormalized: "newsletter",
                senderAddress: "news@vendor.com", senderDisplay: "Vendor",
                dateSent: base - rowid, dateReceived: base - rowid, isRead: true, isFlagged: false,
                hasAttachment: false, rfcMessageId: "<\(rowid)@vendor.com>", imapUID: rowid
            )
            let rcpt = IndexedRecipient(messageRowId: rowid, kind: RecipientKind.to.rawValue,
                                        position: 0, address: ourEmail, display: nil)
            return (msg, rcpt)
        }
        let rows = [incoming(5001), incoming(5002)]
        try await f.db.upsertMessages(rows.map(\.0))
        try await f.db.upsertRecipients(rows.map(\.1))

        let ids = Set(try await f.db.loadAllThreadSummaries(limit: 100).map(\.threadId))
        XCTAssertTrue(ids.contains(5001) && ids.contains(5002),
                      "incoming duplicates are distinct threads — dedup only applies to outgoing")
    }
}
