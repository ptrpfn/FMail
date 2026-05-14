import XCTest
@testable import FMail

/// Tests for `MailScripter.buildScriptSource` and the per-action script
/// pieces. These don't invoke Mail.app — they verify that the AppleScript
/// text we generate contains the right commands and fallback logic.
///
/// Background: the user reported that `move_to_junk` silently failed for
/// a message in `[Gmail]/All Mail`. The script at the time was a single
/// statement (`set mailbox of msg to junk mailbox of theAccount`) with no
/// fallback when `junk mailbox of <account>` returned `missing value`.
/// These tests pin the new robust shape:
///   1. set junk mail status of msg to true   (always succeeds, fast, local)
///   2. try junk mailbox of <account>
///   3. if missing, walk mailboxes by name (Spam / Junk / variants)
///   4. set mailbox of msg to tgtMbox
final class MailScripterTests: XCTestCase {

    // MARK: — Fixture

    private func gmailEntry(rowId: Int = 100, account: String = "felix@gmail.com") -> MailScripter.BatchEntry {
        MailScripter.BatchEntry(
            rfcMessageId: "<msg-\(rowId)@example.com>",
            appleRowId: rowId,
            accountEmail: account,
            mailboxPathComponents: ["[Gmail]", "All Mail"]
        )
    }

    private func icloudEntry(rowId: Int = 200) -> MailScripter.BatchEntry {
        MailScripter.BatchEntry(
            rfcMessageId: "<msg-\(rowId)@me.com>",
            appleRowId: rowId,
            accountEmail: "felix@icloud.com",
            mailboxPathComponents: ["INBOX"]
        )
    }

    private func fallbackEntry(rowId: Int = 300) -> MailScripter.BatchEntry {
        // No account / mailbox info → routed to cross-account fallback.
        MailScripter.BatchEntry(
            rfcMessageId: "<msg-\(rowId)@example.com>",
            appleRowId: rowId,
            accountEmail: nil,
            mailboxPathComponents: nil
        )
    }

    // MARK: — Junk action shape

    func testMoveToJunkActionSetsJunkStatusFirst() {
        let action = MailScripter.moveToJunkAction(accountVar: "theAccount")
        XCTAssertTrue(
            action.contains("set junk mail status of msg to true"),
            "junk action must always flag the message — this is fast, local, and trains Gmail's filter even when the subsequent move fails. Action was:\n\(action)"
        )
    }

    func testMoveToJunkActionWrapsJunkStatusInTry() {
        // Without the try, a failure on `set junk mail status` bubbles out
        // of `repeat with msg in matches` and skips `set foundCount + 1`,
        // making the script silently report notFound.
        let action = MailScripter.moveToJunkAction(accountVar: "theAccount")
        let lines = action.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let statusIdx = lines.firstIndex(of: "set junk mail status of msg to true") else {
            return XCTFail("status line missing:\n\(action)")
        }
        XCTAssertEqual(lines[statusIdx - 1], "try", "expected `try` immediately before status set")
        XCTAssertEqual(lines[statusIdx + 1], "end try", "expected `end try` immediately after status set")
    }

    // (Was `testMoveToJunkActionWrapsMoveInIgnoringApplicationResponses` —
    //  the wrap turned out to silently drop the move when osascript
    //  terminated first. Replaced by
    //  `testMoveToJunkActionDoesNotUseIgnoringApplicationResponses`.)

    func testMoveToJunkActionWalksMailboxesByName() {
        let action = MailScripter.moveToJunkAction(accountVar: "theAccount")
        XCTAssertTrue(action.contains("repeat with cMbox in (mailboxes of theAccount)"))
        // Common spam/junk mailbox names we expect to recognise.
        XCTAssertTrue(action.contains("\"Spam\""), "must check for `Spam` (Gmail's leaf name)")
        XCTAssertTrue(action.contains("\"Junk\""), "must check for `Junk` (iCloud / generic)")
        XCTAssertTrue(action.contains("\"[Gmail]/Spam\""), "must check the slash-joined form Gmail accounts sometimes expose")
    }

    func testMoveToJunkActionUsesNameWalkBeforeProperty() {
        // The `junk mailbox of <account>` property is unreliable — verified
        // via diagnose_junk_mailboxes that it errors for every account in
        // some Mail.app setups. So name-walk should run FIRST; the property
        // is the last-resort fallback when no name matches.
        let action = MailScripter.moveToJunkAction(accountVar: "theAccount")
        guard
            let walkRange = action.range(of: "repeat with cMbox in (mailboxes of theAccount)"),
            let propertyRange = action.range(of: "set tgtMbox to junk mailbox of theAccount")
        else { return XCTFail("expected both walk and property in action:\n\(action)") }
        XCTAssertLessThan(
            walkRange.lowerBound, propertyRange.lowerBound,
            "name walk must appear before the property lookup — the property is unreliable; walking is the safer first attempt."
        )
    }

