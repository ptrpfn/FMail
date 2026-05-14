import AppKit
import Foundation

/// Owns Mark Read / Unread for messages, threads, and search results.
/// All entry points apply the change optimistically (DB + every visible
/// counter updates immediately) and then dispatch one AppleScript at
/// Mail.app in the background. The next FSEvent-driven sync reconciles
/// in case Mail.app couldn't apply the change.
@MainActor
final class ReadStatusController {
    private unowned let model: MailModel

    init(model: MailModel) { self.model = model }

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
        let perThread: [(threadId: Int, messages: [MessageHeader])]
        if let map = try? await db.threadIds(forMessages: resolved.map(\.rowId)) {
            var byThread: [Int: [MessageHeader]] = [:]
            for msg in resolved {
                if let tid = map[msg.rowId] {
                    byThread[tid, default: []].append(msg)
                }
            }
            perThread = byThread.map { (threadId: $0.key, messages: $0.value) }
        } else {
            perThread = []
        }
        if !perThread.isEmpty {
            applyOptimisticThreadBulkRead(perThread: perThread, isRead: isRead)
        } else {
            applyOptimisticReadFlags(messageRowIds: resolved.map(\.rowId), isRead: isRead)
        }

        // AppleScript dispatch — awaited, not Task.detached.
        let entries = mailScripterEntries(for: resolved)
        guard !entries.isEmpty else {
            return (0, "Couldn't build AppleScript entries (mailbox/account info missing)")
        }
        model.syncCoordinator?.skipSyncsUntil = Date().addingTimeInterval(120)
        let result = await MailScripter.setReadStatusBatch(entries, isRead: isRead)
        model.syncCoordinator?.skipSyncsUntil = Date().addingTimeInterval(180)

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

    // MARK: — Move actions (Delete / Move to Junk)

    /// Removes messages from their current mailbox via Mail.app — UI does
    /// the optimistic removal immediately, then the AppleScript dispatch
    /// runs in the background. The next FSEvent-driven sync re-mirrors
    /// Apple's Envelope Index and reconciles the move.
    func deleteMessages(_ messages: [MessageHeader]) {
        Task { @MainActor in
            await applyAndDispatchMove(messages: messages, kind: .delete)
        }
    }

    /// Like `deleteMessages` but routes to the per-account Junk mailbox.
    func moveMessagesToJunk(_ messages: [MessageHeader]) {
        Task { @MainActor in
            await applyAndDispatchMove(messages: messages, kind: .junk)
        }
    }

    /// Bulk delete from the current threads selection.
    func deleteSelectedThreads() async {
        await markSelectedThreads(action: .delete)
    }

    /// Bulk Move to Junk from the current threads selection.
    func moveSelectedThreadsToJunk() async {
        await markSelectedThreads(action: .junk)
    }

    /// Bulk delete from the current search-results selection.
    func deleteSelectedSearchResults() {
        let messages = model.searchResults.filter {
            model.selectedSearchResultIds.contains($0.rowId)
        }
        guard !messages.isEmpty else { return }
        deleteMessages(messages)
    }

    /// Bulk Move to Junk from the current search-results selection.
    func moveSelectedSearchResultsToJunk() {
        let messages = model.searchResults.filter {
            model.selectedSearchResultIds.contains($0.rowId)
        }
        guard !messages.isEmpty else { return }
        moveMessagesToJunk(messages)
    }

    /// Awaitable variant for the MCP `delete_messages` tool.
    @MainActor
    func deleteMessages(rowids: [Int]) async -> (applied: Int, error: String?) {
        await runMoveByRowids(rowids: rowids, kind: .delete)
    }

    /// Awaitable variant for the MCP `move_to_junk` tool.
    @MainActor
    func moveToJunk(rowids: [Int]) async -> (applied: Int, error: String?) {
        await runMoveByRowids(rowids: rowids, kind: .junk)
    }

    // MARK: — Shared move/delete pipeline

    enum MoveKind {
        case delete, junk

        var verbForError: String {
            switch self {
            case .delete: return "Delete"
            case .junk:   return "Move to Junk"
            }
        }
    }

    private func markSelectedThreads(action kind: MoveKind) async {
        guard let db = model.indexDB else { return }
        let viewScope = currentViewScope()
        var allMessages: [MessageHeader] = []
        for tid in model.selectedThreadIds {
            if let msgs = try? await db.loadThreadMessages(threadId: tid, scope: viewScope) {
                allMessages.append(contentsOf: msgs)
            }
        }
        guard !allMessages.isEmpty else { return }
        await applyAndDispatchMove(messages: allMessages, kind: kind)
    }

