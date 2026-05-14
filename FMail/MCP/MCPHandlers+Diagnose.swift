import Foundation

/// `diagnose_junk_mailboxes` — read-only AppleScript that asks Mail.app
/// directly what it considers each account's junk mailbox. Useful when
/// `move_to_junk` silently no-ops: tells us whether the failure is "our
/// script picked the wrong target" vs "Mail.app reports no junk mailbox
/// at all for this account, and the fallback name search didn't find one
/// either."
extension MCPHandlers {

    static func diagnoseJunkMailboxes(_ args: JSONValue, context: MCPContext) async throws -> JSONValue {
        _ = args  // no inputs
        _ = context  // doesn't touch the index; AppleScript directly
        let output = await MailScripter.diagnoseJunkMailboxes()
        return .object([
            "output": .string(output)
        ])
    }
}
