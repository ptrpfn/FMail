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

    // MARK: — Public API

    /// Asks Mail.app to load the message bodies for the given entries.
    /// Reads `source of msg` for each, which is the AppleScript-visible
    /// trigger that forces Mail.app to fetch the body over IMAP/Gmail-API
    /// if it isn't already on disk. Fire-and-forget — we don't care about
    /// the source text, only the side effect (Mail.app writes the .emlx).
    /// FSEventStream picks up the new file and our BodyIndexer reads it.
    static func fetchBodies(_ entries: [BatchEntry]) async {
        guard !entries.isEmpty else { return }
        let bucketed = bucketByMailbox(entries)
        guard !bucketed.groups.isEmpty else { return }

        let blocks = bucketed.groups.values.map { group in
            buildAccountScopedBlock(
                group: group,
                action: "set _ to source of msg",
                withFallbackWalk: false
            )
        }

        // foundCount is referenced by makeLookupBlock to short-circuit slow
        // Message-ID scans. We don't read it back here (fire-and-forget).
        let source = """
        with timeout of 600 seconds
            tell application "Mail"
                set foundCount to 0
                \(blocks.joined(separator: "\n"))
            end tell
        end timeout
        """
        _ = await runOsascript(source)
    }

    /// Mark many messages read/unread with a SINGLE osascript invocation.
    /// Entries are grouped by `(accountEmail, mailboxPath)`; each group
    /// scans its mailbox exactly once with `whose id is …`, so even a
    /// 100-message batch in one Gmail mailbox is one linear scan instead
    /// of 100. Falls through to the broad-walk path for entries that
    /// don't have account/mailbox info.
    static func setReadStatusBatch(_ entries: [BatchEntry], isRead: Bool) async -> Result {
        let v = isRead ? "true" : "false"
        return await runActionBatch(
            entries: entries,
            accountScopedAction: "set read status of msg to \(v)",
            crossAccountAction: "set read status of msg to \(v)"
        )
    }

    /// Delete a batch of messages — Mail.app's `delete msg` moves them to
    /// the Trash mailbox of the relevant account (matches the Delete key
    /// behaviour in Mail.app's UI). Same per-mailbox bucketing pattern as
    /// `setReadStatusBatch`.
    static func deleteBatch(_ entries: [BatchEntry]) async -> Result {
        await runActionBatch(
            entries: entries,
            accountScopedAction: "delete msg",
            crossAccountAction: "delete msg"
        )
    }

    /// Move a batch of messages to the Junk (Spam) mailbox of their
    /// account. Three-step action so it's resilient to Mail.app accounts
    /// where `junk mailbox of <account>` returns `missing value` (observed
    /// for some Gmail setups — symptom is move-to-junk silently no-ops):
    ///   1. `set junk mail status of msg to true` — fast, local, always
    ///      works, also trains Gmail's spam filter.
    ///   2. Try `junk mailbox of <account>`; if missing, walk
    ///      `mailboxes of <account>` looking for a name match against
    ///      "Spam" / "Junk" / common Gmail variants.
    ///   3. `set mailbox of msg to tgtMbox` — the actual move.
    /// The action references the account variable in scope, which differs
    /// between the account-scoped block (`theAccount`) and the cross-account
    /// fallback (`anAccount`).
    static func moveToJunkBatch(_ entries: [BatchEntry]) async -> Result {
        await runActionBatch(
            entries: entries,
            accountScopedAction: moveToJunkAction(accountVar: "theAccount"),
            crossAccountAction: moveToJunkAction(accountVar: "anAccount")
        )
    }

    /// The multi-line "move to junk" AppleScript action, parameterized on
    /// which AppleScript variable holds the account reference at the call
    /// site. Internal for testability — see `MailScripterTests`.
    ///
    /// Decisions, in the order we learned them the hard way:
    ///   1. `set junk mail status` is wrapped in `try` so a failure there
    ///      (e.g. a read-only Gmail label view) doesn't bubble out of the
    ///      outer `repeat with msg in matches` and skip the foundCount
    ///      increment.
    ///   2. Name walk runs FIRST; `junk mailbox of <account>` only as last
    ///      resort. The `junk mailbox` property is unreliable: verified via
    ///      `diagnose_junk_mailboxes` that it errors for every account in
    ///      some Mail.app configurations (macOS Tahoe).
    ///   3. **No `ignoring application responses`**. We tried wrapping the
    ///      move to make the script return fast — turned out Mail.app's
    ///      AppleEvent queue drops the move when osascript terminates
    ///      before it processes the event, so the script reported `applied:N`
    ///      but messages stayed in their source mailbox. Trade-off: the MCP
    ///      call now blocks until Mail.app finishes the IMAP MOVE (5–30s per
    ///      message, more for big batches), and may exceed the LLM client's
    ///      HTTP timeout — but the move actually completes on Mail.app's
    ///      side. The tool description tells the LLM to expect this and
    ///      verify via `search_emails` after a delay.
    ///   4. `move msg to tgtMbox` instead of `set mailbox of msg to tgtMbox`.
    ///      Both are documented as equivalent but `move` is the canonical
    ///      verb for cross-mailbox moves and appears to be more reliable
    ///      for Gmail's label-based store.
    static func moveToJunkAction(accountVar: String) -> String {
        """
        try
            set junk mail status of msg to true
        end try
        set tgtMbox to missing value
        try
            repeat with cMbox in (mailboxes of \(accountVar))
                try
                    set cName to name of cMbox
                    if cName is "Spam" or cName is "Junk" or cName is "Spam mail" or cName is "Bulk Mail" or cName is "[Gmail]/Spam" then
                        set tgtMbox to cMbox
                        exit repeat
                    end if
                end try
            end repeat
        end try
        if tgtMbox is missing value then
            try
                set tgtMbox to junk mailbox of \(accountVar)
            end try
        end if
        if tgtMbox is not missing value then
            try
                move msg to tgtMbox
            end try
        end if
        """
    }

    // MARK: — Shared scaffold

    /// Common AppleScript runner for any per-message action that follows
    /// the bucket-by-mailbox pattern. The two action strings cover the two
    /// in-scope account-variable contexts:
    ///   - `accountScopedAction` runs inside `buildAccountScopedBlock`,
    ///     where `theAccount` is bound.
    ///   - `crossAccountAction` runs inside `buildCrossAccountFallback`,
    ///     where `anAccount` is the loop variable.
    /// Most actions don't reference the account at all (mark-read, delete);
    /// pass the same string for both. Junk needs different strings.
    private static func runActionBatch(
        entries: [BatchEntry],
        accountScopedAction: String,
        crossAccountAction: String
    ) async -> Result {
        guard let source = buildScriptSource(
            entries: entries,
            accountScopedAction: accountScopedAction,
            crossAccountAction: crossAccountAction
        ) else { return .notFound }

        let (stdout, stderr, exitCode) = await runOsascript(source)
        if exitCode != 0 {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = detail.isEmpty ? stdout : detail
            return .failed("osascript exit \(exitCode): \(body)")
        }
        let count = Int(stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return count > 0 ? .ok(matched: count) : .notFound
    }

    /// Builds the full osascript source for one batch. Internal so tests
    /// can verify the emitted script contains the expected commands and
    /// fallback logic. Returns nil when there's nothing to do (`entries`
    /// empty, or none had enough info to be addressable).
    static func buildScriptSource(
        entries: [BatchEntry],
        accountScopedAction: String,
        crossAccountAction: String
    ) -> String? {
        guard !entries.isEmpty else { return nil }
        let bucketed = bucketByMailbox(entries)

        var blocks: [String] = bucketed.groups.values.map { group in
            buildAccountScopedBlock(group: group, action: accountScopedAction, withFallbackWalk: true)
        }
        if let fallback = buildCrossAccountFallback(
            uids: bucketed.fallbackUIDs,
            rfcIds: bucketed.fallbackRfcIds,
            action: crossAccountAction
        ) {
            blocks.append(fallback)
        }
        guard !blocks.isEmpty else { return nil }

        return """
        with timeout of 600 seconds
            tell application "Mail"
                set foundCount to 0
                \(blocks.joined(separator: "\n"))
                return foundCount
            end tell
        end timeout
        """
    }

    // MARK: — Bucketing

    private struct GroupKey: Hashable {
        let email: String
        let pathKey: String
    }

    private struct Group {
        let email: String
        let path: [String]
        var uids: [Int] = []
        var rfcIds: [String] = []
    }

    private struct BucketedEntries {
        let groups: [GroupKey: Group]
        let fallbackUIDs: [Int]
        let fallbackRfcIds: [String]
    }

    /// Bucket entries by `(accountEmail, mailboxPath)` so each Mail.app
    /// mailbox is scanned exactly once. Entries without account+path info
    /// land in the fallback arrays (used by setReadStatusBatch only).
    /// RFC Message-IDs are added in both bracketed and stripped forms —
    /// Mail.app's `message id` property has been observed to return either,
    /// and idempotent set on the same message twice is harmless.
    private static func bucketByMailbox(_ entries: [BatchEntry]) -> BucketedEntries {
        var groups: [GroupKey: Group] = [:]
        var fallbackUIDs: [Int] = []
        var fallbackRfcIds: [String] = []

        for e in entries {
            let stripped = e.rfcMessageId
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            let bracketed = stripped.isEmpty ? "" : "<\(stripped)>"
            let hasUID = e.appleRowId != nil
            let hasRfc = !stripped.isEmpty
            guard hasUID || hasRfc else { continue }

            if let email = e.accountEmail, !email.isEmpty,
               let path = e.mailboxPathComponents, !path.isEmpty {
                let key = GroupKey(email: email, pathKey: path.joined(separator: "/"))
                var group = groups[key] ?? Group(email: email, path: path)
                if let uid = e.appleRowId { group.uids.append(uid) }
                if !bracketed.isEmpty { group.rfcIds.append(bracketed) }
                if !stripped.isEmpty { group.rfcIds.append(stripped) }
                groups[key] = group
            } else {
                if let uid = e.appleRowId { fallbackUIDs.append(uid) }
                if !bracketed.isEmpty { fallbackRfcIds.append(bracketed) }
                if !stripped.isEmpty { fallbackRfcIds.append(stripped) }
            }
        }
        return BucketedEntries(groups: groups, fallbackUIDs: fallbackUIDs, fallbackRfcIds: fallbackRfcIds)
    }

    // MARK: — Script construction

    /// AppleScript snippet for one targeted `(account, mailbox-path)` group.
    /// Resolves the account by email, then iterates `(mailboxes of acct
    /// whose name = X or name = Y)` so Mail.app evaluates the filter once
    /// and returns a resolved list — empirically 30s → 8s for an 8-message
    /// batch in `All Mail` vs. iterating every mailbox.
    ///
    /// `withFallbackWalk: true` adds a brute-walk fallback that scans every
    /// mailbox + one nested level when the targeted name-match misses.
    /// Used by setReadStatusBatch (fetchBodies just gives up if missed).
    private static func buildAccountScopedBlock(
        group: Group,
        action: String,
        withFallbackWalk: Bool
    ) -> String {
        let escapedEmail = appleScriptEscape(group.email)
        let nameCondition = mailboxNameCandidates(pathComponents: group.path)
            .map { "name = \"\(appleScriptEscape($0))\"" }
            .joined(separator: " or ")
        let inner = makeLookupBlock(
            uids: group.uids,
            rfcIds: group.rfcIds,
            mailboxRef: "mbox",
            action: action,
            indent: "                                "
        )

        if !withFallbackWalk {
            return """
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
                            set candidates to (mailboxes of theAccount whose \(nameCondition))
                            repeat with mbox in candidates
                                try
            \(inner)
                                end try
                            end repeat
                        end try
                    end if
                end try
            """
        }

        let fallbackBody = makeLookupBlock(
            uids: group.uids,
            rfcIds: group.rfcIds,
            mailboxRef: "mbox",
            action: action,
            indent: "                                            "
        )
        return """
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
                    try
                        set candidates to (mailboxes of theAccount whose \(nameCondition))
                        repeat with mbox in candidates
                            try
        \(inner)
                            end try
                        end repeat
                    end try
                    if foundCount = countBefore then
                        -- Targeted name-match found nothing — fall back to
                        -- walking every mailbox of the account plus one
                        -- nested level. Slow but only triggers on miss.
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
        """
    }

    /// Cross-account walk for entries that lacked account+mailbox info.
    /// Returns nil if there's nothing to fall back to.
    private static func buildCrossAccountFallback(
        uids: [Int],
        rfcIds: [String],
        action: String
    ) -> String? {
        guard !uids.isEmpty || !rfcIds.isEmpty else { return nil }
        var inner: [String] = []
        if !uids.isEmpty {
            let lit = uids.map(String.init).joined(separator: ", ")
            inner.append("""
                                    set fallbackUIDs to {\(lit)}
                                    repeat with aUID in fallbackUIDs
                                        try
                                            set matches to (messages of mbox whose id is aUID)
                                            repeat with msg in matches
                                                \(action)
                                                set foundCount to foundCount + 1
                                            end repeat
                                        end try
                                    end repeat
            """)
        }
        if !rfcIds.isEmpty {
            let lit = rfcIds.map { "\"\(appleScriptEscape($0))\"" }.joined(separator: ", ")
            inner.append("""
                                    set fallbackMsgIds to {\(lit)}
                                    repeat with aMsgId in fallbackMsgIds
                                        try
                                            set matches to (messages of mbox whose message id is aMsgId)
                                            repeat with msg in matches
                                                \(action)
                                                set foundCount to foundCount + 1
                                            end repeat
                                        end try
                                    end repeat
            """)
        }
        return """
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
        """
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

        // Multi-line actions (e.g. the junk script: set status + lookup +
        // move) need every line indented to the same level as the surrounding
        // `repeat with msg in matches` body, not just the first.
        let actionLines = action
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

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
                for actLine in actionLines {
                    lines.append("        \(actLine)")
                }
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
                for actLine in actionLines {
                    lines.append("\(bodyIndent)        \(actLine)")
                }
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
                    let outTrim = out.trimmingCharacters(in: .whitespacesAndNewlines)
                    let errTrim = err.trimmingCharacters(in: .whitespacesAndNewlines)
                    Log.mailScripter.info("(\(String(format: "%.1fs", elapsed)), exit \(process.terminationStatus)) stdout=\(outTrim, privacy: .public) stderr=\(errTrim, privacy: .public)")
                    continuation.resume(returning: (out, err, process.terminationStatus))
                } catch {
                    continuation.resume(returning: ("", error.localizedDescription, -1))
                }
            }
        }
    }

    // MARK: — Diagnostics

    /// For each Mail.app account, report: account name; what
    /// `junk mailbox of acc` resolves to (or "missing value"); the names of
    /// all mailboxes whose name suggests Spam/Junk. Useful when Move to
    /// Junk silently fails — tells us whether the bug is in our script
    /// (`junk mailbox` returned something we didn't expect) or in Mail.app
    /// (no junk mailbox configured at all). No write side effects.
    static func diagnoseJunkMailboxes() async -> String {
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
                    set junkName to "(missing value)"
                    try
                        set junkName to name of (junk mailbox of acc)
                    on error errMsg
                        set junkName to "(error: " & errMsg & ")"
                    end try
                    set output to output & "  junk mailbox of acc → " & junkName & return
                    try
                        repeat with m in (mailboxes of acc)
                            try
                                set nm to name of m
                                if (nm is "Spam") or (nm is "Junk") or (nm is "Spam mail") or (nm is "Bulk Mail") or nm contains "Spam" or nm contains "Junk" then
                                    set output to output & "  candidate mailbox: " & nm & return
                                end if
                            end try
                        end repeat
                    end try
                    try
                        repeat with m1 in (mailboxes of acc)
                            try
                                repeat with m2 in (mailboxes of m1)
                                    try
                                        set nm2 to name of m2
                                        if (nm2 is "Spam") or (nm2 is "Junk") or nm2 contains "Spam" or nm2 contains "Junk" then
                                            set output to output & "  nested candidate: " & (name of m1) & "/" & nm2 & return
                                        end if
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
