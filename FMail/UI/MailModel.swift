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
