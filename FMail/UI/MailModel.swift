import AppKit
import Foundation
import SwiftUI

@MainActor
@Observable
final class MailModel {
    enum LoadState: Equatable {
        case idle
        case bootstrapping
        case indexing
        case ready
        case fdaDenied
        case noMailData
        case failed(String)
    }

    var loadState: LoadState = .idle
    var indexProgress: IndexProgress = .idle
    var bodyIndexProgress: BodyIndexProgress = .idle
    var accounts: [MailAccount] = []
    var mailboxes: [Mailbox] = []
    /// Either the synthetic "All Mailboxes" view or a specific mailbox.
    var selection: SidebarSelection?
    /// Cached count of unread, non-draft messages across the entire index.
    /// Refreshed by `refreshFromIndexDB`.
    var allUnreadCount: Int = 0
    var selectedThreadId: Int?
    /// Set of thread IDs currently selected in the thread list. Drives the
    /// bulk-action bar (visible when count > 1) and row highlighting.
    /// `selectedThreadId` (singular) is the one shown in the reader; for
    /// single-selection both are aligned, for multi-selection only the
    /// first/most-recent click drives the reader.
    var selectedThreadIds: Set<Int> = []
    var selectedMessageId: Int?
    var threadsForSelectedMailbox: [ThreadSummary] = []
    var messagesInSelectedThread: [MessageHeader] = []
    var isLoadingThreads = false
    var isLoadingThreadMessages = false
    var threadsError: String?
    var bodyForSelectedMessage: MessageBody?
    var isLoadingBody = false
    var bodyError: String?
    var showHidden = false

    // Search
    var searchQuery: String = ""
    var searchInterpretation: String = ""
    var searchResults: [MessageHeader] = []
    var isSearching: Bool = false
    var searchError: String?
    /// The search results the user has selected. Set semantics so the user
    /// can ⌘-click to multi-select for bulk Mark as Read / Unread. With
    /// exactly one item selected, the reader opens that message; with more
    /// selected, the bulk-action bar appears above the list.
    var selectedSearchResultIds: Set<Int> = []

    private var indexDB: IndexDB?
    private var bodyLoader: BodyLoader?
    private var indexer: Indexer?
    private var bodyIndexer: BodyIndexer?
    private var watcher: FileWatcher?
    private(set) var contactsService = ContactsService()
    private var syncInFlight = false
    private var syncRequestedWhileBusy = false
    /// When set in the future, FSEvents-triggered syncs are skipped until then.
    /// Used by our own write-backs (Mark as Read etc.) to suppress the
    /// follow-up sync that'd otherwise fire from Mail.app's `.emlx` flag-plist
    /// modification — we've already updated our index optimistically, so the
    /// re-mirror is wasted work.
    private var skipSyncsUntil: Date?
    private var searchTask: Task<Void, Never>?
    private var bodyIndexerTask: Task<Void, Never>?

    // Reply flow state
    var replyDraft: ReplyDraft?

    var selectedMailbox: Mailbox? {
        guard case .mailbox(let id) = selection else { return nil }
        return mailboxes.first { $0.rowId == id }
    }

    var isAllMailboxesScope: Bool {
        if case .allMailboxes = selection { return true }
        return false
    }

    var sidebarTitle: String {
        switch selection {
        case .allMailboxes: return "All Mailboxes"
        case .mailbox: return selectedMailbox?.displayName ?? ""
        case .none: return ""
        }
    }

    var selectedMessage: MessageHeader? {
        guard let id = selectedMessageId else { return nil }
        return messagesInSelectedThread.first { $0.rowId == id }
    }

    /// Mailboxes grouped by account, hiding by default unless `showHidden`.
    var mailboxesByAccount: [(MailAccount, [Mailbox])] {
        let grouped = Dictionary(grouping: mailboxes.filter { showHidden || !$0.hidden }) { $0.accountUUID }
        return accounts.compactMap { acc in
            guard let mbs = grouped[acc.uuid], !mbs.isEmpty else { return nil }
            let sorted = mbs.sorted { lhs, rhs in
                if lhs.displayName == "INBOX" && rhs.displayName != "INBOX" { return true }
                if rhs.displayName == "INBOX" && lhs.displayName != "INBOX" { return false }
                return lhs.pathComponents.joined(separator: "/") < rhs.pathComponents.joined(separator: "/")
            }
            return (acc, sorted)
        }
    }

