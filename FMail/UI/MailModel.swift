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

    /// Display order for the thread list (View → Sort Mails by). Persisted in
    /// UserDefaults; `didSet` re-sorts the currently visible list so the
    /// menu change is instant — no DB round-trip needed because the visible
    /// set (latest 500 threads) is the same in either direction.
    var messageSortOrder: MessageSortOrder = MessageSortOrder.loadFromDefaults(scope: .mail) {
        didSet {
            guard oldValue != messageSortOrder else { return }
            messageSortOrder.persist(scope: .mail)
            threadsForSelectedMailbox = sortThreads(threadsForSelectedMailbox)
        }
    }

    /// Display order for messages within the currently open thread
    /// (View → Sort Conversations by). Default `.oldest` keeps the original
    /// message at the top.
    var conversationSortOrder: MessageSortOrder = MessageSortOrder.loadFromDefaults(scope: .conversation) {
        didSet {
            guard oldValue != conversationSortOrder else { return }
            conversationSortOrder.persist(scope: .conversation)
            messagesInSelectedThread = sortConversation(messagesInSelectedThread)
        }
    }

    // Search
    var searchQuery: String = ""
    var searchInterpretation: String = ""
    var searchResults: [MessageHeader] = []
    var isSearching: Bool = false
    var searchError: String?
    /// The search result the user clicked most recently. Bound to the
    /// SearchResultsView's List selection so the row stays highlighted
    /// (lighter shade once focus moves to the reader).
    var selectedSearchResultId: Int?

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
        // Plain `Task { ... }` from this @MainActor function inherits MainActor
        // isolation. The await on `runUntilDone` releases the main actor while
        // the BodyIndexer actor does its work; capturing `[weak self]` once at
        // the top is enough — no further isolation hops to send `self` across.
        bodyIndexerTask = Task { [weak self] in
            await bodyIndexer.runUntilDone(mailboxes: snapshotMailboxes) { snapshot in
                self?.bodyIndexProgress = snapshot
            }
            self?.bodyIndexerTask = nil
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
        selectedSearchResultId = nil
        isSearching = false
        searchError = nil
    }

    /// Open a specific message from search results in the reader. Keeps the
    /// search query visible so the user doesn't lose their filtered list.
    /// Also pre-loads the message's mailbox in the background so that when
    /// the user does clear the search, they land in the right place.
    func openFromSearch(_ message: MessageHeader) {
        guard let mb = mailboxes.first(where: { $0.rowId == message.mailboxRowId }),
              let db = indexDB else { return }

        // Persist the row selection in the search list so the highlight stays.
        selectedSearchResultId = message.rowId

        Task { @MainActor in
            guard let threadId = try? await db.threadId(forMessage: message.rowId) else { return }
            let viewScope: IndexDB.ThreadViewScope = ["drafts", "trash", "junk"].contains(mb.kind) ? .includeAll : .excludeDrafts
            let msgs = (try? await db.loadThreadMessages(threadId: threadId, scope: viewScope)) ?? []

            // Update reader state without clearing the search list.
            selection = .mailbox(mb.rowId)
            selectedThreadId = threadId
            messagesInSelectedThread = sortConversation(msgs)
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
        selectedMessageId = nil
        messagesInSelectedThread = []
        bodyForSelectedMessage = nil
        bodyError = nil
        isLoadingThreadMessages = true
        Task { await loadMessagesForSelectedThread(autoSelectLatest: thread.latestMessageRowId) }
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
                threadsForSelectedMailbox = sortThreads(threads)
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
                messagesInSelectedThread = sortConversation(msgs)
                isLoadingThreadMessages = false
                // Fallback uses max-by-date rather than `msgs.last` because the
                // visible array order now depends on the user's
                // conversationSortOrder — `last` is no longer always "newest".
                let fallback = msgs.max { lhs, rhs in
                    (lhs.dateReceived ?? lhs.dateSent ?? .distantPast)
                        < (rhs.dateReceived ?? rhs.dateSent ?? .distantPast)
                }
                if let latest = msgs.first(where: { $0.rowId == autoSelectLatest }) ?? fallback {
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
        guard let rfcId = message.rfcMessageId, !rfcId.isEmpty else {
            bodyError = "This message has no Message-ID header — can't ask Mail.app to mark it."
            return
        }

        // Look up the canonical account+mailbox for a targeted AppleScript.
        let mb = mailboxes.first { $0.rowId == message.mailboxRowId }
        let acct = mb.flatMap { mb in accounts.first { $0.uuid == mb.accountUUID } }
        let accountEmail = acct?.emailAddress
        let mailboxPath = mb?.pathComponents

        // Apply UI changes synchronously, FIRST — instant feedback even if
        // Mail.app takes a moment to process the AppleScript.
        skipSyncsUntil = Date().addingTimeInterval(30)
        applyOptimisticReadFlag(messageRowId: message.rowId, isRead: isRead)

        // Run osascript in a subprocess (background queue inside the
        // function). FMail's main thread is free; Mail.app blocks briefly
        // while it scans the targeted mailbox, but we don't.
        Task.detached {
            let result = await MailScripter.setReadStatus(
                rfcMessageId: rfcId,
                isRead: isRead,
                accountEmail: accountEmail,
                mailboxPathComponents: mailboxPath
            )
            // Surface only failures the user can act on (permission issues,
            // unknown message). Success = silent.
            switch result {
            case .ok:
                break
            case .notFound:
                await MainActor.run { [weak self] in
                    self?.bodyError = "Mail.app couldn't find this message — its body may not be downloaded yet (try Open in Mail.app first)."
                }
            case .failed(let msg):
                await MainActor.run { [weak self] in
                    self?.bodyError = "Mark-as-read failed: \(msg)"
                }
            }
        }
    }

    private func applyOptimisticReadFlag(messageRowId: Int, isRead: Bool) {
        // Find the previous state of the message to compute a delta.
        // If we don't have it in any of the in-memory lists, fall back to
        // assuming a change happened so callers get immediate feedback.
        var previousIsRead: Bool? = nil
        var messageMailboxRowId: Int? = nil

        // Update the in-thread message list.
        if let idx = messagesInSelectedThread.firstIndex(where: { $0.rowId == messageRowId }) {
            let m = messagesInSelectedThread[idx]
            previousIsRead = m.isRead
            messageMailboxRowId = m.mailboxRowId
            messagesInSelectedThread[idx] = MessageHeader(
                rowId: m.rowId, mailboxRowId: m.mailboxRowId, subject: m.subject,
                senderAddress: m.senderAddress, senderDisplay: m.senderDisplay,
                dateSent: m.dateSent, dateReceived: m.dateReceived,
                isRead: isRead, isFlagged: m.isFlagged, rfcMessageId: m.rfcMessageId
            )
        }
        // Update the search results list.
        if let idx = searchResults.firstIndex(where: { $0.rowId == messageRowId }) {
            let m = searchResults[idx]
            if previousIsRead == nil { previousIsRead = m.isRead }
            if messageMailboxRowId == nil { messageMailboxRowId = m.mailboxRowId }
            searchResults[idx] = MessageHeader(
                rowId: m.rowId, mailboxRowId: m.mailboxRowId, subject: m.subject,
                senderAddress: m.senderAddress, senderDisplay: m.senderDisplay,
                dateSent: m.dateSent, dateReceived: m.dateReceived,
                isRead: isRead, isFlagged: m.isFlagged, rfcMessageId: m.rfcMessageId
            )
        }

        // Compute delta for counters. If the state didn't actually change,
        // skip everything below.
        let stateChanged = (previousIsRead != isRead) && (previousIsRead != nil)
        guard stateChanged else {
            // Persist anyway in case our memory is stale relative to the DB.
            if let db = indexDB {
                Task { try? await db.setIsRead(rowid: messageRowId, isRead: isRead) }
            }
            return
        }
        let unreadDelta = isRead ? -1 : 1

        // Update the currently-displayed thread summary's unreadCount.
        if let tid = selectedThreadId,
           let idx = threadsForSelectedMailbox.firstIndex(where: { $0.threadId == tid }) {
            let s = threadsForSelectedMailbox[idx]
            let newCount = max(0, s.unreadCount + unreadDelta)
            threadsForSelectedMailbox[idx] = ThreadSummary(
                threadId: s.threadId,
                latestDateReceived: s.latestDateReceived,
                messageCount: s.messageCount,
                unreadCount: newCount,
                flaggedCount: s.flaggedCount,
                latestSubject: s.latestSubject,
                latestSenderDisplay: s.latestSenderDisplay,
                latestMessageRowId: s.latestMessageRowId
            )
        }

        // Update the message's mailbox unread count in the sidebar.
        // (Best-effort: only the canonical mailbox; Gmail label-mailbox
        // counts may be off by one until the next real sync.)
        if let mboxId = messageMailboxRowId,
           let idx = mailboxes.firstIndex(where: { $0.rowId == mboxId }) {
            let mb = mailboxes[idx]
            let newUnread = max(0, mb.unreadCount + unreadDelta)
            mailboxes[idx] = Mailbox(
                rowId: mb.rowId, accountUUID: mb.accountUUID,
                pathComponents: mb.pathComponents,
                totalCount: mb.totalCount, unreadCount: newUnread,
                hidden: mb.hidden, kind: mb.kind
            )
        }

        // Update the global "All Mailboxes" badge + Dock tile.
        allUnreadCount = max(0, allUnreadCount + unreadDelta)
        updateDockBadge()

        // Persist to our DB so it survives until the next sync confirms.
        if let db = indexDB {
            Task { try? await db.setIsRead(rowid: messageRowId, isRead: isRead) }
        }
    }
}

enum SidebarSelection: Hashable, Sendable {
    case allMailboxes
    case mailbox(Int)
}

enum MessageSortOrder: String, CaseIterable, Sendable, Hashable {
    case newest
    case oldest

    /// One persisted preference per axis. Defaults are deliberately different:
    /// the mail (thread) list defaults newest-first (most-recent activity at
    /// top); conversation messages default oldest-first (the original mail at
    /// the top, replies below) — that's how Apple Mail and most clients show
    /// a thread by default.
    enum Scope: String {
        case mail = "messageSortOrder"
        case conversation = "conversationSortOrder"

        var defaultValue: MessageSortOrder {
            switch self {
            case .mail: return .newest
            case .conversation: return .oldest
            }
        }
    }

    static func loadFromDefaults(scope: Scope) -> MessageSortOrder {
        let raw = UserDefaults.standard.string(forKey: scope.rawValue) ?? ""
        return MessageSortOrder(rawValue: raw) ?? scope.defaultValue
    }

    func persist(scope: Scope) {
        UserDefaults.standard.set(rawValue, forKey: scope.rawValue)
    }
}

extension MailModel {
    fileprivate func sortThreads(_ threads: [ThreadSummary]) -> [ThreadSummary] {
        threads.sorted { lhs, rhs in
            let l = lhs.latestDateReceived ?? .distantPast
            let r = rhs.latestDateReceived ?? .distantPast
            return messageSortOrder == .newest ? l > r : l < r
        }
    }

    fileprivate func sortConversation(_ msgs: [MessageHeader]) -> [MessageHeader] {
        msgs.sorted { lhs, rhs in
            let l = lhs.dateReceived ?? lhs.dateSent ?? .distantPast
            let r = rhs.dateReceived ?? rhs.dateSent ?? .distantPast
            return conversationSortOrder == .newest ? l > r : l < r
        }
    }
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
