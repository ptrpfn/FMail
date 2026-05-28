import Foundation
import SQLite3

struct IndexProgress: Sendable, Equatable {
    var stage: String
    var done: Int
    var total: Int  // 0 = indeterminate

    static let idle = IndexProgress(stage: "Idle", done: 0, total: 0)
}

/// Mirrors Apple's Envelope Index into FMail's own DB. Single bulk pass per
/// table; results held in memory while we iterate chunks into IndexDB.
/// Memory peak ≈ 70 MB on a 150k-message mailbox; acceptable.
final class Indexer: Sendable {
    let envelopePath: String
    let indexDB: IndexDB
    let mailVersionDir: URL

    init(envelopePath: String, indexDB: IndexDB, mailVersionDir: URL) {
        self.envelopePath = envelopePath
        self.indexDB = indexDB
        self.mailVersionDir = mailVersionDir
    }

    /// Cheap read/unread reconcile against Apple's Envelope Index — updates
    /// only the rows whose `read` flag diverged from FMail's index. No thread
    /// rebuild, FTS, or body work, so it's safe to run on every menu open.
    /// Returns the number of rows changed.
    func syncReadFlagsOnly() async throws -> Int {
        let env = try EnvelopeReadOnly(path: envelopePath)
        defer { env.close() }
        let appleFlags = try env.fetchReadFlags()
        let current = try await indexDB.snapshotReadFlags()
        var toRead: [Int] = []
        var toUnread: [Int] = []
        for (rowid, read) in appleFlags {
            guard let cur = current[rowid], cur != read else { continue }
            if read { toRead.append(rowid) } else { toUnread.append(rowid) }
        }
        if !toRead.isEmpty { try await indexDB.setIsReadBatch(rowids: toRead, isRead: true) }
        if !toUnread.isEmpty { try await indexDB.setIsReadBatch(rowids: toUnread, isRead: false) }
        return toRead.count + toUnread.count
    }

    /// One full mirror pass. Idempotent (uses ON CONFLICT upserts).
    func runFullSync(progress: @MainActor @escaping (IndexProgress) -> Void) async throws {
        let env = try EnvelopeReadOnly(path: envelopePath)
        defer { env.close() }

        await report(progress, "Reading mailboxes")

        let mailboxes = try env.loadMailboxes()
        try await indexDB.upsertMailboxes(mailboxes)

        let acctUUIDs = Array(Set(mailboxes.map(\.accountUUID))).sorted()
        let accounts: [(uuid: String, displayName: String, email: String?)] = acctUUIDs.map { uuid in
            let email = env.likelyEmailAddress(forAccountUUID: uuid, mailboxes: mailboxes)
            let display = email ?? "Account \(uuid.prefix(8))"
            return (uuid, display, email)
        }
        try await indexDB.upsertAccounts(accounts)

        await report(progress, "Reading message metadata")
        let allMessages = try env.fetchAllMessages()
        let total = allMessages.count
        await report(progress, "Indexing messages", done: 0, total: total)
        try await chunked(allMessages, size: 2000) { batch, doneSoFar in
            let rows = batch.map(Self.makeIndexedMessage)
            try await self.indexDB.upsertMessages(rows)
            await self.report(progress, "Indexing messages", done: doneSoFar, total: total)
        }

        // Drop any FMail rows for messages Apple's Envelope Index no longer
        // exposes — covers deleted mail and rows filtered out by
        // `fetchAllMessages` (currently: draft autosaves with type=5).
        let keep = Set(allMessages.map(\.rowId))
        try await indexDB.pruneMessagesNotIn(keep)

        await report(progress, "Reading recipients")
        let allRcpts = try env.fetchAllRecipients()
        await report(progress, "Indexing recipients", done: 0, total: allRcpts.count)
        // Group by message rowid so per-message replace works correctly.
        let groupedR = Dictionary(grouping: allRcpts, by: \.messageRowId)
        var msgRcptKeys = Array(groupedR.keys)
        msgRcptKeys.sort()
        var rcptDone = 0
        try await chunked(msgRcptKeys, size: 1000) { keysBatch, _ in
            var rows: [IndexedRecipient] = []
            rows.reserveCapacity(keysBatch.count * 2)
            for key in keysBatch {
                for r in groupedR[key] ?? [] {
                    rows.append(IndexedRecipient(
                        messageRowId: r.messageRowId, kind: r.kind, position: r.position,
                        address: r.address, display: r.display.isEmpty ? nil : r.display
                    ))
                }
            }
            try await self.indexDB.upsertRecipients(rows)
            rcptDone += rows.count
            await self.report(progress, "Indexing recipients", done: rcptDone, total: allRcpts.count)
        }

        await report(progress, "Reading labels")
        let allLabels = try env.fetchAllLabels()
        try await indexDB.replaceAllMessageLabels(allLabels)

        await report(progress, "Reading references")
        let allRefs = try env.fetchAllReferences()
        await report(progress, "Indexing references", done: 0, total: allRefs.count)
        let groupedF = Dictionary(grouping: allRefs, by: \.fromRowId)
        var fromKeys = Array(groupedF.keys)
        fromKeys.sort()
        var refDone = 0
        try await chunked(fromKeys, size: 1000) { keysBatch, _ in
            var rows: [IndexedMessageLink] = []
            rows.reserveCapacity(keysBatch.count * 3)
            for key in keysBatch {
                for f in groupedF[key] ?? [] {
                    rows.append(IndexedMessageLink(
                        fromMessageRowId: f.fromRowId,
                        toMessageIdHash: f.toHash,
                        isParent: f.isParent
                    ))
                }
            }
            try await self.indexDB.upsertMessageLinks(rows)
            refDone += rows.count
            await self.report(progress, "Indexing references", done: refDone, total: allRefs.count)
        }

        await report(progress, "Building threads")
        let snapshotMessages = try await indexDB.snapshotMessagesForThreading()
        let snapshotLinks = try await indexDB.snapshotMessageLinks()
        let threads = ThreadGrouper.build(messages: snapshotMessages, links: snapshotLinks)
        try await indexDB.replaceThreads(threads)

        await report(progress, "Recomputing counts")
        try await indexDB.recomputeMailboxCounts()

        await report(progress, "Updating FTS index")
        try await indexDB.incrementalUpdateFTS()

        try await indexDB.setMeta("last_full_sync_at", String(Int(Date().timeIntervalSince1970)))
        try await indexDB.setMeta("schema_version_at_sync", String(Schema.currentVersion))

        await report(progress, "Done", done: total, total: total)
    }

