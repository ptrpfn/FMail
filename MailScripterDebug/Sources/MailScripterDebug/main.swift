import Foundation

// MailScripterDebug — a side CLI tool to test Mail.app AppleScript
// behavior in isolation. Run via `swift run MailScripterDebug <subcommand>`.
// Subcommands:
//   list                                — dump every account + mailbox name
//   peek --subject "<s>" [--account e]  — find a message by subject, print
//                                         its `id`, `message id`, read status,
//                                         and which mailbox it lives in. Use
//                                         this to learn what Mail.app's `id`
//                                         actually is (IMAP UID? Mail rowid?).
//   find  [--rfc <id>] [--uid <n>] [--account <e>]
//                                       — try every lookup variant against
//                                         every account+mailbox+sub-mailbox;
//                                         report which combinations find the
//                                         message.
//   mark  [--rfc <id>] [--uid <n>] [--account <e>] (--read|--unread)
//                                       — mark a message; immediately re-read
//                                         to verify the flag actually flipped.
//                                         Reports BEFORE / AFTER read status.
//   raw   "<script>"                    — run an arbitrary AppleScript snippet
//                                         and print stdout/stderr/exit code.

// MARK: — AppleScript runner

@discardableResult
func runScript(_ source: String, timeoutSec: Int = 120) -> (stdout: String, stderr: String, code: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", source]
    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do {
        try p.run()
        p.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (out, err, p.terminationStatus)
    } catch {
        return ("", error.localizedDescription, -1)
    }
}

func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "\"", with: "\\\"")
}

// MARK: — list

