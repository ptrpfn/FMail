import Foundation

/// Decides which mailboxes to hide from the sidebar by default.
enum MailboxFilter {
    /// Returns true if this mailbox should be hidden by default.
    /// Hidden by default:
    /// - Gmail's `[Gmail]/All Mail` (duplicates everything)
    /// - Anything starting with `Recovered Messages` (crash artifacts)
    /// - `SendLater` (Apple's scheduled-send queue, not user-facing)
    static func isHiddenByDefault(pathComponents: [String]) -> Bool {
        guard let last = pathComponents.last else { return false }

        if pathComponents.count >= 2,
           pathComponents[pathComponents.count - 2] == "[Gmail]",
           last == "All Mail" {
            return true
        }
        if last.hasPrefix("Recovered Messages") { return true }
        if last == "SendLater" { return true }

        return false
    }
}
