import AppKit
import Foundation

/// Owns Mark Read / Unread for messages, threads, and search results.
/// All entry points apply the change optimistically (DB + every visible
/// counter updates immediately) and then dispatch one AppleScript at
/// Mail.app in the background. The next FSEvent-driven sync reconciles
/// in case Mail.app couldn't apply the change.
@MainActor
final class ReadStatusController {
    // `unowned`: every entry point is invoked synchronously from the UI/MCP
    // while the model is alive, and the model owns this controller — so it
    // cannot outlive the model. (Long-lived background work uses `[weak
    // model]` captures instead; see `dispatchAppleScript`.) Contrast
    // `SyncCoordinator`, which keeps `weak` because it owns periodic/detached
    // tasks that can fire during model teardown.
    private unowned let model: MailModel

    init(model: MailModel) { self.model = model }

    /// How long to suppress FSEvents-triggered syncs around an AppleScript
    /// write-back so the optimistic flip isn't reverted before Mail.app
    /// commits the change to its Envelope Index.
    private enum SkipWindow: TimeInterval {
        case beforeDispatch = 120
        case afterDispatch = 180
    }

    private func suppressSync(_ window: SkipWindow) {
        model.syncCoordinator?.skipSyncsUntil = Date().addingTimeInterval(window.rawValue)
    }

    // MARK: — Public API

    /// Single-message convenience — same code path as bulk.
    func setReadStatus(_ message: MessageHeader, isRead: Bool) {
        setReadStatus(messages: [message], isRead: isRead)
    }

    /// Bulk Mark Read/Unread for an arbitrary message list.
    func setReadStatus(messages: [MessageHeader], isRead: Bool) {
        Task { @MainActor in
            await applyAndDispatch(messages: messages, isRead: isRead)
        }
    }

    /// Mark a list of messages by rowid; resolves rowids via `IndexDB`,
    /// runs the optimistic-flip pipeline, AWAITS the AppleScript dispatch,
    /// and returns the matched count. Used by the MCP `mark_read` tool —
    /// regular UI callers should use `setReadStatus(messages:isRead:)`.
    @MainActor
    func setReadStatus(rowids: [Int], isRead: Bool) async -> (applied: Int, error: String?) {
        guard let db = model.indexDB else {
            return (0, "Index not loaded")
        }
        var resolved: [MessageHeader] = []
        for rowid in rowids {
            if let m = try? await db.loadMessage(rowid: rowid) {
                resolved.append(m)
            }
        }
        guard !resolved.isEmpty else {
            return (0, "No messages matched the given rowids")
        }

        // Optimistic flip — same path as the existing fire-and-forget API,
        // inlined so we can interleave the awaitable AppleScript step.
        await applyOptimisticReadFlip(messages: resolved, isRead: isRead)

        // AppleScript dispatch — awaited, not Task.detached.
        let entries = mailScripterEntries(for: resolved)
        guard !entries.isEmpty else {
            return (0, "Couldn't build AppleScript entries (mailbox/account info missing)")
        }
        suppressSync(.beforeDispatch)
        let result = await MailScripter.setReadStatusBatch(entries, isRead: isRead)
        suppressSync(.afterDispatch)

        switch result {
        case .ok(let matched):
            return (matched, nil)
        case .notFound:
            return (0, "Mail.app couldn't find any of the selected messages — apple_rowid may be stale.")
        case .failed(let m):
            return (resolved.count, "AppleScript failed: \(m)")
        }
    }

    /// Mark every multi-selected search result.
    func markSelectedSearchResults(asRead isRead: Bool) {
        let messages = model.searchResults.filter {
            model.selectedSearchResultIds.contains($0.rowId)
        }
        guard !messages.isEmpty else { return }
        setReadStatus(messages: messages, isRead: isRead)
    }

    // MARK: — Delete actions

