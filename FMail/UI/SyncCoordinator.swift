import Foundation

/// Owns sync orchestration: the in-flight/coalesce flags, the file watcher,
/// the body indexer task, and the runIncrementalSync + post-sync body
/// pre-fetch. Holds a back-reference to MailModel for the bits of state
/// that have to live on the observable model (mailboxes/accounts cache,
/// progress fields, indexDB connection).
@MainActor
final class SyncCoordinator {
    private weak var model: MailModel?
    private let indexer: Indexer
    private let bodyIndexer: BodyIndexer
    private let mailVersionDir: URL

    private var watcher: FileWatcher?
    private var bodyIndexerTask: Task<Void, Never>?
    private var periodicSyncTask: Task<Void, Never>?
    /// Belt-and-braces refresh — fires `runIncrementalSync()` even when no
    /// FSEvents arrive (Mail.app's IMAP writes occasionally miss the watcher,
    /// or the `skipSyncsUntil` window swallows the post-AppleScript reflow
    /// and no later event triggers a fresh pull). 60 s is well below
    /// Mail.app's IMAP-poll interval; full sync is idempotent so the cost
    /// is one cheap re-mirror per minute.
    private static let periodicSyncInterval: TimeInterval = 60
    private var syncInFlight = false
    /// Coalesces N FSEvents-during-sync down to one follow-up. By design —
    /// not a queue.
    private var syncRequestedWhileBusy = false
    /// When set in the future, FSEvents-triggered syncs are skipped until
    /// then. Used by ReadStatusController to suppress the follow-up sync
    /// that'd otherwise fire from Mail.app's `.emlx` flag-plist modification
    /// after our own write-back — we already updated the index optimistically.
    var skipSyncsUntil: Date?

    init(model: MailModel, indexer: Indexer, bodyIndexer: BodyIndexer, mailVersionDir: URL) {
        self.model = model
        self.indexer = indexer
        self.bodyIndexer = bodyIndexer
        self.mailVersionDir = mailVersionDir
    }

    func startFileWatcher() {
        let watcher = FileWatcher(rootPath: mailVersionDir.path) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.runIncrementalSync()
            }
        }
        watcher.start()
        self.watcher = watcher
    }

    func startPeriodicSync() {
        guard periodicSyncTask == nil else { return }
        let interval = Self.periodicSyncInterval
        periodicSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.runIncrementalSync()
            }
        }
    }

    func startBodyIndexer() {
        guard let model else { return }
        if bodyIndexerTask != nil { return }
        let snapshotMailboxes = model.mailboxes
        let bodyIndexer = self.bodyIndexer
        bodyIndexerTask = Task.detached { [weak self, weak model] in
            await bodyIndexer.runUntilDone(mailboxes: snapshotMailboxes) { snapshot in
                model?.bodyIndexProgress = snapshot
            }
            await MainActor.run { [weak self] in
                self?.bodyIndexerTask = nil
            }
        }
    }

    func runIncrementalSync() async {
        guard let model else { return }
        if let until = skipSyncsUntil, until > Date() {
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
        await bodyIndexer.cancel()
        bodyIndexerTask = nil

        do {
            try await indexer.runFullSync { [weak model] snapshot in
                model?.indexProgress = snapshot
            }
            try await model.refreshFromIndexDB()
            await fetchMissingUnreadBodies()
            model.indexProgress = .idle
        } catch {
            Log.sync.error("Incremental sync failed: \(String(describing: error), privacy: .public)")
        }

        startBodyIndexer()

        if syncRequestedWhileBusy {
            syncRequestedWhileBusy = false
            Task { await self.runIncrementalSync() }
        }
    }

    /// After each sync, ask Mail.app to fetch bodies for ALL unread messages
    /// we don't have on disk yet. Fires the AppleScript and returns —
    /// Mail.app does the IMAP grunt work in background, FSEventStream picks
    /// up the resulting `.emlx` files, BodyIndexer indexes them.
    private func fetchMissingUnreadBodies() async {
        guard let model, let db = model.indexDB else { return }
        guard let candidates = try? await db.fetchUnreadMissingBody(limit: nil),
              !candidates.isEmpty else { return }

        let entries: [MailScripter.BatchEntry] = candidates.compactMap { c -> MailScripter.BatchEntry? in
            guard let mb = model.mailboxes.first(where: { $0.rowId == c.mailboxRowId }),
                  let acct = model.accounts.first(where: { $0.uuid == mb.accountUUID }),
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
}
