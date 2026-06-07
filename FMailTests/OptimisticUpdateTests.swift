import XCTest
@testable import FMail

/// Tests for the pure count arithmetic behind ReadStatusController's
/// optimistic flips. No Mail.app, file system, or SQLite — pure value math.
final class OptimisticUpdateTests: XCTestCase {

    // MARK: — Builders

    private func msg(_ rowId: Int, mailbox: Int = 1, isRead: Bool) -> MessageHeader {
        MessageHeader(
            rowId: rowId, mailboxRowId: mailbox, subject: "s",
            senderAddress: "a@b.c", senderDisplay: "A",
            dateSent: nil, dateReceived: nil,
            isRead: isRead, isFlagged: false, hasAttachment: false,
            rfcMessageId: nil, imapUID: nil
        )
    }

    private func summary(_ threadId: Int, messageCount: Int, unreadCount: Int) -> ThreadSummary {
        ThreadSummary(
            threadId: threadId, latestDateReceived: nil,
            messageCount: messageCount, unreadCount: unreadCount,
            flaggedCount: 0, latestSubject: "s", latestSenderDisplay: "A",
            latestMessageRowId: threadId * 100, latestIsOutgoing: false
        )
    }

    // MARK: — unreadDelta

    func testUnreadDeltaSign() {
        XCTAssertEqual(OptimisticUpdate.unreadDelta(isRead: true), -1)
        XCTAssertEqual(OptimisticUpdate.unreadDelta(isRead: false), 1)
    }

    // MARK: — Read flip: mailbox deltas

    func testMailboxUnreadDeltasAggregatesPerMailbox() {
        let messages = [
            msg(1, mailbox: 10, isRead: false),
            msg(2, mailbox: 10, isRead: false),
            msg(3, mailbox: 20, isRead: false),
        ]
        let deltas = OptimisticUpdate.mailboxUnreadDeltas(forFlipping: messages, isRead: true)
        XCTAssertEqual(deltas[10], -2)
        XCTAssertEqual(deltas[20], -1)
    }

    func testMailboxUnreadDeltasMarkUnreadIsPositive() {
        let deltas = OptimisticUpdate.mailboxUnreadDeltas(
            forFlipping: [msg(1, mailbox: 5, isRead: true)], isRead: false
        )
        XCTAssertEqual(deltas[5], 1)
    }

    // MARK: — Read flip: thread summaries

    func testApplyingReadFlipDecrementsAffectedThreadsOnly() {
        let summaries = [
            summary(1, messageCount: 3, unreadCount: 3),
            summary(2, messageCount: 1, unreadCount: 0),
        ]
        let result = OptimisticUpdate.applyingReadFlip(
            to: summaries, flippedCountByThread: [1: 2], isRead: true
        )
        XCTAssertEqual(result[0].unreadCount, 1, "thread 1 loses 2 unread")
        XCTAssertEqual(result[0].messageCount, 3, "messageCount untouched by a read flip")
        XCTAssertEqual(result[1].unreadCount, 0, "thread 2 untouched")
    }

    func testApplyingReadFlipClampsAtZero() {
        let result = OptimisticUpdate.applyingReadFlip(
            to: [summary(1, messageCount: 5, unreadCount: 1)],
            flippedCountByThread: [1: 3], isRead: true
        )
        XCTAssertEqual(result[0].unreadCount, 0, "unread never goes negative")
    }

    func testApplyingReadFlipMarkUnreadIncrements() {
        let result = OptimisticUpdate.applyingReadFlip(
            to: [summary(1, messageCount: 5, unreadCount: 1)],
            flippedCountByThread: [1: 2], isRead: false
        )
        XCTAssertEqual(result[0].unreadCount, 3)
    }

    // MARK: — Removal: mailbox deltas

    func testRemovalMailboxDeltasTotalAndUnread() {
        let messages = [
            msg(1, mailbox: 10, isRead: false),
            msg(2, mailbox: 10, isRead: true),
            msg(3, mailbox: 20, isRead: false),
        ]
        let deltas = OptimisticUpdate.mailboxDeltas(forRemoving: messages)
        XCTAssertEqual(deltas[10], .init(total: -2, unread: -1),
                       "both removed from mailbox 10; only the unread one drops unread")
        XCTAssertEqual(deltas[20], .init(total: -1, unread: -1))
    }

    func testGlobalUnreadDeltaCountsOnlyUnread() {
        let messages = [
            msg(1, isRead: false),
            msg(2, isRead: true),
            msg(3, isRead: false),
        ]
        XCTAssertEqual(OptimisticUpdate.globalUnreadDelta(forRemoving: messages), -2)
    }

    // MARK: — Removal: thread summaries

    func testApplyingRemovalDecrementsCounts() {
        let summaries = [summary(1, messageCount: 3, unreadCount: 2)]
        let removed = [1: [msg(10, isRead: false)]]
        let result = OptimisticUpdate.applyingRemoval(to: summaries, removedByThread: removed)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].messageCount, 2)
        XCTAssertEqual(result[0].unreadCount, 1)
    }

    func testApplyingRemovalDropsEmptiedThread() {
        let summaries = [
            summary(1, messageCount: 1, unreadCount: 1),
            summary(2, messageCount: 2, unreadCount: 0),
        ]
        let removed = [1: [msg(10, isRead: false)]]
        let result = OptimisticUpdate.applyingRemoval(to: summaries, removedByThread: removed)
        XCTAssertEqual(result.map(\.threadId), [2],
                       "thread 1 emptied and dropped; thread 2 survives unchanged")
    }

    func testApplyingRemovalClampsUnreadAtZero() {
        // Summary claims 1 unread but two unread messages are removed (stale
        // count) — unread must not go negative.
        let summaries = [summary(1, messageCount: 3, unreadCount: 1)]
        let removed = [1: [msg(10, isRead: false), msg(11, isRead: false)]]
        let result = OptimisticUpdate.applyingRemoval(to: summaries, removedByThread: removed)
        XCTAssertEqual(result[0].messageCount, 1)
        XCTAssertEqual(result[0].unreadCount, 0)
    }

    func testApplyingRemovalLeavesUnaffectedThreads() {
        let summaries = [summary(1, messageCount: 3, unreadCount: 2)]
        let result = OptimisticUpdate.applyingRemoval(to: summaries, removedByThread: [:])
        XCTAssertEqual(result, summaries)
    }
}