    /// Removes messages from their current mailbox via Mail.app — UI does
    /// the optimistic removal immediately, then the AppleScript dispatch
    /// runs in the background. The next FSEvent-driven sync re-mirrors
    /// Apple's Envelope Index and reconciles the move.
    func deleteMessages(_ messages: [MessageHeader]) {
        Task { @MainActor in
            await applyAndDispatchDelete(messages: messages)
        }
    }

    /// Bulk delete from the current threads selection.
    func deleteSelectedThreads() async {
        guard let db = model.indexDB else { return }
        let viewScope = currentViewScope()
        var allMessages: [MessageHeader] = []
        for tid in model.selectedThreadIds {
            if let msgs = try? await db.loadThreadMessages(threadId: tid, scope: viewScope) {
                allMessages.append(contentsOf: msgs)
            }
        }
        guard !allMessages.isEmpty else { return }
        await applyAndDispatchDelete(messages: allMessages)
    }

    /// Bulk delete from the current search-results selection.
    func deleteSelectedSearchResults() {
        let messages = model.searchResults.filter {
            model.selectedSearchResultIds.contains($0.rowId)
        }
        guard !messages.isEmpty else { return }
        deleteMessages(messages)
    }

    /// Awaitable variant for the MCP `delete_messages` tool.
    @MainActor
    func deleteMessages(rowids: [Int]) async -> (applied: Int, error: String?) {
        guard let db = model.indexDB else {
            return (0, "Index not loaded")
        }
        var resolved: [MessageHeader] = []
        for rowid in rowids {
            if let m = try? await db.loadMessage(rowid: rowid) { resolved.append(m) }
        }
        guard !resolved.isEmpty else {
            return (0, "No messages matched the given rowids")
        }
        await applyOptimisticRemoval(messages: resolved)

        let entries = mailScripterEntries(for: resolved)
        guard !entries.isEmpty else {
            return (0, "Couldn't build AppleScript entries (mailbox/account info missing)")
        }

        suppressSync(.beforeDispatch)
        let result = await MailScripter.deleteBatch(entries)

        // On success: Gmail (and IMAP generally) reassigns apple_rowid when
        // a message moves to Trash — force an immediate sync so MCP queries
        // and the UI see the new state promptly. On failure: keep the
        // suppress window so we don't re-import data that's about to be
        // re-tried.
        switch result {
        case .ok(let matched):
            model.syncCoordinator?.skipSyncsUntil = nil
            await model.syncCoordinator?.runIncrementalSync()
            return (matched, nil)
        case .notFound:
            suppressSync(.afterDispatch)
            return (0, "Mail.app couldn't find any of the selected messages — apple_rowid may be stale.")
        case .failed(let msg):
            suppressSync(.afterDispatch)
            return (resolved.count, "AppleScript failed: \(msg)")
        }
    }

    private func applyAndDispatchDelete(messages: [MessageHeader]) async {
        await applyOptimisticRemoval(messages: messages)

        let entries = mailScripterEntries(for: messages)
        guard !entries.isEmpty else { return }

        suppressSync(.beforeDispatch)
        // Fire-and-forget. `MailScripter` runs osascript on its own serial
        // queue (see `runOsascript`), so awaiting it from this main-actor Task
        // only *suspends* — there's no need to `Task.detached`, and detaching
        // is exactly what made Swift 6 region isolation flag the non-Sendable
        // `model` being sent into the `MainActor.run` closures. Touching
        // `model` only here, on the main actor, sidesteps that.
        Task { [weak model] in
            let result = await MailScripter.deleteBatch(entries)
            switch result {
            case .ok:
                model?.syncCoordinator?.skipSyncsUntil = nil
                await model?.syncCoordinator?.runIncrementalSync()
            case .notFound:
                model?.syncCoordinator?.skipSyncsUntil = Date().addingTimeInterval(SkipWindow.afterDispatch.rawValue)
                model?.bulkActionError = "Mail.app couldn't find some of the selected messages — they may have been moved or removed already (try Tools → Diagnose Mail.app structure)."
            case .failed(let msg):
                model?.syncCoordinator?.skipSyncsUntil = Date().addingTimeInterval(SkipWindow.afterDispatch.rawValue)
                model?.bulkActionError = "Delete failed: \(msg)"
            }
        }
    }