    func boot() async {
        switch loadState {
        case .ready, .bootstrapping, .indexing: return
        default: break
        }

        loadState = .bootstrapping

        guard FullDiskAccess.isGrantedHeuristic() else {
            loadState = .fdaDenied
            return
        }
        guard let versionDir = MailStoreEnumerator.currentMailVersionDirectory() else {
            loadState = .noMailData
            return
        }
        let envelopePath = MailStoreEnumerator.envelopeIndexURL(in: versionDir).path
        guard FileManager.default.fileExists(atPath: envelopePath) else {
            loadState = .noMailData
            return
        }

        do {
            let dbPath = try IndexDB.defaultPath()
            let db = try await IndexDB(path: dbPath)
            self.indexDB = db
            let bodyLoader = BodyLoader(mailVersionDir: versionDir)
            self.bodyLoader = bodyLoader
            let indexer = Indexer(envelopePath: envelopePath, indexDB: db, mailVersionDir: versionDir)
            self.indexer = indexer
            self.bodyIndexer = BodyIndexer(indexDB: db, bodyLoader: bodyLoader)

            let lastSync = try await db.getMeta("last_full_sync_at")
            if lastSync == nil {
                // First run — full index.
                loadState = .indexing
                try await indexer.runFullSync { [weak self] snapshot in
                    self?.indexProgress = snapshot
                }
            }

            try await refreshFromIndexDB()
            loadState = .ready

            // Default selection on launch: the "All Mailboxes" view, so the
            // user lands on something useful instead of an empty middle pane.
            if selection == nil {
                selectAllMailboxes()
            }

            // Background: refresh sync to catch anything new since last run.
            Task.detached { [weak self] in
                guard let self else { return }
                await self.runIncrementalSync()
            }

            // Background: body content indexing for search.
            startBodyIndexer()

            // File watcher: trigger refresh on change.
            let watcher = FileWatcher(rootPath: versionDir.path) { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.runIncrementalSync()
                }
            }
            watcher.start()
            self.watcher = watcher
        } catch {
            loadState = .failed(String(describing: error))
        }
    }

    // MARK: — Body indexing

    func startBodyIndexer() {
        guard let bodyIndexer else { return }
        if bodyIndexerTask != nil { return }
        let snapshotMailboxes = mailboxes
        bodyIndexerTask = Task.detached { [weak self] in
            await bodyIndexer.runUntilDone(mailboxes: snapshotMailboxes) { snapshot in
                Task { @MainActor [weak self] in
                    self?.bodyIndexProgress = snapshot
                }
            }
            await MainActor.run { [weak self] in
                self?.bodyIndexerTask = nil
            }
        }
    }

    // MARK: — Search

    func updateSearch(_ query: String) {
        searchQuery = query
        searchTask?.cancel()
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            searchResults = []
            searchInterpretation = ""
            isSearching = false
            searchError = nil
            return
        }
        isSearching = true
        searchError = nil

        let ast = QueryParser.parse(query)
        let compiled = Evaluator.compile(ast)
        searchInterpretation = compiled.interpretation

        guard compiled.hasAnyConstraint, let db = indexDB else {
            searchResults = []
            isSearching = false
            return
        }

        searchTask = Task { [weak self] in
            do {
                let rows = try await db.search(compiled, limit: 200)
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.searchResults = rows
                    self.isSearching = false
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.searchError = String(describing: error)
                    self?.isSearching = false
                }
            }
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchQuery = ""
        searchInterpretation = ""
        searchResults = []
        selectedSearchResultIds = []
        isSearching = false
        searchError = nil
    }

    func markSelectedSearchResultsAsRead(_ isRead: Bool) {
        let messages = searchResults.filter { selectedSearchResultIds.contains($0.rowId) }
        guard !messages.isEmpty else { return }
        setReadStatusForMessages(messages, isRead: isRead)
    }

    /// Batch Mark as Read for many messages at once. One osascript call
    /// (grouped by mailbox), so Mail.app scans each mailbox once instead of
    /// once-per-message. Optimistic UI updates fire immediately for every
    /// message before osascript runs.
    func setReadStatusForMessages(_ messages: [MessageHeader], isRead: Bool) {
        // Single batched optimistic update — applies every visible counter
        // delta in one pass and commits each array (`searchResults`,
        // `messagesInSelectedThread`, `mailboxes`) with a single mutation,
        // which @Observable can reliably propagate to SwiftUI.
        applyOptimisticReadFlags(messageRowIds: messages.map(\.rowId), isRead: isRead)

        // Build batch entries. Prefer IMAP UID for AppleScript lookup
        // (Mail.app indexes by id) and fall back to RFC Message-ID otherwise.
        let entries: [MailScripter.BatchEntry] = messages.compactMap { msg in
            let mb = mailboxes.first { $0.rowId == msg.mailboxRowId }
            let acct = mb.flatMap { mb in accounts.first { $0.uuid == mb.accountUUID } }
            // `rowId` is Apple's Envelope Index ROWID — that's what
            // Mail.app's AppleScript `id` returns (NOT the IMAP UID).
            return MailScripter.BatchEntry(
                rfcMessageId: msg.rfcMessageId ?? "",
                appleRowId: msg.rowId,
                accountEmail: acct?.emailAddress,
                mailboxPathComponents: mb?.pathComponents
            )
        }
        guard !entries.isEmpty else { return }

        // Suppress sync long enough for the batch to land — one batch can
        // take a while if it spans multiple Gmail accounts.
        skipSyncsUntil = Date().addingTimeInterval(120)

        Task.detached { [weak self] in
            let result = await MailScripter.setReadStatusBatch(entries, isRead: isRead)
            // Re-extend skip-syncs after AppleScript completes — same
            // reason as the thread bulk path: brute-walk + IMAP commit
            // can take minutes, and we don't want sync to overwrite the
            // optimistic flag with stale Envelope Index data.
            await MainActor.run {
                self?.skipSyncsUntil = Date().addingTimeInterval(180)
            }
            switch result {
            case .ok:
                break
            case .notFound:
                await MainActor.run {
                    self?.bodyError = "Mail.app couldn't find some of the selected messages — they may not have been downloaded yet, or Mail.app's mailbox layout doesn't match (try Tools → Diagnose Mail.app structure)."
                }
            case .failed(let msg):
                await MainActor.run {
                    self?.bodyError = "Bulk Mark as Read failed: \(msg)"
                }
            }
        }
    }

    /// Open a specific message from search results in the reader. Keeps the
    /// search query visible so the user doesn't lose their filtered list.
    /// Also pre-loads the message's mailbox in the background so that when
    /// the user does clear the search, they land in the right place.
    func openFromSearch(_ message: MessageHeader) {
        guard let mb = mailboxes.first(where: { $0.rowId == message.mailboxRowId }),
              let db = indexDB else { return }

        // Persist the row selection in the search list so the highlight stays.
        selectedSearchResultIds = [message.rowId]

        Task { @MainActor in
            guard let threadId = try? await db.threadId(forMessage: message.rowId) else { return }
            let viewScope: IndexDB.ThreadViewScope = ["drafts", "trash", "junk"].contains(mb.kind) ? .includeAll : .excludeDrafts
            let msgs = (try? await db.loadThreadMessages(threadId: threadId, scope: viewScope)) ?? []

            // Update reader state without clearing the search list.
            selection = .mailbox(mb.rowId)
            selectedThreadId = threadId
            messagesInSelectedThread = msgs
            isLoadingThreadMessages = false
            if let m = msgs.first(where: { $0.rowId == message.rowId }) {
                selectMessage(m)
            }

            // Background: warm the mailbox's thread list for when search clears.
            Task { await loadThreadsForSelected() }
        }
    }

    func runIncrementalSync() async {
        guard let indexer else { return }
        if let until = skipSyncsUntil, until > Date() {
            // Our own writeback fired this. Skip — we've already updated locally.
            return
        }
        skipSyncsUntil = nil
        if syncInFlight {
            syncRequestedWhileBusy = true
            return
        }
        syncInFlight = true
        defer { syncInFlight = false }

        // Pause body indexing during sync so writes don't race the indexer's
        // bulk transactions over the same SQLite connection.
        await bodyIndexer?.cancel()
        bodyIndexerTask = nil

        do {
            try await indexer.runFullSync { [weak self] snapshot in
                self?.indexProgress = snapshot
            }
            try await refreshFromIndexDB()
            // After the metadata pass, ask Mail.app to fetch bodies for any
            // unread messages whose .emlx we don't have yet — fire-and-forget,
            // body indexer picks them up via FSEventStream once Mail.app
            // writes them to disk.
            await fetchMissingUnreadBodies()
            indexProgress = .idle
        } catch {
            print("Incremental sync failed: \(error)")
        }

        // Restart body indexing now that sync is done.
        startBodyIndexer()

        if syncRequestedWhileBusy {
            syncRequestedWhileBusy = false
            Task { await self.runIncrementalSync() }
        }
    }

    private func refreshFromIndexDB() async throws {
        guard let db = indexDB else { return }
        let mboxes = try await db.loadMailboxes()
        let accts = try await db.loadAccounts()
        // Ensure mailboxes have an account row (in case of out-of-order load).
        let acctMap = Dictionary(uniqueKeysWithValues: accts.map { ($0.uuid, $0) })
        let allUUIDs = Set(mboxes.map(\.accountUUID))
        _ = acctMap
        let finalAccounts = allUUIDs.sorted().map { uuid in
            acctMap[uuid] ?? MailAccount(uuid: uuid, displayName: "Account \(uuid.prefix(8))", emailAddress: nil)
        }
        self.mailboxes = mboxes
        self.accounts = finalAccounts
        self.allUnreadCount = (try? await db.countAllUnreadExcludingDrafts()) ?? 0
        updateDockBadge()

        // Refresh threads if the current scope still resolves.
        switch selection {
        case .allMailboxes:
            await loadThreadsForSelected()
        case .mailbox(let id):
            if mboxes.contains(where: { $0.rowId == id }) {
                await loadThreadsForSelected()
            }
        case .none:
            break
        }
    }

    /// After each sync, ask Mail.app to fetch bodies for any new unread
    /// messages we don't have yet. Fires the AppleScript and returns —
    /// Mail.app does the IMAP grunt work in the background, FSEventStream
    /// picks up the resulting `.emlx` files, BodyIndexer indexes them, and
    /// the user sees fully-rendered bodies as they appear in the list.
    /// Limit kept small so a backfill doesn't lock Mail.app's UI.
    private func fetchMissingUnreadBodies() async {
        guard let db = indexDB else { return }
        guard let candidates = try? await db.fetchUnreadMissingBody(limit: 10),
              !candidates.isEmpty else { return }

        let entries: [MailScripter.BatchEntry] = candidates.compactMap { c -> MailScripter.BatchEntry? in
            guard let mb = mailboxes.first(where: { $0.rowId == c.mailboxRowId }),
                  let acct = accounts.first(where: { $0.uuid == mb.accountUUID }),
                  let email = acct.emailAddress
            else { return nil }
            return MailScripter.BatchEntry(
                rfcMessageId: c.rfcMessageId ?? "",
                appleRowId: c.rowid,
                accountEmail: email,
                mailboxPathComponents: mb.pathComponents
            )
        }
        guard !entries.isEmpty else { return }

        Task.detached {
            await MailScripter.fetchBodies(entries)
        }
    }

    /// Pushes `allUnreadCount` to the Dock tile. Empty string clears the badge.
    /// Numbers ≥ 1000 are shown as "999+" to keep the badge legible.
    private func updateDockBadge() {
        let label: String
        if allUnreadCount <= 0 {
            label = ""
        } else if allUnreadCount > 999 {
            label = "999+"
        } else {
            label = "\(allUnreadCount)"
        }
        NSApplication.shared.dockTile.badgeLabel = label.isEmpty ? nil : label
    }

    func selectAllMailboxes() {
        selection = .allMailboxes
        threadsForSelectedMailbox = []
        selectedThreadId = nil
        selectedThreadIds = []
        selectedMessageId = nil
        messagesInSelectedThread = []
        bodyForSelectedMessage = nil
        bodyError = nil
        threadsError = nil
        isLoadingThreads = true
        Task { await loadThreadsForSelected() }
    }

    func selectMailbox(_ mailbox: Mailbox) {
        selection = .mailbox(mailbox.rowId)
        threadsForSelectedMailbox = []
        selectedThreadId = nil
        selectedThreadIds = []
        selectedMessageId = nil
        messagesInSelectedThread = []
        bodyForSelectedMessage = nil
        bodyError = nil
        threadsError = nil
        isLoadingThreads = true
        Task { await loadThreadsForSelected() }
    }

    func selectThread(_ thread: ThreadSummary) {
        selectedThreadId = thread.threadId
        selectedThreadIds = [thread.threadId]
        selectedMessageId = nil
        messagesInSelectedThread = []
        bodyForSelectedMessage = nil
        bodyError = nil
        isLoadingThreadMessages = true
        Task { await loadMessagesForSelectedThread(autoSelectLatest: thread.latestMessageRowId) }
    }

    func toggleThreadSelection(_ thread: ThreadSummary) {
        if selectedThreadIds.contains(thread.threadId) {
            selectedThreadIds.remove(thread.threadId)
        } else {
            selectedThreadIds.insert(thread.threadId)
        }
    }

    func selectThreadRange(anchorThreadId: Int, to clickedThreadId: Int) {
        let threads = threadsForSelectedMailbox
        guard let anchorIdx = threads.firstIndex(where: { $0.threadId == anchorThreadId }),
              let thisIdx = threads.firstIndex(where: { $0.threadId == clickedThreadId })
        else { return }
        let range = anchorIdx <= thisIdx ? anchorIdx...thisIdx : thisIdx...anchorIdx
        for i in range {
            selectedThreadIds.insert(threads[i].threadId)
        }
    }

    /// Mark every message in every currently-selected thread as read/unread.
    /// Honors the active scope (e.g. excludes drafts/trash/junk in
    /// All Mailboxes view) so we never accidentally flip a junk-folder
    /// message just because it shares a thread with a real one.
    ///
    /// The optimistic update is *thread-aware*: each selected thread's
    /// `ThreadSummary.unreadCount` is decremented by the actual count of
    /// flipped messages in that thread. Without this, threads other than
    /// the currently-open one wouldn't visually update because their
    /// messages aren't loaded into `messagesInSelectedThread` and the
    /// generic per-message path can't find them.
    func markSelectedThreadsAsRead(_ isRead: Bool) async {
        guard let db = indexDB else { return }
        let viewScope: IndexDB.ThreadViewScope
        if isAllMailboxesScope {
            viewScope = .excludeAllSystem
        } else if let kind = selectedMailbox?.kind, ["drafts", "trash", "junk"].contains(kind) {
            viewScope = .includeAll
        } else {
            viewScope = .excludeDrafts
        }
        var perThread: [(threadId: Int, messages: [MessageHeader])] = []
        for tid in selectedThreadIds {
            if let msgs = try? await db.loadThreadMessages(threadId: tid, scope: viewScope) {
                let toFlip = msgs.filter { $0.isRead != isRead }
                if !toFlip.isEmpty { perThread.append((tid, toFlip)) }
            }
        }
        guard !perThread.isEmpty else { return }

        applyOptimisticThreadBulkRead(perThread: perThread, isRead: isRead)

        // The generic AppleScript path is reused.
        let allMessages = perThread.flatMap { $0.messages }
        let entries: [MailScripter.BatchEntry] = allMessages.compactMap { msg in
            let mb = mailboxes.first { $0.rowId == msg.mailboxRowId }
            let acct = mb.flatMap { mb in accounts.first { $0.uuid == mb.accountUUID } }
            return MailScripter.BatchEntry(
                rfcMessageId: msg.rfcMessageId ?? "",
                appleRowId: msg.rowId,
                accountEmail: acct?.emailAddress,
                mailboxPathComponents: mb?.pathComponents
            )
        }
        guard !entries.isEmpty else { return }

        skipSyncsUntil = Date().addingTimeInterval(120)

        Task.detached { [weak self] in
            let result = await MailScripter.setReadStatusBatch(entries, isRead: isRead)
            // Extend the sync-skip past the AppleScript completion. The
            // brute-walk fallback can take minutes, and Mail.app may need
            // additional time after `set read status` to commit to its
            // Envelope Index. Without this, sync runs before Mail.app has
            // persisted, sees stale unread, and overwrites our optimistic
            // flag with `excluded.is_read` in upsertMessages.
            await MainActor.run {
                self?.skipSyncsUntil = Date().addingTimeInterval(180)
            }
            switch result {
            case .ok:
                break
            case .notFound:
                await MainActor.run {
                    self?.bodyError = "Mail.app couldn't find some of the selected messages — they may not have been downloaded yet, or Mail.app's mailbox layout doesn't match (try Tools → Diagnose Mail.app structure)."
                }
            case .failed(let msg):
                await MainActor.run {
                    self?.bodyError = "Bulk Mark as Read failed: \(msg)"
                }
            }
        }
    }

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
        var newThreads = threadsForSelectedMailbox
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
                    latestMessageRowId: s.latestMessageRowId
                )
            }
        }
        threadsForSelectedMailbox = newThreads

        // Aggregate per-mailbox deltas, update sidebar counts.
        let allMessages = perThread.flatMap { $0.messages }
        var mailboxDeltas: [Int: Int] = [:]
        for msg in allMessages {
            mailboxDeltas[msg.mailboxRowId, default: 0] += perMessageDelta
        }
        if !mailboxDeltas.isEmpty {
            var newMailboxes = mailboxes
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
            mailboxes = newMailboxes
        }

        // Update messagesInSelectedThread for any flipped message that is
        // in the open thread (so the reader's per-message dot updates too).
        let flippedRowIds = Set(allMessages.map(\.rowId))
        var newMessagesInThread = messagesInSelectedThread
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
        if anyChangedInThread { messagesInSelectedThread = newMessagesInThread }

        // Same for searchResults if any of these messages are showing there.
        var newSearchResults = searchResults
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
        if anyChangedInSearch { searchResults = newSearchResults }

        // Global counter + dock badge.
        let totalDelta = allMessages.count * perMessageDelta
        allUnreadCount = max(0, allUnreadCount + totalDelta)
        updateDockBadge()

        // Persist to DB.
        if let db = indexDB {
            let ids = allMessages.map(\.rowId)
            Task {
                for id in ids {
                    try? await db.setIsRead(rowid: id, isRead: isRead)
                }
            }
        }
    }

    func selectMessage(_ message: MessageHeader) {
        selectedMessageId = message.rowId
        bodyForSelectedMessage = nil
        bodyError = nil
        isLoadingBody = true
        Task { await loadBodyForSelected() }
    }

    private func loadThreadsForSelected() async {
        guard let db = indexDB else {
            isLoadingThreads = false
            return
        }
        let scope = selection
        do {
            let threads: [ThreadSummary]
            switch scope {
            case .allMailboxes:
                threads = try await db.loadAllThreadSummaries(limit: 500)
            case .mailbox(let id):
                threads = try await db.loadThreadSummaries(mailboxRowId: id, limit: 500)
            case .none:
                isLoadingThreads = false
                return
            }
            // Only commit results if the user hasn't navigated away.
            if selection == scope {
                threadsForSelectedMailbox = threads
                isLoadingThreads = false
            }
        } catch {
            if selection == scope {
                threadsError = String(describing: error)
                isLoadingThreads = false
            }
        }
    }

    private func loadMessagesForSelectedThread(autoSelectLatest: Int) async {
        guard let tid = selectedThreadId, let db = indexDB else {
            isLoadingThreadMessages = false
            return
        }
        // Pick the right view scope:
        //  - All Mailboxes → hide drafts + trash + junk
        //  - Drafts/Trash/Junk mailbox → show everything including those
        //  - Other mailboxes → hide drafts (default)
        let viewScope: IndexDB.ThreadViewScope
        if isAllMailboxesScope {
            viewScope = .excludeAllSystem
        } else if let kind = selectedMailbox?.kind, ["drafts", "trash", "junk"].contains(kind) {
            viewScope = .includeAll
        } else {
            viewScope = .excludeDrafts
        }
        do {
            let msgs = try await db.loadThreadMessages(threadId: tid, scope: viewScope)
            if selectedThreadId == tid {
                messagesInSelectedThread = msgs
                isLoadingThreadMessages = false
                if let latest = msgs.first(where: { $0.rowId == autoSelectLatest }) ?? msgs.last {
                    selectMessage(latest)
                }
            }
        } catch {
            if selectedThreadId == tid {
                threadsError = String(describing: error)
                isLoadingThreadMessages = false
            }
        }
    }

    private func loadBodyForSelected() async {
        guard let message = selectedMessage,
              let bodyLoader else {
            isLoadingBody = false
            return
        }
        // Each message in a thread may live in its own mailbox (Gmail labels in
        // particular: same body filed under Inbox + Important + All Mail). Use
        // the message's own mailboxRowId, not the sidebar selection.
        guard let homeMailbox = mailboxes.first(where: { $0.rowId == message.mailboxRowId }) else {
            bodyError = "Could not find mailbox for message (rowid \(message.rowId), expected mailbox \(message.mailboxRowId))."
            isLoadingBody = false
            return
        }
        do {
            let body = try await bodyLoader.loadBody(messageRowId: message.rowId, mailbox: homeMailbox)
            if selectedMessageId == message.rowId {
                bodyForSelectedMessage = body
                isLoadingBody = false
                if body == nil {
                    let path = homeMailbox.pathComponents.joined(separator: "/")
                    bodyError = "No .emlx file on disk for message rowid \(message.rowId) in \(path). Mail.app may not have downloaded the body yet — open the message in Mail.app once and try again."
                }
            }
        } catch {
            if selectedMessageId == message.rowId {
                bodyError = String(describing: error)
                isLoadingBody = false
            }
        }
    }

    // MARK: — Reply / Compose

    func startReply(kind: ReplyKind, message: MessageHeader, body: MessageBody?) {
        Task { @MainActor in
            _ = try? await contactsService.ensureLoaded()
            let contact = await contactsService.contact(forAddress: message.senderAddress)

            var candidates: [String]
            if let contact, !contact.emailAddresses.isEmpty {
                candidates = contact.emailAddresses
                let lowerSender = message.senderAddress.lowercased()
                if !candidates.contains(lowerSender) {
                    candidates.insert(lowerSender, at: 0)
                }
            } else {
                candidates = [message.senderAddress]
            }

            var preferred = message.senderAddress
            var blocked: Set<String> = []
            if let contact, let db = indexDB,
               let prefs = try? await db.loadContactPrefs(contactId: contact.id) {
                blocked = prefs.blockedAddresses
                if let p = prefs.preferredAddress, !blocked.contains(p.lowercased()) {
                    preferred = p
                }
            }
            let visible = candidates.filter { !blocked.contains($0.lowercased()) }
            let suggestedTo = visible.contains(where: { $0.lowercased() == preferred.lowercased() })
                ? preferred
                : (visible.first ?? message.senderAddress)

            // Resolve our account via the message's mailbox.
            let acctUUID = mailboxes.first(where: { $0.rowId == message.mailboxRowId })?.accountUUID
            let ourAddress = acctUUID.flatMap { uuid in
                accounts.first(where: { $0.uuid == uuid })?.emailAddress
            }

            replyDraft = ReplyDraft(
                kind: kind,
                originalMessage: message,
                originalBody: body,
                resolvedContact: contact,
                candidateAddresses: visible.isEmpty ? [message.senderAddress] : visible,
                blockedAddresses: blocked,
                suggestedToAddress: suggestedTo,
                ourAddress: ourAddress
            )
        }
    }

    func cancelReply() {
        replyDraft = nil
    }

    func sendReply(toAddress: String, makePreferred: Bool, blockOriginal: Bool) {
        guard let draft = replyDraft else { return }
        Task { @MainActor in
            if let contact = draft.resolvedContact, let db = indexDB {
                if makePreferred {
                    try? await db.setPreferredAddress(contactId: contact.id, address: toAddress)
                }
                if blockOriginal,
                   draft.originalMessage.senderAddress.lowercased() != toAddress.lowercased() {
                    try? await db.addBlockedAddress(contactId: contact.id, address: draft.originalMessage.senderAddress)
                }
            }

            let req = ReplyBuilder.build(
                kind: draft.kind,
                message: draft.originalMessage,
                body: draft.originalBody,
                ourAddress: draft.ourAddress,
                toAddressOverride: toAddress
            )
            _ = MailComposer.handOff(req)
            replyDraft = nil
        }
    }

    func startNewMail() {
        let req = ComposeRequest(to: [], cc: [], subject: "", body: "", inReplyTo: nil, references: [])
        _ = MailComposer.handOff(req)
    }

    // MARK: — Read-status writeback (AppleScript → Mail.app)

    /// Optimistic-first read-status toggle. We:
    ///   1. Apply the change to our own DB + every visible counter immediately
    ///      so the UI is instant.
    ///   2. Suppress the FSEvent-triggered sync that'd fire when Mail.app
    ///      writes back to the `.emlx` flag plist (we already know what the
    ///      result will be).
    ///   3. Fire the AppleScript at Mail.app in the background, scoped to the
    ///      message's canonical account + mailbox so Mail.app only scans that
    ///      one mailbox. Wrapped in `ignoring application responses` so neither
    ///      FMail nor the user's interaction with Mail.app gets blocked.
    /// The next real sync (after the suppression window) reconciles in case
    /// Mail.app couldn't apply the change.
    func setReadStatus(_ message: MessageHeader, isRead: Bool) {
        // Delegate to the batch path so the single-message flow gets the
        // same multi-mailbox-variant + brute-walk fallback + longer
        // sync-skip window. Cheaper to maintain one code path.
        setReadStatusForMessages([message], isRead: isRead)
    }

    /// Single-message convenience that delegates to the batch path.
    private func applyOptimisticReadFlag(messageRowId: Int, isRead: Bool) {
        applyOptimisticReadFlags(messageRowIds: [messageRowId], isRead: isRead)
    }

    /// Batch optimistic flip. Applies *all* changes to each array
    /// (`searchResults`, `messagesInSelectedThread`, `mailboxes`,
    /// `threadsForSelectedMailbox`) with a single assignment per array, so
    /// SwiftUI sees one observable mutation per array and reliably re-renders
    /// every affected row in one pass. Counters (mailbox unread, thread
    /// unread, allUnreadCount) are aggregated across the batch.
    private func applyOptimisticReadFlags(messageRowIds: [Int], isRead: Bool) {
        guard !messageRowIds.isEmpty else { return }

        // Working copies — mutate locally, commit at the end.
        var newSearchResults = searchResults
        var newMessagesInThread = messagesInSelectedThread

        var unreadCountDelta = 0
        var mailboxDeltas: [Int: Int] = [:]   // mailbox rowId → unread delta
        var flippedRowIds: [Int] = []         // ids whose state actually changed

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

            // Aggregate counter deltas only when the state actually changed.
            if let prev = prevIsRead, prev != isRead {
                let d = isRead ? -1 : 1
                unreadCountDelta += d
                if let mid = mailboxRowId {
                    mailboxDeltas[mid, default: 0] += d
                }
                flippedRowIds.append(rowId)
            }
        }

        // Commit array changes — one mutation each.
        searchResults = newSearchResults
        messagesInSelectedThread = newMessagesInThread

        // Mailbox sidebar counts.
        if !mailboxDeltas.isEmpty {
            var newMailboxes = mailboxes
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
            mailboxes = newMailboxes
        }

        // Currently-displayed thread's summary — count how many flipped
        // messages belong to the open thread (may differ when the user is
        // bulk-marking from search results that span multiple threads).
        if !flippedRowIds.isEmpty,
           let tid = selectedThreadId,
           let summaryIdx = threadsForSelectedMailbox.firstIndex(where: { $0.threadId == tid }) {
            let inThreadCount = flippedRowIds.filter { id in
                newMessagesInThread.contains(where: { $0.rowId == id })
            }.count
            if inThreadCount > 0 {
                let threadDelta = inThreadCount * (isRead ? -1 : 1)
                let s = threadsForSelectedMailbox[summaryIdx]
                threadsForSelectedMailbox[summaryIdx] = ThreadSummary(
                    threadId: s.threadId,
                    latestDateReceived: s.latestDateReceived,
                    messageCount: s.messageCount,
                    unreadCount: max(0, s.unreadCount + threadDelta),
                    flaggedCount: s.flaggedCount,
                    latestSubject: s.latestSubject,
                    latestSenderDisplay: s.latestSenderDisplay,
                    latestMessageRowId: s.latestMessageRowId
                )
            }
        }

        // Global counter + dock badge.
        allUnreadCount = max(0, allUnreadCount + unreadCountDelta)
        updateDockBadge()

        // Persist all flipped rows to our DB so the change survives until
        // the next sync confirms.
        if let db = indexDB, !flippedRowIds.isEmpty {
            let ids = flippedRowIds
            Task {
                for id in ids {
                    try? await db.setIsRead(rowid: id, isRead: isRead)
                }
            }
        }
    }
}

enum SidebarSelection: Hashable, Sendable {
    case allMailboxes
    case mailbox(Int)
}

struct ReplyDraft: Equatable, Sendable {
    let kind: ReplyKind
    let originalMessage: MessageHeader
    let originalBody: MessageBody?
    let resolvedContact: ContactInfo?
    let candidateAddresses: [String]
    let blockedAddresses: Set<String>
    let suggestedToAddress: String
    let ourAddress: String?
}
