import Foundation

/// Server-direct writeback via the Gmail REST API. Replaces the AppleScript
/// path for Gmail-authorized accounts. Phase B1.
///
/// Per-message flow:
///   1. Resolve RFC Message-ID → Gmail message ID via
///      `users.messages.list?q=rfc822msgid:<id>`. (Cached per call, not
///      across calls — across-call caching is a B3 polish.)
///   2. Call `users.messages.modify` (mark-read / move-to-spam) or
///      `users.messages.trash` (delete) with the resolved ID.
///
/// Errors surface per-message via `WritebackOutcome`. The aggregate
/// `WritebackResult.error` is populated only when the whole batch failed
/// to start (e.g. missing credentials for an account).
struct GmailAPIWritebackService: WritebackService {
    let kind: WritebackKind = .gmailApi

    func setReadStatus(_ messages: [MessageRef], isRead: Bool) async -> WritebackResult {
        await runPerMessage(messages) { client, gmailID in
            try await client.modifyMessage(
                id: gmailID,
                addLabels: isRead ? [] : [GmailSystemLabel.unread],
                removeLabels: isRead ? [GmailSystemLabel.unread] : []
            )
        }
    }

    func moveToJunk(_ messages: [MessageRef]) async -> WritebackResult {
        await runPerMessage(messages) { client, gmailID in
            try await client.modifyMessage(
                id: gmailID,
                addLabels: [GmailSystemLabel.spam],
                removeLabels: [GmailSystemLabel.inbox]
            )
        }
    }

    func delete(_ messages: [MessageRef]) async -> WritebackResult {
        await runPerMessage(messages) { client, gmailID in
            try await client.trashMessage(id: gmailID)
        }
    }

    // MARK: — Internals

    /// Group by Keychain label (= per-account), build a `GmailAPIClient`
    /// per account, run the closure per-message. Aggregates per-message
    /// outcomes into one `WritebackResult`.
    private func runPerMessage(
        _ messages: [MessageRef],
        _ operation: @Sendable @escaping (GmailAPIClient, String) async throws -> Void
    ) async -> WritebackResult {
        var out = WritebackResult.empty()
        let byAccount = Dictionary(grouping: messages, by: { $0.keychainLabel ?? "" })

        for (label, refs) in byAccount {
            if label.isEmpty {
                // Account is configured for `.gmailApi` but no keychain
                // label was set — should be impossible if Settings UI
                // wrote both atomically. Treat as missing credentials.
                for ref in refs {
                    out.perMessage[ref.appleRowId] = .failed("missing Gmail credentials")
                }
                continue
            }
            let client = GmailAPIClient(keychainLabel: label)
            for ref in refs {
                guard let rfcID = ref.rfcMessageId else {
                    out.perMessage[ref.appleRowId] = .failed("no RFC Message-ID — can't look up in Gmail")
                    continue
                }
                do {
                    guard let gmailID = try await client.findMessageID(rfc822msgid: rfcID) else {
                        out.perMessage[ref.appleRowId] = .notFound
                        continue
                    }
                    try await operation(client, gmailID)
                    out.perMessage[ref.appleRowId] = .ok
                    out.applied += 1
                } catch {
                    out.perMessage[ref.appleRowId] = .failed(String(describing: error))
                }
            }
        }

        // Surface a top-level error only if every message failed in the
        // same way (typical case: revoked / expired credentials).
        let failures = out.perMessage.values.compactMap { outcome -> String? in
            if case .failed(let m) = outcome { return m } else { return nil }
        }
        if !failures.isEmpty && failures.count == out.perMessage.count, let first = failures.first {
            out.error = first
        }
        return out
    }
}
