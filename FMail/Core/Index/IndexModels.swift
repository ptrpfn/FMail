import Foundation

// Wire types passed into IndexDB's bulk-write API. They mirror the columns
// of the `messages` / `recipients` / `message_links` / `threads` tables.

struct IndexedMessage {
    let appleRowId: Int
    let appleMessageIdHash: Int64
    let mailboxRowId: Int
    let accountUUID: String
    let subject: String
    let subjectPrefix: String
    let subjectNormalized: String
    let senderAddress: String?
    let senderDisplay: String?
    let dateSent: Int?
    let dateReceived: Int?
    let isRead: Bool
    let isFlagged: Bool
    let hasAttachment: Bool
    let rfcMessageId: String?
    let imapUID: Int?
}

/// A distinct sender you've received mail from — surfaced in the priority
/// settings "add from recent" dropdown. `id` is the lowercased address so
/// SwiftUI lists stay stable.
struct RecentSender: Identifiable, Hashable, Sendable {
    let address: String
    let display: String
    var id: String { address.lowercased() }
    /// "Display <addr>" when a name is known, else just the address.
    var label: String { display.isEmpty ? address : "\(display) <\(address)>" }
}

struct IndexedRecipient {
    let messageRowId: Int
    let kind: Int       // RecipientKind raw value (0=to, 1=cc, 2=bcc, 3=from)
    let position: Int
    let address: String
    let display: String?
}

struct IndexedMessageLink {
    let fromMessageRowId: Int
    let toMessageIdHash: Int64
    let isParent: Bool
}

struct IndexedThread {
    let threadId: Int
    let rootMessageRowId: Int
    let latestDateReceived: Int
    let messageCount: Int
    let unreadCount: Int
    let flaggedCount: Int
    let memberRowIds: [Int]
}

/// Per-thread summary returned to the UI.
///
/// `latestSenderDisplay` is the *correspondent*, not strictly the sender:
///   - For incoming mail: sender display (or address if no display).
///   - For outgoing mail (sender matches one of our accounts'
///     `email_address`): the first `To:` recipient's display, so the row
///     in All Mailboxes / Sent shows the other party (e.g. "Bank") rather
///     than the user's own name repeating across every Sent thread.
/// `latestIsOutgoing` lets the UI prefix "To:" or use a different style.
struct ThreadSummary: Identifiable, Hashable {
    let threadId: Int
    let latestDateReceived: Date?
    let messageCount: Int
    let unreadCount: Int
    let flaggedCount: Int
    let latestSubject: String
    let latestSenderDisplay: String
    let latestMessageRowId: Int
    let latestIsOutgoing: Bool
    var id: Int { threadId }

    /// Copy with adjusted counts (the only fields optimistic flips touch).
    func with(messageCount: Int? = nil, unreadCount: Int? = nil) -> ThreadSummary {
        ThreadSummary(
            threadId: threadId,
            latestDateReceived: latestDateReceived,
            messageCount: messageCount ?? self.messageCount,
            unreadCount: unreadCount ?? self.unreadCount,
            flaggedCount: flaggedCount,
            latestSubject: latestSubject,
            latestSenderDisplay: latestSenderDisplay,
            latestMessageRowId: latestMessageRowId,
            latestIsOutgoing: latestIsOutgoing
        )
    }
}
