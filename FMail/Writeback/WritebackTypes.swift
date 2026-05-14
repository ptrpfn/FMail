import Foundation

/// Common surface for everything that can apply mark-read / move-to-junk /
/// delete to a batch of messages. Implementations:
///   - `AppleScriptWritebackService` (current MailScripter path; Tahoe-flaky)
///   - `GmailAPIWritebackService` (Phase B1; uses OAuth + `users.messages.modify`)
///   - `IMAPWritebackService` (Phase B2; uses LOGIN + UID STORE / UID MOVE)
///
/// Services are pure — they don't read FMail's index or hop to MainActor.
/// `WritebackRouter` resolves rowids into `MessageRef`s (already containing
/// the per-account fields each service needs) and dispatches them in groups.
/// This keeps each service implementation small and unit-testable.
protocol WritebackService: Sendable {
    var kind: WritebackKind { get }
    func setReadStatus(_ messages: [MessageRef], isRead: Bool) async -> WritebackResult
    func moveToJunk(_ messages: [MessageRef]) async -> WritebackResult
    func delete(_ messages: [MessageRef]) async -> WritebackResult
}

/// Identifies which backend should service a particular account. Maps 1:1
/// to the `service` column of the `account_writeback` table (Schema v7).
enum WritebackKind: String, Sendable, Hashable, CaseIterable {
    case applescript
    case gmailApi = "gmail_api"
    case imap
}

/// All the per-message info every backend needs. The router pre-resolves
/// these from `apple_rowid` so services don't need IndexDB access.
///
/// Most fields are optional because they're populated only when known:
///   - `gmailMessageId` is filled in B1 once the message has been queried
///     via Gmail API (or matched via `X-GM-MSGID` IMAP extension); nil before.
///   - `imapUID` is per-mailbox; if a message lives in multiple mailboxes
///     (Gmail labels) we use the canonical mailbox's UID.
///   - `accountEmail` is the account's primary email address; the
///     AppleScript and IMAP services use it for login / lookup.
struct MessageRef: Sendable, Hashable {
    let accountID: String           // FMail's account UUID
    let accountEmail: String?       // for AppleScript + IMAP login
    let appleRowId: Int             // for AppleScript + index updates
    let imapUID: Int?               // for IMAP (per source folder)
    let imapFolderPath: [String]?   // ["[Gmail]", "All Mail"] etc.
    let rfcMessageId: String?       // fallback identifier
    let gmailMessageId: String?     // Gmail API's stable per-account ID
    let keychainLabel: String?      // Gmail API + IMAP credential pointer
}

/// Aggregate result of a writeback call. `applied` is the count of messages
/// the backend reports it acted on. `perMessage` lets callers (e.g. the UI's
/// optimistic-flip reverter) know which specific rowids succeeded.
struct WritebackResult: Sendable {
    var applied: Int
    var perMessage: [Int: WritebackOutcome]   // apple_rowid → outcome
    var error: String?                         // overall dispatch error

    static func empty() -> WritebackResult {
        WritebackResult(applied: 0, perMessage: [:], error: nil)
    }

    /// Merge another result into this one. Used by the router to combine
    /// per-service partial results into one user-visible response.
    mutating func merge(_ other: WritebackResult) {
        applied += other.applied
        for (rowid, outcome) in other.perMessage {
            perMessage[rowid] = outcome
        }
        if let e = other.error {
            error = [error, e].compactMap { $0 }.joined(separator: "; ")
        }
    }

    /// Convenience: produce the `(applied: Int, error: String?)` tuple the
    /// MCP layer expects.
    func legacyTuple() -> (applied: Int, error: String?) {
        (applied, error)
    }
}

enum WritebackOutcome: Sendable, Equatable {
    case ok
    case notFound
    case failed(String)
}

enum WritebackError: Error, CustomStringConvertible {
    case notYetImplemented(WritebackKind)
    case missingCredentials(accountUUID: String, kind: WritebackKind)
    case unknownAccount(String)

    var description: String {
        switch self {
        case .notYetImplemented(let kind):
            return "\(kind.rawValue) writeback service is not implemented yet"
        case .missingCredentials(let uuid, let kind):
            return "no \(kind.rawValue) credentials configured for account \(uuid)"
        case .unknownAccount(let uuid):
            return "unknown account: \(uuid)"
        }
    }
}