    func testMoveToJunkActionStillTriesAccountJunkMailboxAsFallback() {
        // Even though the property is unreliable for some users, we still
        // try it last in case the user's setup has Junk in an unrecognized
        // name but the property works.
        let action = MailScripter.moveToJunkAction(accountVar: "theAccount")
        XCTAssertTrue(
            action.contains("set tgtMbox to junk mailbox of theAccount"),
            "junk action must still try `junk mailbox of <account>` as a last-resort fallback"
        )
        // And the property is only attempted when the walk didn't find a match.
        XCTAssertTrue(
            action.contains("if tgtMbox is missing value"),
            "the property fallback must be gated on the walk having found nothing"
        )
    }

    func testMoveToJunkActionDoesTheActualMoveLast() {
        let action = MailScripter.moveToJunkAction(accountVar: "theAccount")
        XCTAssertTrue(
            action.contains("move msg to tgtMbox"),
            "junk action must perform the actual move via `move msg to tgtMbox` once tgtMbox is resolved. Action was:\n\(action)"
        )
    }

    func testMoveToJunkActionDoesNotUseIgnoringApplicationResponses() {
        // We tried wrapping the move in `ignoring application responses` to
        // make the AppleScript return fast — but the move silently no-op'd
        // because Mail.app's AppleEvent queue drops the event when osascript
        // terminates first. The script returned `applied: N` but messages
        // stayed in their source mailbox. We accept slower MCP responses in
        // exchange for moves that actually happen.
        let action = MailScripter.moveToJunkAction(accountVar: "theAccount")
        XCTAssertFalse(
            action.contains("ignoring application responses"),
            "must NOT wrap the move in `ignoring application responses` — it silently no-ops on Mail.app's side. Action was:\n\(action)"
        )
    }

    func testMoveToJunkActionUsesMoveVerbNotSetMailbox() {
        // `move` is the canonical AppleScript verb for cross-mailbox moves
        // and is more reliable for Gmail's label-based store than the
        // equivalent `set mailbox of msg to <mbox>` assignment.
        let action = MailScripter.moveToJunkAction(accountVar: "theAccount")
        XCTAssertTrue(action.contains("move msg to tgtMbox"))
        XCTAssertFalse(
            action.contains("set mailbox of msg"),
            "use the `move` verb, not the `set mailbox of msg to <mbox>` form"
        )
    }

    func testMoveToJunkActionReferencesCorrectAccountVariable() {
        let theAccount = MailScripter.moveToJunkAction(accountVar: "theAccount")
        XCTAssertTrue(theAccount.contains("junk mailbox of theAccount"))
        XCTAssertFalse(theAccount.contains("junk mailbox of anAccount"))

        let anAccount = MailScripter.moveToJunkAction(accountVar: "anAccount")
        XCTAssertTrue(anAccount.contains("junk mailbox of anAccount"))
        XCTAssertFalse(anAccount.contains("junk mailbox of theAccount"))
    }

    // MARK: — Whole-script construction

    func testJunkScriptIncludesAccountScopedBlockForGmail() {
        let source = MailScripter.buildScriptSource(
            entries: [gmailEntry()],
            accountScopedAction: MailScripter.moveToJunkAction(accountVar: "theAccount"),
            crossAccountAction: MailScripter.moveToJunkAction(accountVar: "anAccount")
        )
        let s = try? XCTUnwrap(source)
        XCTAssertNotNil(s)
        guard let s else { return }
        // The Gmail account scoping should land in the account-scoped block.
        XCTAssertTrue(s.contains("email addresses of acc) contains \"felix@gmail.com\""))
        // Should target both leaf and slash-joined names of [Gmail]/All Mail.
        XCTAssertTrue(s.contains("\"All Mail\""))
        XCTAssertTrue(s.contains("\"[Gmail]/All Mail\""))
        // Junk action must be expanded inline.
        XCTAssertTrue(s.contains("set junk mail status of msg to true"))
        XCTAssertTrue(s.contains("set tgtMbox to junk mailbox of theAccount"))
        // Foundation: foundCount tracking + return.
        XCTAssertTrue(s.contains("set foundCount to 0"))
        XCTAssertTrue(s.contains("return foundCount"))
        // 10-min internal timeout still in place.
        XCTAssertTrue(s.contains("with timeout of 600 seconds"))
    }

