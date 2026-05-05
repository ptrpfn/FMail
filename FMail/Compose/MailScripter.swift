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
    /// messages in one AppleScript. `appleRowId` is preferred over
    /// `rfcMessageId` because Mail.app's `id` property = Apple's Envelope
    /// Index ROWID — an O(1) lookup vs. the linear `whose message id is`
    /// scan. NB: Mail.app's AppleScript `id` is *not* the IMAP UID —
    /// confirmed empirically against Gmail (see
    /// `MailScripterDebug/peek` and `find` in the side tool).
    struct BatchEntry: Sendable {
        let rfcMessageId: String
        let appleRowId: Int?
        let accountEmail: String?
        let mailboxPathComponents: [String]?
    }

    /// Asks Mail.app to load the message bodies for the given entries.
    /// Reads `source of msg` for each, which is the AppleScript-visible
    /// trigger that forces Mail.app to fetch the body over IMAP/Gmail-API
    /// if it isn't already on disk. Fire-and-forget — we don't care about
    /// the source text, only the side effect (Mail.app writes the .emlx).
    /// FSEventStream picks up the new file and our BodyIndexer reads it.
    static func fetchBodies(_ entries: [BatchEntry]) async {
        guard !entries.isEmpty else { return }

        // Re-use the same per-mailbox bucketing as setReadStatusBatch so
        // each mailbox is opened once and we use UID lookups when possible.
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
        var groups: [GroupKey: Group] = [:]

        for e in entries {
            guard let email = e.accountEmail, !email.isEmpty,
                  let path = e.mailboxPathComponents, !path.isEmpty else { continue }
            let key = GroupKey(email: email, pathKey: path.joined(separator: "/"))
            var g = groups[key] ?? Group(email: email, path: path)
            if let uid = e.appleRowId { g.uids.append(uid) }
            let raw = e.rfcMessageId.trimmingCharacters(in: .whitespacesAndNewlines)
            let stripped = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            if !stripped.isEmpty {
                g.rfcIds.append("<\(stripped)>")
                g.rfcIds.append(stripped)
            }
            groups[key] = g
        }
        guard !groups.isEmpty else { return }

        var blocks: [String] = []
        for (_, group) in groups {
            let escapedEmail = appleScriptEscape(group.email)
            // Same iterate-by-name approach as setReadStatusBatch.
            let candidateNames = mailboxNameCandidates(pathComponents: group.path)
            let nameLiterals = candidateNames
                .map { "\"\(appleScriptEscape($0))\"" }
                .joined(separator: ", ")
            // UID-first; only run the slow `whose message id` scan if UIDs
            // didn't hit. Action: read `source` to force Mail.app to fetch
            // the body.
            let inner = makeLookupBlock(
                uids: group.uids,
                rfcIds: group.rfcIds,
                mailboxRef: "mbox",
                action: "set _ to source of msg",
                indent: "                                "
            )
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
                        set targetNames to {\(nameLiterals)}
                        try
                            repeat with mbox in (mailboxes of theAccount)
                                try
                                    if (name of mbox) is in targetNames then
            \(inner)
                                    end if
                                end try
                            end repeat
                        end try
                    end if
                end try
            """)
        }

        // foundCount is mutated by makeLookupBlock to short-circuit slow
        // Message-ID scans. We don't read it back here (fire-and-forget),
        // but it must exist before the inner blocks reference it.
        let source = """
        with timeout of 600 seconds
            tell application "Mail"
                set foundCount to 0
                \(blocks.joined(separator: "\n"))
            end tell
        end timeout
        """

        // Run on the serial queue (same as Mark-as-Read) so multiple Mail.app
        // operations from FMail don't race each other.
        _ = await runOsascript(source)
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
            let raw = e.rfcMessageId.trimmingCharacters(in: .whitespacesAndNewlines)
            let stripped = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            let bracketed = stripped.isEmpty ? "" : "<\(stripped)>"

            let hasUID = e.appleRowId != nil
            let hasRfc = !stripped.isEmpty
            guard hasUID || hasRfc else { continue }
            if let email = e.accountEmail, !email.isEmpty,
               let path = e.mailboxPathComponents, !path.isEmpty {
                let key = GroupKey(email: email, pathKey: path.joined(separator: "/"))
                var group = targetedGroups[key] ?? Group(email: email, path: path)
                if let uid = e.appleRowId { group.uids.append(uid) }
                // Include both bracketed and stripped forms because Mail.app's
                // `message id` property has been observed to return either
                // form depending on the protocol/source. Idempotent — Mail.app
                // setting `read status` on the same message twice is harmless.
                if !bracketed.isEmpty { group.rfcIds.append(bracketed) }
                if !stripped.isEmpty { group.rfcIds.append(stripped) }
                targetedGroups[key] = group
            } else {
                if let uid = e.appleRowId { fallbackUIDs.append(uid) }
                if !bracketed.isEmpty { fallbackRfcIds.append(bracketed) }
                if !stripped.isEmpty { fallbackRfcIds.append(stripped) }
            }
        }

        var blocks: [String] = []

        // Performance: Mail.app indexes messages by `id` (= Apple Envelope
        // Index ROWID) so `whose id is N` is O(log n). `whose message id is X`
        // is a LINEAR SCAN — for [Gmail]/All Mail at 100k+ messages, each
        // takes seconds, and Mail.app blocks its main thread (= beachball).
        //
        // Strategy: try the fast UID lookup first. ONLY fall back to the
        // slow Message-ID scan if the UID lookup didn't match anything in
        // this mailbox candidate. apple_rowid is always present, so in
        // practice the Message-ID branch is dead code — kept as a safety
        // net for the rare case where rowId mismatches.
        //
        // We try multiple mailbox path variants because Mail.app's view
        // of Gmail flattens the [Gmail] container.
        for (_, group) in targetedGroups {
            let escapedEmail = appleScriptEscape(group.email)
            // Names to match against `(name of mbox)` while iterating
            // `mailboxes of theAccount`. We collect every plausible form
            // because Mail.app's view of Gmail varies — the leaf name
            // (e.g. `All Mail`) usually wins, but some setups also expose
            // the slash-joined form (`[Gmail]/All Mail`) as a single
            // mailbox. Empirically, `mailbox "X" of theAccount` (lookup by
            // name on a STORED account reference) is unreliable for some
            // names like `All Mail` (errors -1728) — so we always iterate.
            let candidateNames = mailboxNameCandidates(pathComponents: group.path)
            let nameLiterals = candidateNames
                .map { "\"\(appleScriptEscape($0))\"" }
                .joined(separator: ", ")
            let action = "set read status of msg to \(readBool)"
            let inner = makeLookupBlock(
                uids: group.uids,
                rfcIds: group.rfcIds,
                mailboxRef: "mbox",
                action: action,
                indent: "                                "
            )
            // Same lookup block, deeper indent, for the brute-walk fallback.
            let fallbackBody = makeLookupBlock(
                uids: group.uids,
                rfcIds: group.rfcIds,
                mailboxRef: "mbox",
                action: action,
                indent: "                                            "
            )

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
                        set countBefore to foundCount
                        set targetNames to {\(nameLiterals)}
                        -- Iterate by name so we don't depend on
                        -- `mailbox "X" of theAccount` (which Mail.app
                        -- silently fails for some mailbox names like
                        -- `All Mail` even when the mailbox exists).
                        try
                            repeat with mbox in (mailboxes of theAccount)
                                try
                                    if (name of mbox) is in targetNames then
            \(inner)
                                    end if
                                end try
                            end repeat
                        end try
                        if foundCount = countBefore then
                            -- Targeted name-iteration found nothing — fall
                            -- back to walking every mailbox of the account
                            -- plus one nested level deep. Slow (every
                            -- mailbox gets scanned) but only triggers when
                            -- the leaf-name match misses.
                            try
                                repeat with mbox in (mailboxes of theAccount)
                                    try
            \(fallbackBody)
                                    end try
                                    try
                                        repeat with submbox in (mailboxes of mbox)
                                            try
                                                set mbox to submbox
            \(fallbackBody)
                                            end try
                                        end repeat
                                    end try
                                end repeat
                            end try
                        end if
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

    /// Names to match against `(name of mbox)` when iterating mailboxes
    /// of an account, so we can locate the right one without depending
    /// on the unreliable `mailbox "X" of theAccount` direct lookup.
    ///
    /// For Gmail `["[Gmail]", "All Mail"]` the message lives in a
    /// mailbox usually exposed as `All Mail` (leaf), occasionally as
    /// `[Gmail]/All Mail` (slash-joined). We list both to cover either.
    /// For single-component paths (`["INBOX"]`), only the name itself
    /// is needed.
    private static func mailboxNameCandidates(pathComponents: [String]) -> [String] {
        guard let leaf = pathComponents.last, !pathComponents.isEmpty else { return [] }
        var names: [String] = []
        names.append(leaf)
        if pathComponents.count > 1 {
            names.append(pathComponents.joined(separator: "/"))
        }
        return names
    }

    /// AppleScript snippet that finds messages in `mailboxRef` and runs
    /// `action` on each (e.g. `"set read status of msg to true"`).
    ///
    /// UID lookup runs first (O(log n) — Mail.app indexes by `id` =
    /// apple_rowid); the slow Message-ID scan only runs as a fallback if
    /// the UID lookup found nothing in this mailbox. apple_rowid is
    /// always present, so in practice the Message-ID branch is dead code —
    /// kept as a safety net.
    ///
    /// `mailboxRef` is the AppleScript expression for the mailbox to scan
    /// (e.g. `"targetMailbox"` or `"mbox"`).
    /// `action` is the AppleScript statement run for each `msg` reference;
    /// it should NOT increment `foundCount` — the helper does that.
    /// `indent` is the leading whitespace prepended to each line so the
    /// emitted block aligns with the surrounding scaffold.
    private static func makeLookupBlock(
        uids: [Int],
        rfcIds: [String],
        mailboxRef: String,
        action: String,
        indent: String
    ) -> String {
        // Empirical scaling of `whose id = X1 or id = X2 or …`:
        //   1 ID:  ~4s   |   3 IDs: ~4s   |   5 IDs: ~5s
        //   7 IDs: ~6s   |   8 IDs: ~30-75s (variable)
        // There's a sharp non-linearity at 8+ OR terms — Mail.app's
        // predicate evaluator falls over. Cap each chain at 5 IDs and
        // emit multiple chains in sequence within the same mailbox match.
        // For an 8-message batch in `[Gmail]/All Mail`: 2 chains × ~5s
        // = ~10s, instead of the 30-75s a single 8-OR chain would take.
        let chunkSize = 5
        let uidChunks = uids.chunked(into: chunkSize)
        let rfcChunks = rfcIds.chunked(into: chunkSize)

        var lines: [String] = []
        let hasUIDs = !uids.isEmpty
        let hasRfcIds = !rfcIds.isEmpty
        if hasUIDs {
            // Distinct variable (`mboxCountBefore`) avoids shadowing the
            // outer per-account `countBefore`.
            lines.append("set mboxCountBefore to foundCount")
            for chunk in uidChunks {
                let condition = chunk.map { "id = \($0)" }.joined(separator: " or ")
                lines.append("try")
                lines.append("    set matches to (messages of \(mailboxRef) whose \(condition))")
                lines.append("    repeat with msg in matches")
                lines.append("        \(action)")
                lines.append("        set foundCount to foundCount + 1")
                lines.append("    end repeat")
                lines.append("end try")
            }
        }
        if hasRfcIds {
            // Slow Message-ID scan, only as a fallback when UID lookup
            // missed (apple_rowid mismatch — rare).
            let openGuard = hasUIDs ? "if foundCount = mboxCountBefore then" : ""
            let closeGuard = hasUIDs ? "end if" : ""
            if !openGuard.isEmpty { lines.append(openGuard) }
            let bodyIndent = hasUIDs ? "    " : ""
            for chunk in rfcChunks {
                let condition = chunk
                    .map { "message id = \"\(appleScriptEscape($0))\"" }
                    .joined(separator: " or ")
                lines.append("\(bodyIndent)try")
                lines.append("\(bodyIndent)    set matches to (messages of \(mailboxRef) whose \(condition))")
                lines.append("\(bodyIndent)    repeat with msg in matches")
                lines.append("\(bodyIndent)        \(action)")
                lines.append("\(bodyIndent)        set foundCount to foundCount + 1")
                lines.append("\(bodyIndent)    end repeat")
                lines.append("\(bodyIndent)end try")
            }
            if !closeGuard.isEmpty { lines.append(closeGuard) }
        }
        return lines.map { indent + $0 }.joined(separator: "\n")
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
    /// Emits the full script + output to the Unified Log so debugging
    /// "Mark as Read silently failed" doesn't require code changes —
    /// `log show --predicate 'subsystem == "FMail.MailScripter"' --last 5m`.
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
                let started = Date()
                do {
                    try process.run()
                    process.waitUntilExit()
                    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let elapsed = Date().timeIntervalSince(started)
                    fputs("[FMail.MailScripter] (\(String(format: "%.1fs", elapsed)), exit \(process.terminationStatus)) stdout=\(out.trimmingCharacters(in: .whitespacesAndNewlines)) stderr=\(err.trimmingCharacters(in: .whitespacesAndNewlines))\n", stderr)
                    continuation.resume(returning: (out, err, process.terminationStatus))
                } catch {
                    continuation.resume(returning: ("", error.localizedDescription, -1))
                }
            }
        }
    }

    // MARK: — Diagnostics

    /// Returns a human-readable dump of Mail.app's account / mailbox
    /// hierarchy (top-level + one nested level). Useful when "Mark as
    /// Read" silently fails — we can compare what FMail thinks the
    /// mailbox path is against what Mail.app actually exposes via
    /// AppleScript. No write side effects.
    static func diagnoseStructure() async -> String {
        let source = """
        with timeout of 60 seconds
            tell application "Mail"
                set output to ""
                repeat with acc in accounts
                    try
                        set output to output & "Account: " & (name of acc) & return
                    end try
                    try
                        set output to output & "  emails: " & ((email addresses of acc) as string) & return
                    end try
                    try
                        repeat with mbox1 in (mailboxes of acc)
                            try
                                set output to output & "  mailbox: " & (name of mbox1) & return
                            end try
                            try
                                repeat with mbox2 in (mailboxes of mbox1)
                                    try
                                        set output to output & "    submailbox: " & (name of mbox2) & return
                                    end try
                                end repeat
                            end try
                        end repeat
                    end try
                end repeat
                return output
            end tell
        end timeout
        """
        let (stdout, stderr, exitCode) = await runOsascript(source)
        if exitCode != 0 {
            return "Diagnostic failed (exit \(exitCode)): \(stderr.isEmpty ? stdout : stderr)"
        }
        return stdout
    }
}

private extension Array {
    /// Splits the array into sub-arrays of at most `size` elements. The
    /// final sub-array may be shorter. `chunked(into: 5)` on a 12-element
    /// array yields three sub-arrays of sizes 5, 5, 2.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
