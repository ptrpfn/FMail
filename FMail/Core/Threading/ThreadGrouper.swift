import Foundation

/// Builds threads via union-find on the `(message_rowid, parent_message_id_hash)`
/// graph from Apple's `message_references`. Output is a list of IndexedThread
/// values with member rowids; the caller persists them.
///
/// Algorithm:
/// 1. Each message starts in its own component.
/// 2. For each link, find the message rowid whose `apple_message_id_hash`
///    equals the link's `to_message_id_hash` (if any), and union the two
///    components.
/// 3. Each component becomes a thread; thread_id = the smallest member rowid
///    (deterministic for re-runs).
/// 4. Aggregate per-thread stats (count, latest date, unread count, flagged).
enum ThreadGrouper {
    static func build(
        messages: [(rowid: Int, hash: Int64, date: Int, isRead: Bool, isFlagged: Bool)],
        links: [(from: Int, toHash: Int64)]
    ) -> [IndexedThread] {
        // Map message rowids to compact indices for the union-find arrays.
        var rowIdToIdx: [Int: Int] = [:]
        rowIdToIdx.reserveCapacity(messages.count)
        var idxToRowId: [Int] = []
        idxToRowId.reserveCapacity(messages.count)
        var hashToIdx: [Int64: Int] = [:]
        hashToIdx.reserveCapacity(messages.count)

        for (i, m) in messages.enumerated() {
            rowIdToIdx[m.rowid] = i
            idxToRowId.append(m.rowid)
            if m.hash != 0 {
                hashToIdx[m.hash] = i
            }
        }

        var parent = Array(0..<messages.count)
        var rank = [Int](repeating: 0, count: messages.count)

        func find(_ x: Int) -> Int {
            var cur = x
            while parent[cur] != cur { cur = parent[cur] }
            // Path compression.
            var node = x
            while parent[node] != cur {
                let next = parent[node]
                parent[node] = cur
                node = next
            }
            return cur
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a)
            let rb = find(b)
            if ra == rb { return }
            if rank[ra] < rank[rb] { parent[ra] = rb }
            else if rank[ra] > rank[rb] { parent[rb] = ra }
            else { parent[rb] = ra; rank[ra] += 1 }
        }

        for link in links {
            guard let fromIdx = rowIdToIdx[link.from] else { continue }
            guard let toIdx = hashToIdx[link.toHash] else { continue }
            union(fromIdx, toIdx)
        }

        // Group indices by root.
        var groups: [Int: [Int]] = [:]
        for i in 0..<messages.count {
            let r = find(i)
            groups[r, default: []].append(i)
        }

        var threads: [IndexedThread] = []
        threads.reserveCapacity(groups.count)
        for (_, members) in groups {
            // thread_id = smallest member rowid (stable across re-runs).
            var memberRowIds: [Int] = []
            memberRowIds.reserveCapacity(members.count)
            var minRowId = Int.max
            var latestDate = 0
            var unread = 0
            var flagged = 0
            for idx in members {
                let m = messages[idx]
                memberRowIds.append(m.rowid)
                if m.rowid < minRowId { minRowId = m.rowid }
                if m.date > latestDate { latestDate = m.date }
                if !m.isRead { unread += 1 }
                if m.isFlagged { flagged += 1 }
            }
            // Earliest dated message in the component is the thread root.
            let earliest = members.min(by: { messages[$0].date < messages[$1].date }) ?? members[0]
            let rootRowId = messages[earliest].rowid

            threads.append(IndexedThread(
                threadId: minRowId,
                rootMessageRowId: rootRowId,
                latestDateReceived: latestDate,
                messageCount: members.count,
                unreadCount: unread,
                flaggedCount: flagged,
                memberRowIds: memberRowIds
            ))
        }
        return threads
    }
}
