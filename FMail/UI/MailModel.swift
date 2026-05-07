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
    /// Error from loading the *currently selected* message's body. Shown inline
    /// in the reader. Distinct from `bulkActionError` so a bulk Mark-as-Read
    /// failure doesn't masquerade as a body-load failure.
    var bodyError: String?
    /// Error from a bulk action (Mark Read/Unread across multiple messages).
    /// Surfaced as an alert in AppShell. Cleared on dismiss.
    var bulkActionError: String?
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

    /// Visible to ReadStatusController (which mutates DB rows on optimistic
    /// flips) and other in-module collaborators. External callers should
    /// not reach into the index directly.
    var indexDB: IndexDB?
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
    /// re-mirror is wasted work. Mutated by ReadStatusController.
    var skipSyncsUntil: Date?

    /// Owns Mark Read / Unread for messages, threads, and search results.
    /// `@ObservationIgnored` keeps it out of @Observable's tracking so we
    /// can use `lazy` (the controller captures `self`, so the value can't
    /// be created until self is fully initialized).
    @ObservationIgnored
    private(set) lazy var readStatus = ReadStatusController(model: self)
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
                let rows = try await db.search(compiled, limit: 600)
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

    /// Bulk-mark from the search results selection. Forwards to
    /// `ReadStatusController` which owns the optimistic-flip + AppleScript
    /// dispatch.
    func markSelectedSearchResultsAsRead(_ isRead: Bool) {
        readStatus.markSelectedSearchResults(asRead: isRead)
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
            Log.sync.error("Incremental sync failed: \(String(describing: error), privacy: .public)")
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

    /// After each sync, ask Mail.app to fetch bodies for ALL unread
    /// messages we don't have on disk yet. Fires the AppleScript and
    /// returns — Mail.app does the IMAP grunt work in the background,
    /// FSEventStream picks up the resulting `.emlx` files, BodyIndexer
    /// indexes them, and the user sees fully-rendered bodies as they
    /// appear in the list. No limit: a fresh-install or post-vacation
    /// backlog of N messages costs N/5 chunks × ~5s each in Mail.app
    /// time (background — FMail's UI stays responsive).
    private func fetchMissingUnreadBodies() async {
        guard let db = indexDB else { return }
        guard let candidates = try? await db.fetchUnreadMissingBody(limit: nil),
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
    /// Internal so ReadStatusController can call it after optimistic flips.
    func updateDockBadge() {
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
        select(.allMailboxes)
    }

    func selectMailbox(_ mailbox: Mailbox) {
        select(.mailbox(mailbox.rowId))
    }

    /// Unified sidebar setter. Switches scope, clears reader/thread state,
    /// and kicks off a thread-list load. Silently no-ops on a `.mailbox(id)`
    /// for a mailbox that's not currently in `mailboxes` — guards against a
    /// stale id (deleted mailbox, persisted-then-restored selection) putting
    /// the UI into a "selected something that doesn't exist" state.
    func select(_ newSelection: SidebarSelection) {
        if case .mailbox(let id) = newSelection,
           !mailboxes.contains(where: { $0.rowId == id }) {
            return
        }
        selection = newSelection
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

    /// Bulk-mark from the threads selection. Forwards to ReadStatusController.
    func markSelectedThreadsAsRead(_ isRead: Bool) async {
        await readStatus.markSelectedThreads(asRead: isRead)
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
                threads = try await db.loadAllThreadSummaries(limit: 600)
            case .mailbox(let id):
                threads = try await db.loadThreadSummaries(mailboxRowId: id, limit: 600)
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
            if selectedMessageId != message.rowId { return }  // user navigated away
            if let body {
                bodyForSelectedMessage = body
                isLoadingBody = false
                return
            }
            // No .emlx on disk — Mail.app fetched only the header. Ask Mail.app
            // to download the body now (synchronously, on the AppleScript
            // serial queue), then retry the local read. The post-sync
            // pre-fetch only covers ~10 messages; on-demand has to fill in
            // the rest when the user actually opens one.
            await fetchBodyOnDemandAndReload(message: message, homeMailbox: homeMailbox)
        } catch {
            if selectedMessageId == message.rowId {
                bodyError = String(describing: error)
                isLoadingBody = false
            }
        }
    }

    /// Body is missing from disk — ask Mail.app to download it via
    /// AppleScript (`source of msg` triggers an IMAP fetch), then retry
    /// the local read. Bounded retry: we know the AppleScript completed,
    /// but Mail.app sometimes lags briefly between the AppleEvent return
    /// and writing the .emlx to disk. We poll every 500 ms for up to 8s
    /// after the script returns; if still nothing, surface the error.
    private func fetchBodyOnDemandAndReload(message: MessageHeader, homeMailbox: Mailbox) async {
        guard let acct = accounts.first(where: { $0.uuid == homeMailbox.accountUUID }),
              let email = acct.emailAddress else {
            // Fallback: surface the original error, can't even build a fetch.
            bodyError = "No .emlx file on disk for message rowid \(message.rowId) in \(homeMailbox.pathComponents.joined(separator: "/")). Mail.app may not have downloaded the body yet — open the message in Mail.app once and try again."
            isLoadingBody = false
            return
        }

        let entry = MailScripter.BatchEntry(
            rfcMessageId: message.rfcMessageId ?? "",
            appleRowId: message.rowId,
            accountEmail: email,
            mailboxPathComponents: homeMailbox.pathComponents
        )

        // Run on the same serial queue as Mark-as-Read so we don't compete
        // with concurrent osascript invocations against Mail.app.
        await MailScripter.fetchBodies([entry])

        // The AppleScript returned, meaning Mail.app's `source of msg` read
        // resolved. Now invalidate the .emlx cache for this mailbox and
        // re-read. Mail.app may need a beat to flush the new file to disk.
        guard selectedMessageId == message.rowId, let bodyLoader else { return }
        await bodyLoader.invalidate(mailboxRowId: homeMailbox.rowId)

        let pollDeadline = Date().addingTimeInterval(8)
        while Date() < pollDeadline {
            if selectedMessageId != message.rowId { return }
            if let body = try? await bodyLoader.loadBody(messageRowId: message.rowId, mailbox: homeMailbox),
               body != nil {
                bodyForSelectedMessage = body
                isLoadingBody = false
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            await bodyLoader.invalidate(mailboxRowId: homeMailbox.rowId)
        }

        // Still nothing on disk — surface the error so the user can fall
        // back to "Open in Mail.app". This usually means Mail.app couldn't
        // find the message via apple_rowid OR the IMAP fetch is still in
        // flight (slow network).
        if selectedMessageId == message.rowId {
            bodyError = "Mail.app didn't deliver the body for rowid \(message.rowId) within 8s — try again or use Open in Mail.app."
            isLoadingBody = false
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