    /// Optimistic removal of `messages` from every visible array AND from
    /// FMail's local index. Decrements the unread/total counts on the
    /// source mailboxes and the global badge. Threads with all members
    /// removed disappear; threads with some members surviving have their
    /// `messageCount`/`unreadCount` reduced.
    ///
    /// The DB delete means any navigation or MCP read immediately after a
    /// delete reflects the post-delete state, without waiting for the next
    /// FSEvent-driven sync. If the underlying AppleScript dispatch fails,
    /// the next full sync re-upserts the rows from Apple's Envelope Index
    /// (which still has them), and the indexer's `pruneMessagesNotIn` pass
    /// only drops rowids that are actually gone from Apple's side.
    ///
    /// Awaitable so callers can guarantee the DB delete lands before they
    /// trigger a follow-up `runIncrementalSync()`.
    private func applyOptimisticRemoval(messages: [MessageHeader]) async {
        guard !messages.isEmpty, let db = model.indexDB else { return }
        let removedRowIds = Set(messages.map(\.rowId))

        // Thread membership — looked up BEFORE the DB delete (which needs the
        // rows still present). Bulk removal may span multiple threads.
        let map = (try? await db.threadIds(forMessages: messages.map(\.rowId))) ?? [:]
        var byThread: [Int: [MessageHeader]] = [:]
        for m in messages {
            if let tid = map[m.rowId] { byThread[tid, default: []].append(m) }
        }

        do {
            try await db.deleteMessagesByRowid(messages.map(\.rowId))
        } catch {
            Log.db.error("Optimistic DB delete failed for \(messages.count) rowids: \(String(describing: error), privacy: .public)")
        }

        // 1) messagesInSelectedThread — drop removed rowids.
        if model.messagesInSelectedThread.contains(where: { removedRowIds.contains($0.rowId) }) {
            model.messagesInSelectedThread.removeAll { removedRowIds.contains($0.rowId) }
        }

        // 2) searchResults — drop removed rowids and prune selection.
        if model.searchResults.contains(where: { removedRowIds.contains($0.rowId) }) {
            model.searchResults.removeAll { removedRowIds.contains($0.rowId) }
            model.selectedSearchResultIds = model.selectedSearchResultIds.subtracting(removedRowIds)
        }

        // 3) threadsForSelectedMailbox — decrement counts; drop empty threads.
        let newThreads = OptimisticUpdate.applyingRemoval(
            to: model.threadsForSelectedMailbox, removedByThread: byThread
        )
        model.threadsForSelectedMailbox = newThreads
        // If the open thread is gone, clear its selection so the reader empties.
        if let tid = model.selectedThreadId,
           !newThreads.contains(where: { $0.threadId == tid }) {
            model.selectedThreadId = nil
            model.selectedThreadIds.remove(tid)
            model.messagesInSelectedThread = []
            model.bodyForSelectedMessage = nil
            model.selectedMessageId = nil
        }

        // 4) Mailboxes — decrement counts on each source mailbox.
        applyMailboxCountDeltas(OptimisticUpdate.mailboxDeltas(forRemoving: messages))

        // 5) Global counter.
        model.allUnreadCount = max(
            0, model.allUnreadCount + OptimisticUpdate.globalUnreadDelta(forRemoving: messages)
        )
    }

    /// Mark every message in every currently-selected thread. Honors the
    /// active scope (e.g. excludes drafts/trash/junk in All Mailboxes view)
    /// so we never accidentally flip a junk-folder message just because it
    /// shares a thread with a real one.
    func markSelectedThreads(asRead isRead: Bool) async {
        guard let db = model.indexDB else { return }
        let viewScope = currentViewScope()
        var perThread: [(threadId: Int, messages: [MessageHeader])] = []
        for tid in model.selectedThreadIds {
            if let msgs = try? await db.loadThreadMessages(threadId: tid, scope: viewScope) {
                let toFlip = msgs.filter { $0.isRead != isRead }
                if !toFlip.isEmpty { perThread.append((tid, toFlip)) }
            }
        }
        guard !perThread.isEmpty else { return }
        applyOptimisticThreadBulkRead(perThread: perThread, isRead: isRead)
        let allMessages = perThread.flatMap { $0.messages }
        await dispatchAppleScript(messages: allMessages, isRead: isRead)
    }

