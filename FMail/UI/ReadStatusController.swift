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

    /// Mark every multi-selected search result.
    func markSelectedSearchResults(asRead isRead: Bool) {
        let messages = model.searchResults.filter {
            model.selectedSearchResultIds.contains($0.rowId)
        }
        guard !messages.isEmpty else { return }
        setReadStatus(messages: messages, isRead: isRead)
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

        model.skipSyncsUntil = Date().addingTimeInterval(120)

        Task.detached { [weak model] in
            let result = await MailScripter.setReadStatusBatch(entries, isRead: isRead)
            await MainActor.run {
                model?.skipSyncsUntil = Date().addingTimeInterval(180)
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

    /// View scope for currently-selected mailbox / All Mailboxes view.
    /// Hides drafts (and trash/junk in All Mailboxes) unless the user is
    /// browsing one of those mailboxes directly.
    private func currentViewScope() -> IndexDB.ThreadViewScope {
        if model.isAllMailboxesScope {
            return .excludeAllSystem
        }
        if let kind = model.selectedMailbox?.kind, ["drafts", "trash", "junk"].contains(kind) {
            return .includeAll
        }
        return .excludeDrafts
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
            Task {
                for id in ids {
                    try? await db.setIsRead(rowid: id, isRead: isRead)
                }
            }
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
            let ids = flippedRowIds
            Task {
                for id in ids {
                    try? await db.setIsRead(rowid: id, isRead: isRead)
                }
            }
        }
    }
}
