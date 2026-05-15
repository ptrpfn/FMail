import Foundation

/// Existing `MailScripter` pipeline behind the `WritebackService` interface.
/// This is the fallback path for any account not configured for a server-
/// direct backend. Same Tahoe-flaky behaviour as before; B1/B2 add reliable
/// alternatives.
struct AppleScriptWritebackService: WritebackService {
    let kind: WritebackKind = .applescript

    func setReadStatus(_ messages: [MessageRef], isRead: Bool) async -> WritebackResult {
        let entries = messages.map { Self.batchEntry(from: $0) }
        let result = await MailScripter.setReadStatusBatch(entries, isRead: isRead)
        return Self.translate(result, messages: messages)
    }

    func moveToJunk(_ messages: [MessageRef]) async -> WritebackResult {
        // Hard-failed: macOS Tahoe broke `junk mailbox of <account>` for
        // every account in observed setups, and `move msg to <Spam mbox>`
        // over Gmail IMAP wedges Mail.app's AppleEvent queue for minutes
        // at a time. After ~3 weeks of trying to make this work via
        // AppleScript we concluded it's unfixable at that layer.
        // Authorize the Gmail account in Settings (uses Gmail API
        // directly) or wait for IMAP support (Phase B2).
        var out = WritebackResult.empty()
        let msg = "AppleScript move-to-junk is unsupported (macOS Tahoe broke the junk-mailbox lookup). Authorize this Gmail account in FMail Settings to use the Gmail API directly, or wait for Phase B2 IMAP support."
        out.error = msg
        for ref in messages { out.perMessage[ref.appleRowId] = .failed(msg) }
        return out
    }

    func delete(_ messages: [MessageRef]) async -> WritebackResult {
        let entries = messages.map { Self.batchEntry(from: $0) }
        let result = await MailScripter.deleteBatch(entries)
        return Self.translate(result, messages: messages)
    }

    // MARK: — Helpers

    private static func batchEntry(from ref: MessageRef) -> MailScripter.BatchEntry {
        MailScripter.BatchEntry(
            rfcMessageId: ref.rfcMessageId ?? "",
            appleRowId: ref.appleRowId,
            accountEmail: ref.accountEmail,
            mailboxPathComponents: ref.imapFolderPath
        )
    }

    /// MailScripter returns one aggregate result for the whole batch
    /// (matched count or a fail string). Since it doesn't tell us WHICH
    /// rowids matched, we attribute the outcome uniformly across the
    /// batch — `ok` to all when matched > 0, `notFound` to all when 0,
    /// `failed(...)` to all on dispatch error.
    private static func translate(_ result: MailScripter.Result, messages: [MessageRef]) -> WritebackResult {
        var out = WritebackResult.empty()
        switch result {
        case .ok(let matched):
            out.applied = matched
            for ref in messages { out.perMessage[ref.appleRowId] = .ok }
        case .notFound:
            for ref in messages { out.perMessage[ref.appleRowId] = .notFound }
            out.error = "Mail.app couldn't find any of the messages — apple_rowid may be stale."
        case .failed(let msg):
            for ref in messages { out.perMessage[ref.appleRowId] = .failed(msg) }
            out.error = "AppleScript failed: \(msg)"
        }
        return out
    }
}