    private func runMoveByRowids(rowids: [Int], kind: MoveKind) async -> (applied: Int, error: String?) {
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
        applyOptimisticRemoval(messages: resolved)

        let entries = mailScripterEntries(for: resolved)
        guard !entries.isEmpty else {
            return (0, "Couldn't build AppleScript entries (mailbox/account info missing)")
        }
        model.syncCoordinator?.skipSyncsUntil = Date().addingTimeInterval(120)
        let result = await dispatchMove(entries: entries, kind: kind)

        // For successful moves: Gmail (and IMAP generally) reassigns the
        // message's apple_rowid when it changes mailboxes — the old rowid
        // becomes invalid and a new rowid appears in the destination
        // mailbox. FMail's index still has the OLD rowid pointing to the
        // source mailbox until sync re-reads Apple's Envelope Index. Force
        // an immediate sync so MCP queries (and the UI) see the new state
        // promptly. For failures: keep the suppress window so we don't
        // re-import data that's about to be re-tried.
        switch result {
        case .ok(let matched):
            model.syncCoordinator?.skipSyncsUntil = nil
            await model.syncCoordinator?.runIncrementalSync()
            return (matched, nil)
        case .notFound:
            model.syncCoordinator?.skipSyncsUntil = Date().addingTimeInterval(180)
            return (0, "Mail.app couldn't find any of the messages — apple_rowid may be stale.")
        case .failed(let m):
            model.syncCoordinator?.skipSyncsUntil = Date().addingTimeInterval(180)
            return (resolved.count, "AppleScript failed: \(m)")
        }
    }

    private func applyAndDispatchMove(messages: [MessageHeader], kind: MoveKind) async {
        applyOptimisticRemoval(messages: messages)

        let entries = mailScripterEntries(for: messages)
        guard !entries.isEmpty else { return }

        model.syncCoordinator?.skipSyncsUntil = Date().addingTimeInterval(120)
        Task.detached { [weak model] in
            let result = await Self.dispatchMove(entries: entries, kind: kind)
            switch result {
            case .ok:
                // Force an immediate sync so the index picks up the new
                // post-move rowids (Gmail reassigns on label changes).
                // Otherwise the optimistic UI removal hides the messages
                // but MCP / DB queries see stale state for ~3 minutes.
                await MainActor.run {
                    model?.syncCoordinator?.skipSyncsUntil = nil
                }
                if let sc = await MainActor.run(body: { model?.syncCoordinator }) {
                    await sc.runIncrementalSync()
                }
            case .notFound:
                await MainActor.run {
                    model?.syncCoordinator?.skipSyncsUntil = Date().addingTimeInterval(180)
                    model?.bulkActionError = "Mail.app couldn't find some of the selected messages — they may have been moved or removed already (try Tools → Diagnose Mail.app structure)."
                }
            case .failed(let msg):
                await MainActor.run {
                    model?.syncCoordinator?.skipSyncsUntil = Date().addingTimeInterval(180)
                    model?.bulkActionError = "\(kind.verbForError) failed: \(msg)"
                }
            }
        }
    }

    private func dispatchMove(entries: [MailScripter.BatchEntry], kind: MoveKind) async -> MailScripter.Result {
        await Self.dispatchMove(entries: entries, kind: kind)
    }

    nonisolated private static func dispatchMove(entries: [MailScripter.BatchEntry], kind: MoveKind) async -> MailScripter.Result {
        switch kind {
        case .delete: return await MailScripter.deleteBatch(entries)
        case .junk:   return await MailScripter.moveToJunkBatch(entries)
        }
    }

