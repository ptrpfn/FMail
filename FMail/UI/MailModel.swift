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
    var selectedThreadIds: Set<Int> = []
    var selectedMessageId: Int?
    var threadsForSelectedMailbox: [ThreadSummary] = []
    var messagesInSelectedThread: [MessageHeader] = []
    var isLoadingThreads = false
    var threadsError: String?
    var bodyForSelectedMessage: MessageBody?
    var bodyError: String?
    /// Error from a bulk action (Mark Read/Unread across multiple messages).
    /// Set by `ReadStatusController`.
    var bulkActionError: String?

    // Search
    var searchQuery: String = ""
    var searchInterpretation: String = ""
    var searchResults: [MessageHeader] = []
    var isSearching: Bool = false
    var searchError: String?
    /// Search results the user has selected — drives `ReadStatusController`'s
    /// bulk Mark as Read / Unread.
    var selectedSearchResultIds: Set<Int> = []

    /// Visible to ReadStatusController (which mutates DB rows on optimistic
    /// flips) and other in-module collaborators.
    var indexDB: IndexDB?
    /// Internal so the MCP layer can hand it to read tools.
    private(set) var bodyLoader: BodyLoader?
    /// Sync orchestration — file watcher, body indexer, runIncrementalSync,
    /// post-sync body pre-fetch, skip-window after our own write-backs.
    @ObservationIgnored
    var syncCoordinator: SyncCoordinator?

    /// Loopback HTTP/JSON-RPC server for MCP clients. Off by default; gated
    /// by `MCPSettings.enabled`. Started after `boot()` reaches `.ready` so
    /// handlers always have an `indexDB` to read from.
    @ObservationIgnored
    var mcpServer: MCPServer?

    /// Mirrors `mcpServer?.isRunning` on the main actor so the menu can
    /// reflect status without hopping into the actor. Updated by
    /// `applyMCPSettings()`.
    var mcpServerStatus: MCPServerStatus = .stopped

    /// Owns Mark Read / Unread for messages, threads, and search results.
    @ObservationIgnored
    private(set) lazy var readStatus = ReadStatusController(model: self)

    /// Manages the `cloudflared` child process when the user toggles the
    /// Cloudflare tunnel on/off.
    @ObservationIgnored
    private(set) lazy var tunnel = TunnelCoordinator(
        mcpPort: { MCPSettings.port },
        mcpIsRunning: { [weak self] in
            guard let self else { return false }
            if case .running = self.mcpServerStatus { return true }
            return false
        }
    )

    /// Set to true once `boot()` has registered the willTerminate observer
    /// so re-boots (e.g. after an FDA grant) don't double-register.
    @ObservationIgnored
    private var willTerminateObserverRegistered = false
    private var searchTask: Task<Void, Never>?

    /// Cap on rows pulled for the thread list and search results — the UI is
    /// a scannable list, not an exhaustive export.
    private static let listLoadLimit = 600

    var selectedMailbox: Mailbox? {
        guard case .mailbox(let id) = selection else { return nil }
        return mailboxes.first { $0.rowId == id }
    }

    var isAllMailboxesScope: Bool {
        if case .allMailboxes = selection { return true }
        return false
    }

    func boot() async {
        switch loadState {
        case .ready, .bootstrapping, .indexing: return
        default: break
        }

        // Best-effort cleanup so cmd-Q never leaves a public tunnel
        // running after FMail exits. Register once; the observer fires
        // on .main, so `stopBlockingForQuit` (MainActor) runs synchronously.
        if !willTerminateObserverRegistered {
            willTerminateObserverRegistered = true
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tunnel.stopBlockingForQuit()
                }
            }
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
            let db = try IndexDB(path: dbPath)
            self.indexDB = db
            let bodyLoader = BodyLoader(mailVersionDir: versionDir)
            self.bodyLoader = bodyLoader
            let indexer = Indexer(envelopePath: envelopePath, indexDB: db, mailVersionDir: versionDir)
            let bodyIndexer = BodyIndexer(indexDB: db, bodyLoader: bodyLoader)
            let coordinator = SyncCoordinator(model: self, indexer: indexer, bodyIndexer: bodyIndexer, mailVersionDir: versionDir)
            self.syncCoordinator = coordinator

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

            // Default scope: the "All Mailboxes" view.
            if selection == nil {
                selectAllMailboxes()
            }

            // Background: refresh sync to catch anything new since last run.
            Task { [weak coordinator] in
                await coordinator?.runIncrementalSync()
            }

            // Background: body content indexing for search.
            coordinator.startBodyIndexer()

            // File watcher: trigger refresh on change.
            coordinator.startFileWatcher()

            // Periodic safety-net sync — catches anything FSEvents missed or
            // the post-write skip window suppressed.
            coordinator.startPeriodicSync()

            // MCP server: opt-in via Settings. Reads the index built above.
            applyMCPSettings()
        } catch {
            loadState = .failed(String(describing: error))
        }
    }

    /// Start, stop, or restart the MCP server to match `MCPSettings`.
    /// Called from `boot()` and from the menu whenever the toggle or port
    /// changes.
    func applyMCPSettings() {
        let enabled = MCPSettings.enabled
        let desiredPort = MCPSettings.port

        if !enabled {
            if let server = mcpServer {
                Task { @MainActor [weak self] in
                    await server.stop()
                    self?.mcpServer = nil
                    self?.mcpServerStatus = .stopped
                }
            } else {
                mcpServerStatus = .stopped
            }
            return
        }

        // Already running on the requested port — nothing to do. Avoids a
        // redundant stop/re-register/start cycle on every menu re-render.
        if mcpServer != nil, case .running(let p) = mcpServerStatus, p == UInt16(desiredPort) {
            return
        }

        guard let indexDB = self.indexDB, let bodyLoader = self.bodyLoader else {
            // boot() hasn't reached `.ready` yet — nothing to register against.
            // boot() calls applyMCPSettings() again at the end.
            mcpServerStatus = .starting
            return
        }

        // Build (or reuse) the server and its dispatcher.
        let server: MCPServer
        if let existing = mcpServer {
            server = existing
        } else {
            server = MCPServer()
            mcpServer = server
        }
        mcpServerStatus = .starting
        // Read-only context — MCP intentionally has no write surface.
        let context = MCPContext(indexDB: indexDB, bodyLoader: bodyLoader)
        Task { @MainActor [weak self] in
            // If a previous run is still listening on a different port, stop first.
            if await server.isRunning, await server.port != UInt16(desiredPort) {
                await server.stop()
            }
            do {
                let dispatcher = await server.dispatcherForRegistration()
                await MCPTools.registerReadTools(on: dispatcher, context: context)
                try await server.start(port: desiredPort)
                let p = await server.port
                self?.mcpServerStatus = .running(port: p)
            } catch {
                Log.mcp.error("MCP start failed: \(String(describing: error), privacy: .public)")
                self?.mcpServerStatus = .error(String(describing: error))
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

        // Inherits MainActor isolation from this @MainActor method, so the
        // result handling runs on the main actor without an explicit hop.
        searchTask = Task { [weak self] in
            do {
                let rows = try await db.search(compiled, limit: Self.listLoadLimit)
                if Task.isCancelled { return }
                guard let self else { return }
                self.searchResults = rows
                self.isSearching = false
            } catch {
                self?.searchError = String(describing: error)
                self?.isSearching = false
            }
        }
    }

    func refreshFromIndexDB() async throws {
        guard let db = indexDB else { return }
        let mboxes = try await db.loadMailboxes()
        let accts = try await db.loadAccounts()
        // Ensure mailboxes have an account row (in case of out-of-order load).
        let acctMap = Dictionary(uniqueKeysWithValues: accts.map { ($0.uuid, $0) })
        let allUUIDs = Set(mboxes.map(\.accountUUID))
        let finalAccounts = allUUIDs.sorted().map { uuid in
            acctMap[uuid] ?? MailAccount(uuid: uuid, displayName: "Account \(uuid.prefix(8))", emailAddress: nil)
        }
        self.mailboxes = mboxes
        self.accounts = finalAccounts
        do {
            self.allUnreadCount = try await db.countAllUnreadExcludingDrafts()
        } catch {
            // Keep the previous count rather than zeroing the badge — a
            // transient SQLite error shouldn't make the user think their
            // inbox cleared itself.
            Log.db.error("countAllUnreadExcludingDrafts failed: \(String(describing: error), privacy: .public)")
        }

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

        // Re-run any active search so its result list reflects the new index.
        if !searchQuery.isEmpty {
            updateSearch(searchQuery)
        }
    }

    func selectAllMailboxes() {
        select(.allMailboxes)
    }

    /// Switches scope, clears reader/thread state, and kicks off a thread-list
    /// load. Silently no-ops on a `.mailbox(id)` for a mailbox that's not in
    /// `mailboxes` (stale id guard).
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
                threads = try await db.loadAllThreadSummaries(limit: Self.listLoadLimit)
            case .mailbox(let id):
                threads = try await db.loadThreadSummaries(mailboxRowId: id, limit: Self.listLoadLimit)
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

    /// Open `message` in Mail.app via the `message://` URL scheme. Returns
    /// false when the message has no Message-ID or macOS refuses to open it.
    @discardableResult
    func openInMailApp(_ message: MessageHeader) -> Bool {
        guard let rfcId = message.rfcMessageId, !rfcId.isEmpty else { return false }
        return MailAppOpener.openMessage(rfcMessageId: rfcId)
    }
}

enum SidebarSelection: Hashable, Sendable {
    case allMailboxes
    case mailbox(Int)
}

/// MainActor-side view of the MCP server's lifecycle state.
enum MCPServerStatus: Sendable, Equatable {
    case stopped
    case starting
    case running(port: UInt16)
    case error(String)
}
