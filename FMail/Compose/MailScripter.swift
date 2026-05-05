import AppKit
import Foundation

/// AppleScript-driven write-back to Mail.app. Runs scripts via `/usr/bin/osascript`
/// in a subprocess — keeps FMail's main thread free and avoids NSAppleScript's
/// fussy main-thread / runloop requirements. The first invocation triggers
/// macOS's Automation permission prompt ("FMail wants to control Mail.app").
///
/// All operations are **serialized** through `serialQueue` — running two
/// AppleScripts concurrently against Mail.app makes them compete for Mail's
/// main thread and one usually times out (-1712). Mail.app has no Message-ID
/// index, so each "find by message id" is a linear scan; in [Gmail]/All Mail
/// (100k+ messages) this takes seconds. We also wrap each script in
/// `with timeout of 300 seconds` so the default 60-s ceiling can't kill the
/// scan.
enum MailScripter {
    /// All `osascript` invocations go through this queue so they never run
    /// in parallel against Mail.app. Concurrent runs compete for Mail.app's
    /// main thread and almost always time out one of the two.
    private static let serialQueue = DispatchQueue(
        label: "com.felixmatschke.FMail.applescript",
        qos: .userInitiated
    )
    /// Asks Mail.app to set a message's read status. Returns when osascript
    /// finishes (Mail.app has applied the change or reported it couldn't find
    /// the message). Caller should run this with a Task and not await it on
    /// the main actor — UI feedback should be optimistic (already done before
    /// this is called).
    static func setReadStatus(
        rfcMessageId: String,
        isRead: Bool,
        accountEmail: String?,
        mailboxPathComponents: [String]?
    ) async -> Result {
        let cleaned = rfcMessageId
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard !cleaned.isEmpty else { return .failed("Empty Message-ID") }

        let escapedId = appleScriptEscape(cleaned)
        let readBool = isRead ? "true" : "false"

        let source = makeScript(
            escapedId: escapedId,
            readBool: readBool,
            accountEmail: accountEmail,
            mailboxPathComponents: mailboxPathComponents
        )

        let (stdout, stderr, exitCode) = await runOsascript(source)
        if exitCode != 0 {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = detail.isEmpty ? stdout : detail
            return .failed("osascript exit \(exitCode): \(body)")
        }
        let count = Int(stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return count > 0 ? .ok(matched: count) : .notFound
    }

    enum Result: Sendable {
        case ok(matched: Int)
        case notFound
        case failed(String)
    }

    /// Per-message metadata needed to batch a mark-as-read across multiple
    /// messages in one AppleScript. `imapUID` is preferred over
    /// `rfcMessageId` because Mail.app indexes by `id` (the IMAP UID) —
    /// an O(1) lookup instead of the linear `whose message id is "..."`
    /// scan.
    struct BatchEntry: Sendable {
        let rfcMessageId: String
        let imapUID: Int?
        let accountEmail: String?
        let mailboxPathComponents: [String]?
    }

    /// Mark many messages read/unread with a SINGLE osascript invocation.
    /// Entries are grouped by `(accountEmail, mailboxPath)`; each group
    /// scans its mailbox exactly once with `whose message id is in {...}`,
    /// so even a 100-message batch in one Gmail mailbox is one linear scan
    /// instead of 100. Falls through to the broad-walk path for entries
    /// that don't have account/mailbox info.
    static func setReadStatusBatch(_ entries: [BatchEntry], isRead: Bool) async -> Result {
        guard !entries.isEmpty else { return .notFound }

        let readBool = isRead ? "true" : "false"

        // Bucket targeted entries by (account email, joined mailbox path).
        // For each bucket we collect IMAP UIDs (fast `whose id is N`) and
        // RFC Message-IDs (slow `whose message id is "..."`) separately.
        struct GroupKey: Hashable {
            let email: String
            let pathKey: String
        }
        struct Group {
            let email: String
            let path: [String]
            var uids: [Int] = []
            var rfcIds: [String] = []
        }
        var targetedGroups: [GroupKey: Group] = [:]
        var fallbackUIDs: [Int] = []
        var fallbackRfcIds: [String] = []

        for e in entries {
            let cleaned = e.rfcMessageId
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            let hasUID = e.imapUID != nil
            let hasRfc = !cleaned.isEmpty
            guard hasUID || hasRfc else { continue }
            if let email = e.accountEmail, !email.isEmpty,
               let path = e.mailboxPathComponents, !path.isEmpty {
                let key = GroupKey(email: email, pathKey: path.joined(separator: "/"))
                var group = targetedGroups[key] ?? Group(email: email, path: path)
                if let uid = e.imapUID {
                    group.uids.append(uid)
                } else {
                    group.rfcIds.append(cleaned)
                }
                targetedGroups[key] = group
            } else {
                if let uid = e.imapUID {
                    fallbackUIDs.append(uid)
                } else {
                    fallbackRfcIds.append(cleaned)
                }
            }
        }

        var blocks: [String] = []

        // Targeted blocks: navigate to the canonical mailbox once, then look
        // up by IMAP UID (`whose id is N`, indexed in Mail.app — fast) plus
        // any leftover entries that only have RFC Message-IDs (linear scan).
        for (_, group) in targetedGroups {
            let escapedEmail = appleScriptEscape(group.email)
            let mailboxRef = buildMailboxRef(pathComponents: group.path)

            var inner: [String] = []
            if !group.uids.isEmpty {
                let uidLiteral = group.uids.map(String.init).joined(separator: ", ")
                inner.append("""
                                set targetUIDs to {\(uidLiteral)}
                                repeat with aUID in targetUIDs
                                    try
                                        set matches to (messages of targetMailbox whose id is aUID)
                                        repeat with msg in matches
                                            set read status of msg to \(readBool)
                                            set foundCount to foundCount + 1
                                        end repeat
                                    end try
                                end repeat
                """)
            }
            if !group.rfcIds.isEmpty {
                let idLiteral = group.rfcIds.map { "\"\(appleScriptEscape($0))\"" }.joined(separator: ", ")
                inner.append("""
                                set targetMsgIds to {\(idLiteral)}
                                repeat with aMsgId in targetMsgIds
                                    try
                                        set matches to (messages of targetMailbox whose message id is aMsgId)
                                        repeat with msg in matches
                                            set read status of msg to \(readBool)
                                            set foundCount to foundCount + 1
                                        end repeat
                                    end try
                                end repeat
                """)
            }

            blocks.append("""
                try
                    set theAccount to missing value
                    repeat with acc in accounts
                        try
                            if (email addresses of acc) contains "\(escapedEmail)" then
                                set theAccount to acc
                                exit repeat
                            end if
                        end try
                    end repeat
                    if theAccount is not missing value then
                        try
                            set targetMailbox to \(mailboxRef)
            \(inner.joined(separator: "\n"))
                        end try
                    end if
                end try
            """)
        }

        if !fallbackUIDs.isEmpty || !fallbackRfcIds.isEmpty {
            var inner: [String] = []
            if !fallbackUIDs.isEmpty {
                let lit = fallbackUIDs.map(String.init).joined(separator: ", ")
                inner.append("""
                                    set fallbackUIDs to {\(lit)}
                                    repeat with aUID in fallbackUIDs
                                        try
                                            set matches to (messages of mbox whose id is aUID)
                                            repeat with msg in matches
                                                set read status of msg to \(readBool)
                                                set foundCount to foundCount + 1
                                            end repeat
                                        end try
                                    end repeat
                """)
            }
            if !fallbackRfcIds.isEmpty {
                let lit = fallbackRfcIds.map { "\"\(appleScriptEscape($0))\"" }.joined(separator: ", ")
                inner.append("""
                                    set fallbackMsgIds to {\(lit)}
                                    repeat with aMsgId in fallbackMsgIds
                                        try
                                            set matches to (messages of mbox whose message id is aMsgId)
                                            repeat with msg in matches
                                                set read status of msg to \(readBool)
                                                set foundCount to foundCount + 1
                                            end repeat
                                        end try
                                    end repeat
                """)
            }
            blocks.append("""
                try
                    repeat with anAccount in accounts
                        try
                            repeat with mbox in (mailboxes of anAccount)
                                try
            \(inner.joined(separator: "\n"))
                                end try
                            end repeat
                        end try
                    end repeat
                end try
            """)
        }

        let source = """
        with timeout of 600 seconds
            tell application "Mail"
                set foundCount to 0
                \(blocks.joined(separator: "\n"))
                return foundCount
            end tell
        end timeout
        """

        let (stdout, stderr, exitCode) = await runOsascript(source)
        if exitCode != 0 {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = detail.isEmpty ? stdout : detail
            return .failed("osascript exit \(exitCode): \(body)")
        }
        let count = Int(stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return count > 0 ? .ok(matched: count) : .notFound
    }

    // MARK: — Script construction

    private static func makeScript(
        escapedId: String,
        readBool: String,
        accountEmail: String?,
        mailboxPathComponents: [String]?
    ) -> String {
        let body: String
        if let accountEmail, !accountEmail.isEmpty,
           let mailboxPathComponents, !mailboxPathComponents.isEmpty {
            // Targeted: navigate directly to the message's home mailbox so
            // Mail.app only scans that one mailbox's messages.
            let escapedEmail = appleScriptEscape(accountEmail)
            let mailboxRef = buildMailboxRef(pathComponents: mailboxPathComponents)
            body = """
                set targetId to "\(escapedId)"
                set targetEmail to "\(escapedEmail)"
                set foundCount to 0
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
                            set foundCount to foundCount + 1
                        end repeat
                    end try
                end if
                return foundCount
            """
        } else {
            // Fallback: walk one level deep across all accounts.
            body = """
                set targetId to "\(escapedId)"
                set foundCount to 0
                repeat with anAccount in accounts
                    try
                        repeat with mbox in (mailboxes of anAccount)
                            try
                                set matches to (messages of mbox whose message id is targetId)
                                repeat with msg in matches
                                    set read status of msg to \(readBool)
                                    set foundCount to foundCount + 1
                                end repeat
                            end try
                        end repeat
                    end try
                end repeat
                return foundCount
            """
        }

        // Wrap in a 5-minute timeout: the default 60 s isn't enough for a
        // linear scan of [Gmail]/All Mail (100k+ messages) on slower disks.
        return """
        with timeout of 300 seconds
            tell application "Mail"
            \(body)
            end tell
        end timeout
        """
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

    // MARK: — osascript subprocess

    /// Runs an AppleScript via `/usr/bin/osascript` on the **serial queue** so
    /// concurrent FMail actions don't fire two scripts at Mail.app at the
    /// same time (that compounds the slowness and reliably hits the
    /// AppleEvent timeout). Subsequent calls wait their turn here.
    private static func runOsascript(_ source: String) async -> (String, String, Int32) {
        await withCheckedContinuation { continuation in
            serialQueue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", source]
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(returning: (out, err, process.terminationStatus))
                } catch {
                    continuation.resume(returning: ("", error.localizedDescription, -1))
                }
            }
        }
    }
}