    // MARK: — Pipeline

    /// Look up thread ids for the given messages so the optimistic flip can
    /// update closed-thread summaries too, then apply optimistically and
    /// dispatch the AppleScript.
    private func applyAndDispatch(messages: [MessageHeader], isRead: Bool) async {
        await applyOptimisticReadFlip(messages: messages, isRead: isRead)
        await dispatchAppleScript(messages: messages, isRead: isRead)
    }

    /// Group `messages` by thread id (via IndexDB) and apply the optimistic
    /// read flip. Falls back to a per-message visible-array flip when the DB
    /// lookup is unavailable, so the reader/search views still update.
    private func applyOptimisticReadFlip(messages: [MessageHeader], isRead: Bool) async {
        let perThread = await groupByThread(messages)
        if !perThread.isEmpty {
            applyOptimisticThreadBulkRead(perThread: perThread, isRead: isRead)
        } else {
            applyOptimisticReadFlags(messageRowIds: messages.map(\.rowId), isRead: isRead)
        }
    }

    /// Bucket `messages` by their thread id. Returns `[]` when the index is
    /// unavailable or the lookup fails (callers treat that as "fall back to a
    /// per-message flip").
    private func groupByThread(
        _ messages: [MessageHeader]
    ) async -> [(threadId: Int, messages: [MessageHeader])] {
        guard let db = model.indexDB,
              let map = try? await db.threadIds(forMessages: messages.map(\.rowId)) else {
            return []
        }
        var byThread: [Int: [MessageHeader]] = [:]
        for msg in messages {
            if let tid = map[msg.rowId] { byThread[tid, default: []].append(msg) }
        }
        return byThread.map { (threadId: $0.key, messages: $0.value) }
    }

    /// Build the AppleScript batch and fire it at Mail.app on a detached
    /// task. Suppresses sync long enough for the batch to land — one batch
    /// can take a while if it spans multiple Gmail accounts. Sets the skip
    /// window once before dispatch (covers the common case) and once after
    /// (covers slow brute-walks where Mail.app needs additional time to
    /// commit to its Envelope Index after `set read status`).
    private func dispatchAppleScript(messages: [MessageHeader], isRead: Bool) async {
        let entries = mailScripterEntries(for: messages)
        guard !entries.isEmpty else { return }

        suppressSync(.beforeDispatch)

        // Fire-and-forget on the main actor — see the note in
        // `applyAndDispatchDelete`. The osascript runs off-thread inside
        // `MailScripter`; `model` is only ever touched here on the main actor.
        Task { [weak model] in
            let result = await MailScripter.setReadStatusBatch(entries, isRead: isRead)
            model?.syncCoordinator?.skipSyncsUntil = Date().addingTimeInterval(SkipWindow.afterDispatch.rawValue)
            switch result {
            case .ok:
                break
            case .notFound:
                model?.bulkActionError = "Mail.app couldn't find some of the selected messages — they may not have been downloaded yet, or Mail.app's mailbox layout doesn't match (try Tools → Diagnose Mail.app structure)."
            case .failed(let msg):
                model?.bulkActionError = "Bulk Mark as Read failed: \(msg)"
            }
        }
    }

    private func currentViewScope() -> IndexDB.ThreadViewScope {
        MailboxKind.viewScope(
            forSelectedKind: model.selectedMailbox?.kind,
            allMailboxesScope: model.isAllMailboxesScope
        )
    }