func listStructure() {
    // Email addresses are concatenated with ", " for readability.
    let script = """
    with timeout of 60 seconds
        tell application "Mail"
            set output to ""
            repeat with acc in accounts
                try
                    set emailsList to (email addresses of acc)
                    set emailsStr to ""
                    repeat with e in emailsList
                        if emailsStr is "" then
                            set emailsStr to (e as string)
                        else
                            set emailsStr to emailsStr & ", " & (e as string)
                        end if
                    end repeat
                    set output to output & "ACCOUNT: " & (name of acc) & " [" & emailsStr & "]" & linefeed
                end try
                try
                    repeat with mbox1 in (mailboxes of acc)
                        try
                            set output to output & "  MAILBOX: " & (name of mbox1) & linefeed
                        end try
                        try
                            repeat with mbox2 in (mailboxes of mbox1)
                                try
                                    set output to output & "    SUBMAILBOX: " & (name of mbox2) & linefeed
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
    let r = runScript(script)
    if r.code != 0 {
        FileHandle.standardError.write(Data("FAILED (exit \(r.code)): \(r.stderr)\n".utf8))
        exit(1)
    }
    print(r.stdout, terminator: "")
}

// MARK: — peek

func peek(subject: String, account: String?) {
    let escSubj = escape(subject)
    let accountClause: String
    if let account {
        accountClause = """
            set theAcc to missing value
            repeat with acc in accounts
                try
                    if (email addresses of acc) contains "\(escape(account))" then
                        set theAcc to acc
                        exit repeat
                    end if
                end try
            end repeat
            if theAcc is missing value then return "(account not found)"
            set acctList to {theAcc}
        """
    } else {
        accountClause = """
            set acctList to accounts
        """
    }
    let script = """
    with timeout of 120 seconds
        tell application "Mail"
            \(accountClause)
            set output to ""
            set hits to 0
            repeat with acc in acctList
                try
                    set acctName to (name of acc)
                    repeat with mbox in (mailboxes of acc)
                        try
                            set msgs to (messages of mbox whose subject contains "\(escSubj)")
                            repeat with msg in msgs
                                try
                                    set output to output & acctName & " > " & (name of mbox) & ¬
                                        " | id=" & (id of msg) & ¬
                                        " | message id=" & (message id of msg) & ¬
                                        " | read=" & (read status of msg) & ¬
                                        " | subject=" & (subject of msg) & linefeed
                                    set hits to hits + 1
                                end try
                            end repeat
                        end try
                        try
                            repeat with submbox in (mailboxes of mbox)
                                try
                                    set msgs to (messages of submbox whose subject contains "\(escSubj)")
                                    repeat with msg in msgs
                                        try
                                            set output to output & acctName & " > " & (name of mbox) & " > " & (name of submbox) & ¬
                                                " | id=" & (id of msg) & ¬
                                                " | message id=" & (message id of msg) & ¬
                                                " | read=" & (read status of msg) & ¬
                                                " | subject=" & (subject of msg) & linefeed
                                            set hits to hits + 1
                                        end try
                                    end repeat
                                end try
                            end repeat
                        end try
                    end repeat
                end try
            end repeat
            if hits is 0 then
                return "(no matches)"
            end if
            return output
        end tell
    end timeout
    """
    let r = runScript(script)
    if r.code != 0 {
        FileHandle.standardError.write(Data("FAILED (exit \(r.code)): \(r.stderr)\n".utf8))
        exit(1)
    }
    print(r.stdout, terminator: "")
}

// MARK: — find

/// For each account (filtered or all), walks every mailbox + 1 nested
/// level and tries each lookup form. Reports every match with the
/// account + mailbox + which lookup found it.
func find(rfc: String?, uid: Int?, account: String?) {
    let stripped = (rfc ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    let bracketed = stripped.isEmpty ? "" : "<\(stripped)>"

    let accountClause: String
    if let account {
        accountClause = """
            set theAcc to missing value
            repeat with acc in accounts
                try
                    if (email addresses of acc) contains "\(escape(account))" then
                        set theAcc to acc
                        exit repeat
                    end if
                end try
            end repeat
            if theAcc is missing value then return "(account not found)"
            set acctList to {theAcc}
        """
    } else {
        accountClause = "set acctList to accounts"
    }

    // Each lookup is a try-block. We use both `(name of mbox)` and `(name of acc)` for
    // reporting context. `mbox` is the active mailbox in scope.
    var lookups: [String] = []
    if let uid {
        lookups.append("""
                    try
                        set matches to (messages of mbox whose id is \(uid))
                        repeat with msg in matches
                            try
                                set output to output & "  HIT (whose id is \(uid)): " & (name of acc) & " > " & mboxLabel & ¬
                                    " | message id=" & (message id of msg) & ¬
                                    " | read=" & (read status of msg) & linefeed
                                set hits to hits + 1
                            end try
                        end repeat
                    end try
        """)
    }
    if !bracketed.isEmpty {
        lookups.append("""
                    try
                        set matches to (messages of mbox whose message id is "\(escape(bracketed))")
                        repeat with msg in matches
                            try
                                set output to output & "  HIT (msg id bracketed): " & (name of acc) & " > " & mboxLabel & ¬
                                    " | id=" & (id of msg) & ¬
                                    " | read=" & (read status of msg) & linefeed
                                set hits to hits + 1
                            end try
                        end repeat
                    end try
        """)
    }
    if !stripped.isEmpty {
        lookups.append("""
                    try
                        set matches to (messages of mbox whose message id is "\(escape(stripped))")
                        repeat with msg in matches
                            try
                                set output to output & "  HIT (msg id stripped): " & (name of acc) & " > " & mboxLabel & ¬
                                    " | id=" & (id of msg) & ¬
                                    " | read=" & (read status of msg) & linefeed
                                set hits to hits + 1
                            end try
                        end repeat
                    end try
        """)
    }
    let lookupBlock = lookups.joined(separator: "\n")

    let script = """
    with timeout of 600 seconds
        tell application "Mail"
            \(accountClause)
            set output to ""
            set hits to 0
            repeat with acc in acctList
                try
                    repeat with topMbox in (mailboxes of acc)
                        set mbox to topMbox
                        set mboxLabel to (name of mbox)
    \(lookupBlock)
                        try
                            repeat with submbox in (mailboxes of topMbox)
                                set mbox to submbox
                                set mboxLabel to ((name of topMbox) & " > " & (name of submbox))
    \(lookupBlock)
                            end repeat
                        end try
                    end repeat
                end try
            end repeat
            if hits is 0 then
                return "(no matches via any lookup)"
            end if
            return output
        end tell
    end timeout
    """
    let r = runScript(script, timeoutSec: 600)
    if r.code != 0 {
        FileHandle.standardError.write(Data("FAILED (exit \(r.code)): \(r.stderr)\n".utf8))
        exit(1)
    }
    print(r.stdout, terminator: "")
}

// MARK: — mark (with verification)

/// Marks a message read/unread, then re-reads the read status via a
/// fresh AppleScript invocation to verify it actually persisted in
/// Mail.app's store (not just in the in-memory reference we wrote to).
func mark(rfc: String?, uid: Int?, account: String?, makeRead: Bool) {
    let stripped = (rfc ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    let bracketed = stripped.isEmpty ? "" : "<\(stripped)>"
    let readBool = makeRead ? "true" : "false"

    let accountClause: String
    if let account {
        accountClause = """
            set theAcc to missing value
            repeat with acc in accounts
                try
                    if (email addresses of acc) contains "\(escape(account))" then
                        set theAcc to acc
                        exit repeat
                    end if
                end try
            end repeat
            if theAcc is missing value then return "(account not found)"
            set acctList to {theAcc}
        """
    } else {
        accountClause = "set acctList to accounts"
    }

    // Step 1: find each match, capture BEFORE read status and a stable
    // reference (account name + mailbox name + message id), set the new
    // read status, then capture AFTER status by re-fetching via the same
    // path. We DON'T trust the original `msg` reference for AFTER —
    // that's the point of verification: re-find and re-read.
    var lookupAndFlip: [String] = []
    if let uid {
        lookupAndFlip.append("""
                    try
                        set matches to (messages of mbox whose id is \(uid))
                        repeat with msg in matches
                            try
                                set beforeRead to (read status of msg)
                                set msgIdProp to (message id of msg)
                                set read status of msg to \(readBool)
                                set afterImmediate to (read status of msg)
                                -- Re-fetch via id and re-read to confirm persistence.
                                set verifyMatches to (messages of mbox whose id is \(uid))
                                set verifyRead to "no-match"
                                repeat with vm in verifyMatches
                                    set verifyRead to (read status of vm) as string
                                end repeat
                                set output to output & "FLIP via uid \(uid): " & (name of acc) & " > " & mboxLabel & ¬
                                    " | message id=" & msgIdProp & ¬
                                    " | before=" & beforeRead & ¬
                                    " | immediate=" & afterImmediate & ¬
                                    " | verify-refetch=" & verifyRead & linefeed
                                set hits to hits + 1
                            end try
                        end repeat
                    end try
        """)
    }
    if !bracketed.isEmpty {
        lookupAndFlip.append("""
                    try
                        set matches to (messages of mbox whose message id is "\(escape(bracketed))")
                        repeat with msg in matches
                            try
                                set beforeRead to (read status of msg)
                                set msgIdProp to (id of msg)
                                set read status of msg to \(readBool)
                                set afterImmediate to (read status of msg)
                                set verifyMatches to (messages of mbox whose message id is "\(escape(bracketed))")
                                set verifyRead to "no-match"
                                repeat with vm in verifyMatches
                                    set verifyRead to (read status of vm) as string
                                end repeat
                                set output to output & "FLIP via msgid bracketed: " & (name of acc) & " > " & mboxLabel & ¬
                                    " | id=" & msgIdProp & ¬
                                    " | before=" & beforeRead & ¬
                                    " | immediate=" & afterImmediate & ¬
                                    " | verify-refetch=" & verifyRead & linefeed
                                set hits to hits + 1
                            end try
                        end repeat
                    end try
        """)
    }
    if !stripped.isEmpty {
        lookupAndFlip.append("""
                    try
                        set matches to (messages of mbox whose message id is "\(escape(stripped))")
                        repeat with msg in matches
                            try
                                set beforeRead to (read status of msg)
                                set msgIdProp to (id of msg)
                                set read status of msg to \(readBool)
                                set afterImmediate to (read status of msg)
                                set verifyMatches to (messages of mbox whose message id is "\(escape(stripped))")
                                set verifyRead to "no-match"
                                repeat with vm in verifyMatches
                                    set verifyRead to (read status of vm) as string
                                end repeat
                                set output to output & "FLIP via msgid stripped: " & (name of acc) & " > " & mboxLabel & ¬
                                    " | id=" & msgIdProp & ¬
                                    " | before=" & beforeRead & ¬
                                    " | immediate=" & afterImmediate & ¬
                                    " | verify-refetch=" & verifyRead & linefeed
                                set hits to hits + 1
                            end try
                        end repeat
                    end try
        """)
    }
    let lookupBlock = lookupAndFlip.joined(separator: "\n")

    let script = """
    with timeout of 600 seconds
        tell application "Mail"
            \(accountClause)
            set output to ""
            set hits to 0
            repeat with acc in acctList
                try
                    repeat with topMbox in (mailboxes of acc)
                        set mbox to topMbox
                        set mboxLabel to (name of mbox)
    \(lookupBlock)
                        try
                            repeat with submbox in (mailboxes of topMbox)
                                set mbox to submbox
                                set mboxLabel to ((name of topMbox) & " > " & (name of submbox))
    \(lookupBlock)
                            end repeat
                        end try
                    end repeat
                end try
            end repeat
            if hits is 0 then
                return "(no message matched any lookup form — nothing flipped)"
            end if
            return output
        end tell
    end timeout
    """
    let r = runScript(script, timeoutSec: 600)
    if r.code != 0 {
        FileHandle.standardError.write(Data("FAILED (exit \(r.code)): \(r.stderr)\n".utf8))
        exit(1)
    }
    print(r.stdout, terminator: "")

    // Independent second-script verification: settle for ~3 seconds, then
    // re-query using a totally fresh osascript invocation. If Mail.app's
    // first-script "verify-refetch" lied (cached in-memory but not persisted),
    // this catches it.
    print("\n--- waiting 3s for Mail.app to settle, then independent verify ---")
    Thread.sleep(forTimeInterval: 3.0)
    var verifyLookups: [String] = []
    if let uid {
        verifyLookups.append("""
                    try
                        set matches to (messages of mbox whose id is \(uid))
                        repeat with msg in matches
                            try
                                set output to output & "VERIFY (uid): " & (name of acc) & " > " & mboxLabel & " | read=" & (read status of msg) & linefeed
                            end try
                        end repeat
                    end try
        """)
    }
    if !bracketed.isEmpty {
        verifyLookups.append("""
                    try
                        set matches to (messages of mbox whose message id is "\(escape(bracketed))")
                        repeat with msg in matches
                            try
                                set output to output & "VERIFY (msgid bracketed): " & (name of acc) & " > " & mboxLabel & " | read=" & (read status of msg) & linefeed
                            end try
                        end repeat
                    end try
        """)
    }
    let verifyBlock = verifyLookups.joined(separator: "\n")
    let verifyScript = """
    with timeout of 300 seconds
        tell application "Mail"
            \(accountClause)
            set output to ""
            repeat with acc in acctList
                try
                    repeat with topMbox in (mailboxes of acc)
                        set mbox to topMbox
                        set mboxLabel to (name of mbox)
    \(verifyBlock)
                        try
                            repeat with submbox in (mailboxes of topMbox)
                                set mbox to submbox
                                set mboxLabel to ((name of topMbox) & " > " & (name of submbox))
    \(verifyBlock)
                            end repeat
                        end try
                    end repeat
                end try
            end repeat
            if output is "" then return "(no matches on independent verify — message gone?)"
            return output
        end tell
    end timeout
    """
    let v = runScript(verifyScript, timeoutSec: 300)
    if v.code != 0 {
        FileHandle.standardError.write(Data("Independent verify FAILED (exit \(v.code)): \(v.stderr)\n".utf8))
    } else {
        print(v.stdout, terminator: "")
    }
}

// MARK: — raw

func raw(source: String) {
    let r = runScript(source)
    print("--- stdout ---")
    print(r.stdout)
    print("--- stderr ---")
    print(r.stderr)
    print("--- exit \(r.code) ---")
}

// MARK: — argv parsing

let args = Array(CommandLine.arguments.dropFirst())

func argValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func hasFlag(_ name: String) -> Bool {
    args.contains(name)
}

guard let cmd = args.first else {
    print("""
    Usage:
      list
      peek --subject "<s>" [--account <email>]
      find [--rfc <id>] [--uid <n>] [--account <email>]
      mark [--rfc <id>] [--uid <n>] [--account <email>] (--read | --unread)
      raw "<applescript source>"

    Examples:
      swift run MailScripterDebug list
      swift run MailScripterDebug peek --subject "school trip" --account felix.matschke@gmail.com
      swift run MailScripterDebug find --rfc "<abc@gmail.com>" --account felix.matschke@gmail.com
      swift run MailScripterDebug mark --rfc "abc@gmail.com" --account felix.matschke@gmail.com --read
    """)
    exit(1)
}

switch cmd {
case "list":
    listStructure()
case "peek":
    guard let s = argValue("--subject") else {
        FileHandle.standardError.write(Data("Need --subject\n".utf8))
        exit(1)
    }
    peek(subject: s, account: argValue("--account"))
case "find":
    let rfc = argValue("--rfc")
    let uid = argValue("--uid").flatMap(Int.init)
    if rfc == nil && uid == nil {
        FileHandle.standardError.write(Data("Need at least one of --rfc or --uid\n".utf8))
        exit(1)
    }
    find(rfc: rfc, uid: uid, account: argValue("--account"))
case "mark":
    let rfc = argValue("--rfc")
    let uid = argValue("--uid").flatMap(Int.init)
    if rfc == nil && uid == nil {
        FileHandle.standardError.write(Data("Need at least one of --rfc or --uid\n".utf8))
        exit(1)
    }
    let r = hasFlag("--read")
    let u = hasFlag("--unread")
    if r == u {
        FileHandle.standardError.write(Data("Need exactly one of --read or --unread\n".utf8))
        exit(1)
    }
    mark(rfc: rfc, uid: uid, account: argValue("--account"), makeRead: r)
case "raw":
    guard args.count >= 2 else {
        FileHandle.standardError.write(Data("Need a script argument after `raw`\n".utf8))
        exit(1)
    }
    raw(source: args[1])
default:
    FileHandle.standardError.write(Data("Unknown command: \(cmd)\n".utf8))
    exit(1)
}
