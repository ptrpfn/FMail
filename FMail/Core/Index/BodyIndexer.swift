import Foundation

/// Walks `.emlx` files for messages whose body has not yet been indexed,
/// extracts plain-text body, and adds it to FTS. Designed to run in the
/// background as a long sweep that the user can interrupt by quitting.
///
/// The plan calls this out as Phase 2 stage 2 / Phase 3 prerequisite. The
/// metadata sync in `Indexer.runFullSync` populates FTS with subject + sender
/// + recipients, so search works immediately for those fields. Body content
/// becomes searchable as this sweep progresses.
actor BodyIndexer {
    private let indexDB: IndexDB
    private let bodyLoader: BodyLoader
    private(set) var isRunning = false
    private var cancelled = false

    init(indexDB: IndexDB, bodyLoader: BodyLoader) {
        self.indexDB = indexDB
        self.bodyLoader = bodyLoader
    }

    func cancel() { cancelled = true }

    /// Runs until the unindexed-body queue is empty or `cancel()` is called.
    /// Reports progress via the `progress` closure (called on the MainActor).
    func runUntilDone(
        mailboxes: [Mailbox],
        progress: @MainActor @escaping (BodyIndexProgress) -> Void
    ) async {
        if isRunning { return }
        isRunning = true
        cancelled = false
        defer { isRunning = false }

        let mailboxByRowId = Dictionary(uniqueKeysWithValues: mailboxes.map { ($0.rowId, $0) })

        let total = (try? await indexDB.countUnindexedBody()) ?? 0
        var done = 0
        await reportProgress(progress, stage: "Indexing bodies", done: 0, total: total)

        let batchSize = 200
        while !cancelled {
            let batch: [(rowid: Int, mailboxRowId: Int)]
            do {
                batch = try await indexDB.fetchUnindexedBodyMessages(limit: batchSize)
            } catch {
                break
            }
            if batch.isEmpty { break }

            for entry in batch {
                if cancelled { break }
                guard let mb = mailboxByRowId[entry.mailboxRowId] else {
                    // Orphan reference; mark as indexed-with-empty so we don't loop.
                    try? await indexDB.setBodyText(messageRowId: entry.rowid, bodyText: "")
                    done += 1
                    continue
                }
                do {
                    if let body = try await bodyLoader.loadBody(messageRowId: entry.rowid, mailbox: mb) {
                        let text = body.displayText
                        try await indexDB.setBodyText(messageRowId: entry.rowid, bodyText: text)
                    } else {
                        // No .emlx on disk yet; mark with empty body so we move on.
                        // FSEvents-driven incremental sync would re-trigger indexing
                        // if the file appears later (Phase 5 enhancement).
                        try await indexDB.setBodyText(messageRowId: entry.rowid, bodyText: "")
                    }
                } catch {
                    // Skip; mark as done so we don't loop on a corrupt file.
                    try? await indexDB.setBodyText(messageRowId: entry.rowid, bodyText: "")
                }
                done += 1
                if done % 50 == 0 {
                    await reportProgress(progress, stage: "Indexing bodies", done: done, total: total)
                    // Yield so other actor work can run.
                    await Task.yield()
                }
            }
        }
        await reportProgress(progress, stage: cancelled ? "Paused" : "Idle", done: done, total: total)
    }

    private func reportProgress(_ closure: @MainActor @escaping (BodyIndexProgress) -> Void, stage: String, done: Int, total: Int) async {
        await MainActor.run {
            closure(BodyIndexProgress(stage: stage, done: done, total: total))
        }
    }
}

struct BodyIndexProgress: Sendable, Equatable {
    var stage: String
    var done: Int
    var total: Int

    static let idle = BodyIndexProgress(stage: "Idle", done: 0, total: 0)
}