    /// Build AppleScript entries from messages, looking up each message's
    /// canonical mailbox + account so MailScripter can use the fast
    /// `whose id is N` path instead of the slow message-id scan.
    private func mailScripterEntries(for messages: [MessageHeader]) -> [MailScripter.BatchEntry] {
        messages.compactMap { msg in
            let mb = model.mailboxes.first { $0.rowId == msg.mailboxRowId }
            let acct = mb.flatMap { mb in
                model.accounts.first { $0.uuid == mb.accountUUID }
            }
            return MailScripter.BatchEntry(
                rfcMessageId: msg.rfcMessageId ?? "",
                appleRowId: msg.rowId,
                accountEmail: acct?.emailAddress,
                mailboxPathComponents: mb?.pathComponents
            )
        }
    }

    // MARK: — Optimistic flips

    /// Thread-aware optimistic flip. Updates every selected thread's
    /// summary by the count of its flipped messages — works even for
    /// threads whose messages aren't loaded into `messagesInSelectedThread`
    /// (i.e., closed threads in a multi-select).
    private func applyOptimisticThreadBulkRead(
        perThread: [(threadId: Int, messages: [MessageHeader])],
        isRead: Bool
    ) {
        let allMessages = perThread.flatMap { $0.messages }

        // Thread summaries — decrement/increment each by its flipped count.
        let flippedCountByThread = Dictionary(
            perThread.map { ($0.threadId, $0.messages.count) }, uniquingKeysWith: +
        )
        model.threadsForSelectedMailbox = OptimisticUpdate.applyingReadFlip(
            to: model.threadsForSelectedMailbox,
            flippedCountByThread: flippedCountByThread,
            isRead: isRead
        )

        // Sidebar mailbox unread counts.
        applyMailboxUnreadDeltas(
            OptimisticUpdate.mailboxUnreadDeltas(forFlipping: allMessages, isRead: isRead)
        )

        // Flip the per-message read dot wherever these messages are visible.
        flipReadInVisibleArrays(rowIds: Set(allMessages.map(\.rowId)), isRead: isRead)

        // Global counter.
        let totalDelta = allMessages.count * OptimisticUpdate.unreadDelta(isRead: isRead)
        model.allUnreadCount = max(0, model.allUnreadCount + totalDelta)

        // Persist to DB.
        if let db = model.indexDB {
            persistIsRead(rowids: allMessages.map(\.rowId), isRead: isRead, db: db)
        }
    }

    /// Per-message fallback when the thread-id lookup failed. Discovers each
    /// message's previous read state and mailbox from the visible arrays
    /// (`messagesInSelectedThread`, `searchResults`) — the only places it can
    /// see them without the DB — and updates counts from there.
    private func applyOptimisticReadFlags(messageRowIds: [Int], isRead: Bool) {
        guard !messageRowIds.isEmpty else { return }

        var newSearchResults = model.searchResults
        var newMessagesInThread = model.messagesInSelectedThread

        var unreadCountDelta = 0
        var mailboxDeltas: [Int: Int] = [:]
        var flippedRowIds: [Int] = []
        let perMessage = OptimisticUpdate.unreadDelta(isRead: isRead)

        for rowId in messageRowIds {
            var prevIsRead: Bool? = nil
            var mailboxRowId: Int? = nil

            if let idx = newMessagesInThread.firstIndex(where: { $0.rowId == rowId }) {
                prevIsRead = newMessagesInThread[idx].isRead
                mailboxRowId = newMessagesInThread[idx].mailboxRowId
                newMessagesInThread[idx] = newMessagesInThread[idx].withIsRead(isRead)
            }
            if let idx = newSearchResults.firstIndex(where: { $0.rowId == rowId }) {
                if prevIsRead == nil { prevIsRead = newSearchResults[idx].isRead }
                if mailboxRowId == nil { mailboxRowId = newSearchResults[idx].mailboxRowId }
                newSearchResults[idx] = newSearchResults[idx].withIsRead(isRead)
            }

            if let prev = prevIsRead, prev != isRead {
                unreadCountDelta += perMessage
                if let mid = mailboxRowId { mailboxDeltas[mid, default: 0] += perMessage }
                flippedRowIds.append(rowId)
            }
        }

        model.searchResults = newSearchResults
        model.messagesInSelectedThread = newMessagesInThread

        applyMailboxUnreadDeltas(mailboxDeltas)

        // Open thread's summary — count how many flipped messages belong
        // to it (may differ when bulk-marking from search results that
        // span multiple threads).
        if !flippedRowIds.isEmpty,
           let tid = model.selectedThreadId,
           let summaryIdx = model.threadsForSelectedMailbox.firstIndex(where: { $0.threadId == tid }) {
            let inThreadCount = flippedRowIds.filter { id in
                newMessagesInThread.contains(where: { $0.rowId == id })
            }.count
            if inThreadCount > 0 {
                let s = model.threadsForSelectedMailbox[summaryIdx]
                model.threadsForSelectedMailbox[summaryIdx] =
                    s.with(unreadCount: max(0, s.unreadCount + inThreadCount * perMessage))
            }
        }

        model.allUnreadCount = max(0, model.allUnreadCount + unreadCountDelta)

        if let db = model.indexDB, !flippedRowIds.isEmpty {
            persistIsRead(rowids: flippedRowIds, isRead: isRead, db: db)
        }
    }

