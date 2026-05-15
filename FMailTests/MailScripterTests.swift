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

    // (Junk-action tests removed when AppleScriptWritebackService.moveToJunk
    //  was hard-failed. macOS Tahoe broke the underlying `junk mailbox of
    //  <account>` AppleScript property for every account in practice;
    //  authorize Gmail via OAuth or wait for IMAP support instead. The
    //  whole moveToJunkBatch + moveToJunkAction code path is gone.
    //  setReadStatus and delete via AppleScript are still tested below.)

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
        // Regression: makeLookupBlock originally only indented the first
        // line of a multi-line action, dumping the rest at column 0 —
        // compiles in AppleScript but unreadable. Fix indents every line.
        // Use a synthetic multi-line action so this test outlives the
        // junk-specific code that motivated it.
        let action = """
        try
            set junk mail status of msg to true
        end try
        if true then
            move msg to mbox
        end if
        """
        let source = MailScripter.buildScriptSource(
            entries: [gmailEntry()],
            accountScopedAction: action,
            crossAccountAction: action
        )
        guard let s = source else { XCTFail("nil script"); return }
        // Every non-blank line from the action should be at some indent
        // ≥ 8 spaces (the makeLookupBlock body indent) inside the
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
