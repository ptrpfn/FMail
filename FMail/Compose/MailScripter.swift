import AppKit
import Foundation

/// AppleScript-driven write-back to Mail.app. Used for actions FMail itself
/// can't perform (because it never writes to Apple Mail's local store):
/// mark-as-read, mark-as-unread, etc.
///
/// Triggers the macOS Automation permission prompt the first time it runs
/// ("FMail wants to control Mail.app"). `NSAppleEventsUsageDescription` is
/// already set in the bundle Info.plist.
enum MailScripter {
    /// Asks Mail.app to set a message's read status. Returns immediately —
    /// the AppleScript is fire-and-forget so neither FMail nor Mail.app
    /// freeze while we wait. Caller is expected to update the local UI
    /// optimistically; the next sync (and FSEvents) reconciles eventually.
    ///
    /// The lookup is targeted at the message's canonical account+mailbox so
    /// Mail.app only scans one mailbox's messages — much cheaper than walking
    /// every account/mailbox.
    static func setReadStatusFireAndForget(
        rfcMessageId: String,
        isRead: Bool,
        accountEmail: String?,
        mailboxPathComponents: [String]?
    ) {
        let cleaned = rfcMessageId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard !cleaned.isEmpty else { return }

        let escapedId = appleScriptEscape(cleaned)
        let readBool = isRead ? "true" : "false"

        let bodyScript: String
        if let accountEmail, !accountEmail.isEmpty,
           let mailboxPathComponents, !mailboxPathComponents.isEmpty {
            // Targeted: navigate directly to the message's home mailbox.
            let escapedEmail = appleScriptEscape(accountEmail)
            let mailboxRef = buildMailboxRef(pathComponents: mailboxPathComponents)
            bodyScript = """
                set targetId to "\(escapedId)"
                set targetEmail to "\(escapedEmail)"
                set theAccount to missing value
                repeat with acc in accounts
                    try
                        if (email addresses of acc) contains targetEmail then
                            set theAccount to acc
                            exit repeat
                        end if
                    end try
                end repeat
                if theAccount is not missing value then
                    try
                        set targetMailbox to \(mailboxRef)
                        set matches to (messages of targetMailbox whose message id is targetId)
                        repeat with msg in matches
                            set read status of msg to \(readBool)
                        end repeat
                    end try
                end if
            """
        } else {
            // Fallback: walk one level deep across all accounts. Slower and
            // misses Gmail's nested layout, but covers common iCloud cases
            // when we don't have account/mailbox metadata.
            bodyScript = """
                set targetId to "\(escapedId)"
                repeat with anAccount in accounts
                    try
                        repeat with mbox in (mailboxes of anAccount)
                            try
                                set matches to (messages of mbox whose message id is targetId)
                                repeat with msg in matches
                                    set read status of msg to \(readBool)
                                end repeat
                            end try
                        end repeat
                    end try
                end repeat
            """
        }

        // `ignoring application responses` — fire the apple event without
        // waiting for Mail.app to finish processing. The NSAppleScript call
        // returns immediately, so neither FMail nor the user's interaction
        // with Mail.app's UI gets blocked while Mail.app does the work.
        let source = """
        tell application "Mail"
            ignoring application responses
            \(bodyScript)
            end ignoring
        end tell
        """

        DispatchQueue.global(qos: .userInitiated).async {
            guard let script = NSAppleScript(source: source) else { return }
            var error: NSDictionary?
            _ = script.executeAndReturnError(&error)
            // Errors silently ignored — there's no UI to show them to in the
            // fire-and-forget model, and the next sync will reconcile state
            // either way. (For debugging, set a breakpoint on `error != nil`.)
        }
    }

    /// Build an AppleScript object reference like
    /// `mailbox "All Mail" of mailbox "[Gmail]" of theAccount`
    /// from path components like `["[Gmail]", "All Mail"]`.
    private static func buildMailboxRef(pathComponents: [String]) -> String {
        var ref = "theAccount"
        for component in pathComponents {
            ref = "mailbox \"\(appleScriptEscape(component))\" of \(ref)"
        }
        return ref
    }

    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
