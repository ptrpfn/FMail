import Foundation

/// Pure count arithmetic behind `ReadStatusController`'s optimistic flips.
///
/// These functions take plain value inputs and return new values — no
/// `MailModel`, no side effects — so the off-by-one-prone delta math is unit
/// testable in isolation. The controller stays responsible for orchestration
/// (grouping messages, assigning results back to the observable model).
enum OptimisticUpdate {

    /// Signed count change applied per message when flipping to `isRead`:
    /// marking read removes one unread (-1); marking unread adds one (+1).
    static func unreadDelta(isRead: Bool) -> Int { isRead ? -1 : 1 }

    // MARK: — Read flip

    /// Per-mailbox unread delta for flipping `messages` to `isRead`.
    static func mailboxUnreadDeltas(
        forFlipping messages: [MessageHeader], isRead: Bool
    ) -> [Int: Int] {
        let perMessage = unreadDelta(isRead: isRead)
        var deltas: [Int: Int] = [:]
        for m in messages {
            deltas[m.mailboxRowId, default: 0] += perMessage
        }
        return deltas
    }

    /// Apply a read flip to the thread summaries, decrementing/incrementing
    /// each affected thread's `unreadCount` by its flipped-message count.
    /// Threads not present in `flippedCountByThread` are returned unchanged.
    static func applyingReadFlip(
        to summaries: [ThreadSummary],
        flippedCountByThread: [Int: Int],
        isRead: Bool
    ) -> [ThreadSummary] {
        let perMessage = unreadDelta(isRead: isRead)
        return summaries.map { s in
            guard let count = flippedCountByThread[s.threadId], count > 0 else { return s }
            return s.with(unreadCount: max(0, s.unreadCount + count * perMessage))
        }
    }

    // MARK: — Removal

    struct CountDelta: Equatable {
        var total = 0
        var unread = 0
    }

    /// Per-mailbox (total, unread) deltas for removing `messages`. Total drops
    /// by one per message; unread drops by one only for unread messages.
    static func mailboxDeltas(forRemoving messages: [MessageHeader]) -> [Int: CountDelta] {
        var deltas: [Int: CountDelta] = [:]
        for m in messages {
            deltas[m.mailboxRowId, default: CountDelta()].total -= 1
            if !m.isRead { deltas[m.mailboxRowId, default: CountDelta()].unread -= 1 }
        }
        return deltas
    }

    /// Global unread delta for removing `messages` (negative count of the
    /// unread ones).
    static func globalUnreadDelta(forRemoving messages: [MessageHeader]) -> Int {
        -messages.filter { !$0.isRead }.count
    }

    /// Apply removals (grouped by thread) to the summaries: each affected
    /// thread loses `group.count` from `messageCount` and the unread ones from
    /// `unreadCount`; a thread whose `messageCount` reaches zero is dropped.
    static func applyingRemoval(
        to summaries: [ThreadSummary],
        removedByThread: [Int: [MessageHeader]]
    ) -> [ThreadSummary] {
        summaries.compactMap { s in
            guard let group = removedByThread[s.threadId], !group.isEmpty else { return s }
            let newCount = s.messageCount - group.count
            if newCount <= 0 { return nil }
            let unreadDrop = group.filter { !$0.isRead }.count
            return s.with(
                messageCount: newCount,
                unreadCount: max(0, s.unreadCount - unreadDrop)
            )
        }
    }
}