    /// Optimistic removal of `messages` from every visible array. Decrements
    /// the unread/total counts on the source mailboxes and the global badge.
    /// Threads with all members removed disappear; threads with some members
    /// surviving have their `messageCount`/`unreadCount` reduced.
    /// We do NOT update the DB — the next FSEvent-driven sync will re-mirror
    /// Apple's Envelope Index and reconcile naturally.
    private func applyOptimisticRemoval(messages: [MessageHeader]) {
        guard !messages.isEmpty else { return }
        let removedRowIds = Set(messages.map(\.rowId))

        // Per-thread + per-mailbox tallies for count maintenance.
        var byThread: [Int: [MessageHeader]] = [:]
        var perMailboxTotalDelta: [Int: Int] = [:]
        var perMailboxUnreadDelta: [Int: Int] = [:]
        var globalUnreadDelta = 0

        for m in messages {
            perMailboxTotalDelta[m.mailboxRowId, default: 0] -= 1
            if !m.isRead {
                perMailboxUnreadDelta[m.mailboxRowId, default: 0] -= 1
                globalUnreadDelta -= 1
            }
        }

        // Resolve thread ids in the order we have them in messagesInSelectedThread
        // (we already know thread membership from the open thread, but bulk
        // removal may span multiple threads). Use a sync DB hop.
        Task { @MainActor [weak model] in
            guard let model, let db = model.indexDB else { return }
            let map = (try? await db.threadIds(forMessages: messages.map(\.rowId))) ?? [:]
            for m in messages {
                if let tid = map[m.rowId] { byThread[tid, default: []].append(m) }
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
            var newThreads = model.threadsForSelectedMailbox
            for (tid, group) in byThread {
                guard let idx = newThreads.firstIndex(where: { $0.threadId == tid }) else { continue }
                let s = newThreads[idx]
                let unreadDrop = group.filter { !$0.isRead }.count
                let newCount = max(0, s.messageCount - group.count)
                if newCount == 0 {
                    newThreads.remove(at: idx)
                } else {
                    newThreads[idx] = ThreadSummary(
                        threadId: s.threadId,
                        latestDateReceived: s.latestDateReceived,
                        messageCount: newCount,
                        unreadCount: max(0, s.unreadCount - unreadDrop),
                        flaggedCount: s.flaggedCount,
                        latestSubject: s.latestSubject,
                        latestSenderDisplay: s.latestSenderDisplay,
                        latestMessageRowId: s.latestMessageRowId,
                        latestIsOutgoing: s.latestIsOutgoing
                    )
                }
            }
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
            if !perMailboxTotalDelta.isEmpty {
                var newMailboxes = model.mailboxes
                for (mid, totalDelta) in perMailboxTotalDelta {
                    let unreadDelta = perMailboxUnreadDelta[mid] ?? 0
                    if let idx = newMailboxes.firstIndex(where: { $0.rowId == mid }) {
                        let mb = newMailboxes[idx]
                        newMailboxes[idx] = Mailbox(
                            rowId: mb.rowId, accountUUID: mb.accountUUID,
                            pathComponents: mb.pathComponents,
                            totalCount: max(0, mb.totalCount + totalDelta),
                            unreadCount: max(0, mb.unreadCount + unreadDelta),
                            hidden: mb.hidden, kind: mb.kind
                        )
                    }
                }
                model.mailboxes = newMailboxes
            }

            // 5) Global badge.
            model.allUnreadCount = max(0, model.allUnreadCount + globalUnreadDelta)
            model.updateDockBadge()
        }
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
        let perThread: [(threadId: Int, messages: [MessageHeader])]
        if let db = model.indexDB,
           let map = try? await db.threadIds(forMessages: messages.map(\.rowId)) {
            var byThread: [Int: [MessageHeader]] = [:]
            for msg in messages {
                if let tid = map[msg.rowId] {
                    byThread[tid, default: []].append(msg)
                }
            }
            perThread = byThread.map { ($0.key, $0.value) }
        } else {
            perThread = []
        }

        if !perThread.isEmpty {
            applyOptimisticThreadBulkRead(perThread: perThread, isRead: isRead)
        } else {
            // Fallback when DB lookup failed: at least flip the per-message
            // state so the search/reader views update.
            applyOptimisticReadFlags(messageRowIds: messages.map(\.rowId), isRead: isRead)
        }
        await dispatchAppleScript(messages: messages, isRead: isRead)
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

        model.syncCoordinator?.skipSyncsUntil = Date().addingTimeInterval(120)

        Task.detached { [weak model] in
            let result = await MailScripter.setReadStatusBatch(entries, isRead: isRead)
            await MainActor.run {
                model?.syncCoordinator?.skipSyncsUntil = Date().addingTimeInterval(180)
            }
            switch result {
            case .ok:
                break
            case .notFound:
                await MainActor.run {
                    model?.bulkActionError = "Mail.app couldn't find some of the selected messages — they may not have been downloaded yet, or Mail.app's mailbox layout doesn't match (try Tools → Diagnose Mail.app structure)."
                }
            case .failed(let msg):
                await MainActor.run {
                    model?.bulkActionError = "Bulk Mark as Read failed: \(msg)"
                }
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
        let perMessageDelta = isRead ? -1 : 1

        // Update every selected thread's summary.
        var newThreads = model.threadsForSelectedMailbox
        for (tid, msgs) in perThread {
            if let idx = newThreads.firstIndex(where: { $0.threadId == tid }) {
                let s = newThreads[idx]
                let delta = msgs.count * perMessageDelta
                newThreads[idx] = ThreadSummary(
                    threadId: s.threadId,
                    latestDateReceived: s.latestDateReceived,
                    messageCount: s.messageCount,
                    unreadCount: max(0, s.unreadCount + delta),
                    flaggedCount: s.flaggedCount,
                    latestSubject: s.latestSubject,
                    latestSenderDisplay: s.latestSenderDisplay,
                    latestMessageRowId: s.latestMessageRowId,
                    latestIsOutgoing: s.latestIsOutgoing
                )
            }
        }
        model.threadsForSelectedMailbox = newThreads

        // Aggregate per-mailbox deltas, update sidebar counts.
        let allMessages = perThread.flatMap { $0.messages }
        var mailboxDeltas: [Int: Int] = [:]
        for msg in allMessages {
            mailboxDeltas[msg.mailboxRowId, default: 0] += perMessageDelta
        }
        if !mailboxDeltas.isEmpty {
            var newMailboxes = model.mailboxes
            for (mid, delta) in mailboxDeltas {
                if let idx = newMailboxes.firstIndex(where: { $0.rowId == mid }) {
                    let mb = newMailboxes[idx]
                    newMailboxes[idx] = Mailbox(
                        rowId: mb.rowId, accountUUID: mb.accountUUID,
                        pathComponents: mb.pathComponents,
                        totalCount: mb.totalCount,
                        unreadCount: max(0, mb.unreadCount + delta),
                        hidden: mb.hidden, kind: mb.kind
                    )
                }
            }
            model.mailboxes = newMailboxes
        }

        // Update messagesInSelectedThread for any flipped message that is
        // in the open thread (so the reader's per-message dot updates too).
        let flippedRowIds = Set(allMessages.map(\.rowId))
        var newMessagesInThread = model.messagesInSelectedThread
        var anyChangedInThread = false
        for idx in newMessagesInThread.indices {
            let m = newMessagesInThread[idx]
            if flippedRowIds.contains(m.rowId), m.isRead != isRead {
                newMessagesInThread[idx] = MessageHeader(
                    rowId: m.rowId, mailboxRowId: m.mailboxRowId, subject: m.subject,
                    senderAddress: m.senderAddress, senderDisplay: m.senderDisplay,
                    dateSent: m.dateSent, dateReceived: m.dateReceived,
                    isRead: isRead, isFlagged: m.isFlagged,
                    rfcMessageId: m.rfcMessageId, imapUID: m.imapUID
                )
                anyChangedInThread = true
            }
        }
        if anyChangedInThread { model.messagesInSelectedThread = newMessagesInThread }

        // Same for searchResults if any of these messages are showing there.
        var newSearchResults = model.searchResults
        var anyChangedInSearch = false
        for idx in newSearchResults.indices {
            let m = newSearchResults[idx]
            if flippedRowIds.contains(m.rowId), m.isRead != isRead {
                newSearchResults[idx] = MessageHeader(
                    rowId: m.rowId, mailboxRowId: m.mailboxRowId, subject: m.subject,
                    senderAddress: m.senderAddress, senderDisplay: m.senderDisplay,
                    dateSent: m.dateSent, dateReceived: m.dateReceived,
                    isRead: isRead, isFlagged: m.isFlagged,
                    rfcMessageId: m.rfcMessageId, imapUID: m.imapUID
                )
                anyChangedInSearch = true
            }
        }
        if anyChangedInSearch { model.searchResults = newSearchResults }

        // Global counter + dock badge.
        let totalDelta = allMessages.count * perMessageDelta
        model.allUnreadCount = max(0, model.allUnreadCount + totalDelta)
        model.updateDockBadge()

        // Persist to DB.
        if let db = model.indexDB {
            let ids = allMessages.map(\.rowId)
            persistIsRead(rowids: ids, isRead: isRead, db: db)
        }
    }

    /// Per-message fallback when DB lookup failed. Applies *all* changes to
    /// each array (`searchResults`, `messagesInSelectedThread`, `mailboxes`,
    /// `threadsForSelectedMailbox`) with a single assignment per array, so
    /// SwiftUI sees one observable mutation per array. Counters are
    /// aggregated across the batch.
    private func applyOptimisticReadFlags(messageRowIds: [Int], isRead: Bool) {
        guard !messageRowIds.isEmpty else { return }

        var newSearchResults = model.searchResults
        var newMessagesInThread = model.messagesInSelectedThread

        var unreadCountDelta = 0
        var mailboxDeltas: [Int: Int] = [:]
        var flippedRowIds: [Int] = []

        for rowId in messageRowIds {
            var prevIsRead: Bool? = nil
            var mailboxRowId: Int? = nil

            if let idx = newMessagesInThread.firstIndex(where: { $0.rowId == rowId }) {
                let m = newMessagesInThread[idx]
                prevIsRead = m.isRead
                mailboxRowId = m.mailboxRowId
                newMessagesInThread[idx] = MessageHeader(
                    rowId: m.rowId, mailboxRowId: m.mailboxRowId, subject: m.subject,
                    senderAddress: m.senderAddress, senderDisplay: m.senderDisplay,
                    dateSent: m.dateSent, dateReceived: m.dateReceived,
                    isRead: isRead, isFlagged: m.isFlagged,
                    rfcMessageId: m.rfcMessageId, imapUID: m.imapUID
                )
            }
            if let idx = newSearchResults.firstIndex(where: { $0.rowId == rowId }) {
                let m = newSearchResults[idx]
                if prevIsRead == nil { prevIsRead = m.isRead }
                if mailboxRowId == nil { mailboxRowId = m.mailboxRowId }
                newSearchResults[idx] = MessageHeader(
                    rowId: m.rowId, mailboxRowId: m.mailboxRowId, subject: m.subject,
                    senderAddress: m.senderAddress, senderDisplay: m.senderDisplay,
                    dateSent: m.dateSent, dateReceived: m.dateReceived,
                    isRead: isRead, isFlagged: m.isFlagged,
                    rfcMessageId: m.rfcMessageId, imapUID: m.imapUID
                )
            }

            if let prev = prevIsRead, prev != isRead {
                let d = isRead ? -1 : 1
                unreadCountDelta += d
                if let mid = mailboxRowId {
                    mailboxDeltas[mid, default: 0] += d
                }
                flippedRowIds.append(rowId)
            }
        }

        model.searchResults = newSearchResults
        model.messagesInSelectedThread = newMessagesInThread

        if !mailboxDeltas.isEmpty {
            var newMailboxes = model.mailboxes
            for (mid, delta) in mailboxDeltas {
                if let idx = newMailboxes.firstIndex(where: { $0.rowId == mid }) {
                    let mb = newMailboxes[idx]
                    newMailboxes[idx] = Mailbox(
                        rowId: mb.rowId, accountUUID: mb.accountUUID,
                        pathComponents: mb.pathComponents,
                        totalCount: mb.totalCount,
                        unreadCount: max(0, mb.unreadCount + delta),
                        hidden: mb.hidden, kind: mb.kind
                    )
                }
            }
            model.mailboxes = newMailboxes
        }

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
                let threadDelta = inThreadCount * (isRead ? -1 : 1)
                let s = model.threadsForSelectedMailbox[summaryIdx]
                model.threadsForSelectedMailbox[summaryIdx] = ThreadSummary(
                    threadId: s.threadId,
                    latestDateReceived: s.latestDateReceived,
                    messageCount: s.messageCount,
                    unreadCount: max(0, s.unreadCount + threadDelta),
                    flaggedCount: s.flaggedCount,
                    latestSubject: s.latestSubject,
                    latestSenderDisplay: s.latestSenderDisplay,
                    latestMessageRowId: s.latestMessageRowId,
                    latestIsOutgoing: s.latestIsOutgoing
                )
            }
        }

        model.allUnreadCount = max(0, model.allUnreadCount + unreadCountDelta)
        model.updateDockBadge()

        if let db = model.indexDB, !flippedRowIds.isEmpty {
            persistIsRead(rowids: flippedRowIds, isRead: isRead, db: db)
        }
    }

    /// One-transaction batch write of `is_read`. Failures show up as a
    /// `bulkActionError` alert — without surfacing, the optimistic in-memory
    /// flip would silently revert on the next sync, leaving the user with
    /// no idea what happened.
    private func persistIsRead(rowids: [Int], isRead: Bool, db: IndexDB) {
        Task { [weak model] in
            do {
                try await db.setIsReadBatch(rowids: rowids, isRead: isRead)
            } catch {
                Log.db.error("setIsReadBatch failed for \(rowids.count) rows: \(String(describing: error), privacy: .public)")
                await MainActor.run {
                    model?.bulkActionError = "Couldn't update read status in the local index — your change may not stick after the next sync. (\(error.localizedDescription))"
                }
            }
        }
    }
}