    // MARK: — Helpers

    private func chunked<T>(_ items: [T], size: Int, body: ([T], Int) async throws -> Void) async throws {
        var idx = 0
        while idx < items.count {
            let end = min(idx + size, items.count)
            try await body(Array(items[idx..<end]), end)
            idx = end
        }
    }

    private func report(_ closure: @MainActor @escaping (IndexProgress) -> Void, _ stage: String, done: Int = 0, total: Int = 0) async {
        await MainActor.run {
            closure(IndexProgress(stage: stage, done: done, total: total))
        }
    }

    private static func makeIndexedMessage(_ raw: EnvelopeReadOnly.RawMessage) -> IndexedMessage {
        let subject = EncodedWord.decode(raw.subjectText)
        let prefix = raw.subjectPrefix
        let normalized = normalizeSubject(prefix + subject)
        return IndexedMessage(
            appleRowId: raw.rowId,
            appleMessageIdHash: raw.messageIdHash,
            mailboxRowId: raw.mailboxRowId,
            accountUUID: raw.accountUUID,
            subject: subject,
            subjectPrefix: prefix,
            subjectNormalized: normalized,
            senderAddress: raw.senderAddress.isEmpty ? nil : raw.senderAddress,
            senderDisplay: raw.senderDisplay.isEmpty ? nil : EncodedWord.decode(raw.senderDisplay),
            dateSent: raw.dateSent,
            dateReceived: raw.dateReceived,
            isRead: raw.isRead,
            isFlagged: raw.isFlagged,
            hasAttachment: raw.hasAttachment,
            rfcMessageId: raw.rfcMessageId,
            imapUID: raw.imapUID
        )
    }

    /// Normalize for thread grouping fallback: strip "Re:"/"Fwd:" prefixes,
    /// collapse whitespace, lowercase.
    static func normalizeSubject(_ s: String) -> String {
        var t = s
        let prefixes = ["re:", "re :", "fwd:", "fw:", "fwd :", "fw :"]
        var changed = true
        while changed {
            changed = false
            let trimmed = t.trimmingCharacters(in: .whitespaces).lowercased()
            for p in prefixes {
                if trimmed.hasPrefix(p) {
                    t = String(t.trimmingCharacters(in: .whitespaces).dropFirst(p.count))
                    changed = true
                    break
                }
            }
        }
        return t.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