    // MARK: — Shared model mutations

    /// Apply per-mailbox unread deltas to the sidebar, in one assignment.
    private func applyMailboxUnreadDeltas(_ deltas: [Int: Int]) {
        guard !deltas.isEmpty else { return }
        model.mailboxes = model.mailboxes.map { mb in
            guard let delta = deltas[mb.rowId], delta != 0 else { return mb }
            return mb.with(unreadCount: max(0, mb.unreadCount + delta))
        }
    }

    /// Apply per-mailbox total+unread deltas (used by removal), in one
    /// assignment.
    private func applyMailboxCountDeltas(_ deltas: [Int: OptimisticUpdate.CountDelta]) {
        guard !deltas.isEmpty else { return }
        model.mailboxes = model.mailboxes.map { mb in
            guard let d = deltas[mb.rowId] else { return mb }
            return mb.with(
                totalCount: max(0, mb.totalCount + d.total),
                unreadCount: max(0, mb.unreadCount + d.unread)
            )
        }
    }

    /// Flip the read flag on `rowIds` wherever they appear in the open thread
    /// or the search results, reassigning each array at most once.
    private func flipReadInVisibleArrays(rowIds: Set<Int>, isRead: Bool) {
        if model.messagesInSelectedThread.contains(where: { rowIds.contains($0.rowId) && $0.isRead != isRead }) {
            model.messagesInSelectedThread = model.messagesInSelectedThread.map {
                rowIds.contains($0.rowId) && $0.isRead != isRead ? $0.withIsRead(isRead) : $0
            }
        }
        if model.searchResults.contains(where: { rowIds.contains($0.rowId) && $0.isRead != isRead }) {
            model.searchResults = model.searchResults.map {
                rowIds.contains($0.rowId) && $0.isRead != isRead ? $0.withIsRead(isRead) : $0
            }
        }
    }

    /// One-transaction batch write of `is_read`. Failures show up as a
    /// `bulkActionError` alert — without surfacing, the optimistic in-memory
    /// flip would silently revert on the next sync, leaving the user with
    /// no idea what happened.
    private func persistIsRead(rowids: [Int], isRead: Bool, db: IndexDB) {
        // Inherits MainActor isolation from this @MainActor method, so the
        // catch block runs back on the main actor without an explicit hop.
        Task { [weak model] in
            do {
                try await db.setIsReadBatch(rowids: rowids, isRead: isRead)
            } catch {
                Log.db.error("setIsReadBatch failed for \(rowids.count) rows: \(String(describing: error), privacy: .public)")
                model?.bulkActionError = "Couldn't update read status in the local index — your change may not stick after the next sync. (\(error.localizedDescription))"
            }
        }
    }
}