    func testJunkScriptIncludesCrossAccountFallbackWhenAccountInfoMissing() {
        let source = MailScripter.buildScriptSource(
            entries: [fallbackEntry()],
            accountScopedAction: MailScripter.moveToJunkAction(accountVar: "theAccount"),
            crossAccountAction: MailScripter.moveToJunkAction(accountVar: "anAccount")
        )
        let s = try? XCTUnwrap(source)
        XCTAssertNotNil(s)
        guard let s else { return }
        // Cross-account fallback iterates `accounts`.
        XCTAssertTrue(s.contains("repeat with anAccount in accounts"))
        // Action variant references `anAccount` not `theAccount`.
        XCTAssertTrue(s.contains("set tgtMbox to junk mailbox of anAccount"))
        XCTAssertFalse(s.contains("set tgtMbox to junk mailbox of theAccount"),
                       "fallback-only script shouldn't contain the theAccount variant")
    }

    func testJunkScriptIncludesBothBranchesForMixedEntries() {
        // Mixed: one Gmail entry (account-scoped), one with no info (fallback).
        let source = MailScripter.buildScriptSource(
            entries: [gmailEntry(rowId: 100), fallbackEntry(rowId: 300)],
            accountScopedAction: MailScripter.moveToJunkAction(accountVar: "theAccount"),
            crossAccountAction: MailScripter.moveToJunkAction(accountVar: "anAccount")
        )
        let s = try? XCTUnwrap(source)
        guard let s else { return }
        XCTAssertTrue(s.contains("set tgtMbox to junk mailbox of theAccount"))
        XCTAssertTrue(s.contains("set tgtMbox to junk mailbox of anAccount"))
        XCTAssertTrue(s.contains("repeat with anAccount in accounts"))
    }

    func testJunkScriptGroupsMultipleEntriesInSameMailbox() {
        // Three messages from the same Gmail All Mail mailbox — should
        // produce ONE per-mailbox scan with `id = 100 or id = 101 or id = 102`,
        // not three separate scans.
        let entries = [
            gmailEntry(rowId: 100),
            gmailEntry(rowId: 101),
            gmailEntry(rowId: 102)
        ]
        let source = MailScripter.buildScriptSource(
            entries: entries,
            accountScopedAction: MailScripter.moveToJunkAction(accountVar: "theAccount"),
            crossAccountAction: MailScripter.moveToJunkAction(accountVar: "anAccount")
        )
        let s = try? XCTUnwrap(source)
        guard let s else { return }
        // The OR-chain should appear in the script (chunked at 5 IDs).
        XCTAssertTrue(s.contains("id = 100 or id = 101 or id = 102"))
    }

    // MARK: — Delete still works for all mailboxes

    func testDeleteScriptHasSimpleAction() {
        let source = MailScripter.buildScriptSource(
            entries: [gmailEntry(), icloudEntry()],
            accountScopedAction: "delete msg",
            crossAccountAction: "delete msg"
        )
        let s = try? XCTUnwrap(source)
        guard let s else { return }
        XCTAssertTrue(s.contains("delete msg"))
        // Both account groups represented.
        XCTAssertTrue(s.contains("felix@gmail.com"))
        XCTAssertTrue(s.contains("felix@icloud.com"))
    }

    func testReadStatusScriptHasReadStatusAction() {
        let source = MailScripter.buildScriptSource(
            entries: [gmailEntry()],
            accountScopedAction: "set read status of msg to true",
            crossAccountAction: "set read status of msg to true"
        )
        let s = try? XCTUnwrap(source)
        guard let s else { return }
        XCTAssertTrue(s.contains("set read status of msg to true"))
    }

    // MARK: — Empty / malformed input

    func testBuildScriptSourceReturnsNilForEmptyEntries() {
        let source = MailScripter.buildScriptSource(
            entries: [],
            accountScopedAction: "delete msg",
            crossAccountAction: "delete msg"
        )
        XCTAssertNil(source)
    }

    // MARK: — Multi-line action indentation

    func testMultiLineActionPreservesAllLinesInsideRepeatLoop() {
        // Regression: when actions grew from a single line to multi-line
        // (junk), `makeLookupBlock` originally only indented the first line,
        // dumping the rest at column 0 — which compiles in AppleScript but
        // makes the output unreadable and risks accidental wrong-scope.
        // The fix indents every line; assert by inspection.
        let action = MailScripter.moveToJunkAction(accountVar: "theAccount")
        let source = MailScripter.buildScriptSource(
            entries: [gmailEntry()],
            accountScopedAction: action,
            crossAccountAction: action
        )
        guard let s = source else { XCTFail("nil script"); return }
        // Every non-blank line from the junk action should be at some
        // indent ≥ 8 spaces (the makeLookupBlock body indent) inside the
        // script. Find the first occurrence and walk forward.
        let actionLines = action
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        for line in actionLines {
            // Match should appear as " <indent>line " — look for a line
            // ending with the same content, indented.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            XCTAssertTrue(
                s.contains("        \(trimmed)") || s.contains("    \(trimmed)"),
                "action line not indented inside script:\n  expected to find an indented `\(trimmed)`\n  script:\n\(s)"
            )
        }
    }
}
