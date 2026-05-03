import Foundation

/// Boolean tree of search conditions.
indirect enum QueryNode: Equatable {
    case and([QueryNode])
    case or([QueryNode])
    case not(QueryNode)
    case term(Term)
    case empty
}

/// Atomic search predicates. Some compile to FTS5 MATCH terms, others to
/// auxiliary SQL conditions on the `messages` table.
enum Term: Equatable {
    /// Bag-of-words matched in any indexed FTS column.
    case anyText(String)
    /// Multi-word phrase matched in any column.
    case phrase(String)

    /// Single-word value matched in a specific FTS column.
    case fromAddr(String)
    case toAddr(String)
    case ccAddr(String)
    case subject(String)
    case body(String)
    case attachmentName(String)

    case dateBefore(Date)
    case dateAfter(Date)
    /// Half-open range `[start, end)`. Used by `on:` and `during:`.
    case dateInRange(Date, Date)

    case isUnread, isRead, isFlagged, isUnflagged, hasAttachment, noAttachment
    case mailboxKind(String)        // in:inbox / in:sent / etc.
    case account(String)            // account:felix.matschke@gmail.com or short prefix

    /// Field we didn't recognize — pass through as bag-of-words on value
    /// so the user still gets results.
    case unknownField(name: String, value: String)
}
