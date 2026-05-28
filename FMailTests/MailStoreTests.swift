import XCTest
@testable import FMail

/// Pure-helper tests for the MailStore layer — no Mail.app, no FDA. Cover the
/// URL parsing, sidebar hiding rules, and version-directory selection that the
/// production reader relies on.
final class MailStoreTests: XCTestCase {

    // MARK: — MailboxURL.parse

    func testParseImapURL() {
        let parsed = MailboxURL.parse("imap://ACCT-UUID/INBOX")
        XCTAssertEqual(parsed?.accountUUID, "ACCT-UUID")
        XCTAssertEqual(parsed?.pathComponents, ["INBOX"])
    }

    func testParseNestedPathIsPercentDecoded() {
        let parsed = MailboxURL.parse("imap://ACCT/Work/Q1%20Reports")
        XCTAssertEqual(parsed?.accountUUID, "ACCT")
        XCTAssertEqual(parsed?.pathComponents, ["Work", "Q1 Reports"])
    }

    /// `URLComponents` chokes on the unescaped `[` in Gmail's `[Gmail]`
    /// container — the fallback parser must still recover host + path.
    func testParseGmailBracketFallback() {
        let parsed = MailboxURL.parse("imap://ACCT-UUID/[Gmail]/All Mail")
        XCTAssertEqual(parsed?.accountUUID, "ACCT-UUID")
        XCTAssertEqual(parsed?.pathComponents, ["[Gmail]", "All Mail"])
    }

    func testParseHostOnlyHasEmptyPath() {
        let parsed = MailboxURL.parse("local-only://LOCAL-ACCT")
        XCTAssertEqual(parsed?.accountUUID, "LOCAL-ACCT")
        XCTAssertEqual(parsed?.pathComponents, [])
    }

    func testParseRejectsSchemeless() {
        XCTAssertNil(MailboxURL.parse("not-a-url"))
    }

    // MARK: — MailboxFilter.isHiddenByDefault

    func testGmailAllMailIsHidden() {
        XCTAssertTrue(MailboxFilter.isHiddenByDefault(pathComponents: ["[Gmail]", "All Mail"]))
    }

    func testRecoveredMessagesIsHidden() {
        XCTAssertTrue(MailboxFilter.isHiddenByDefault(pathComponents: ["Recovered Messages"]))
        XCTAssertTrue(MailboxFilter.isHiddenByDefault(pathComponents: ["Recovered Messages (Gmail)"]))
    }

    func testSendLaterIsHidden() {
        XCTAssertTrue(MailboxFilter.isHiddenByDefault(pathComponents: ["SendLater"]))
    }

    func testRegularMailboxesAreVisible() {
        XCTAssertFalse(MailboxFilter.isHiddenByDefault(pathComponents: ["INBOX"]))
        XCTAssertFalse(MailboxFilter.isHiddenByDefault(pathComponents: ["[Gmail]", "Sent Mail"]))
        // "All Mail" not under "[Gmail]" is a normal user folder.
        XCTAssertFalse(MailboxFilter.isHiddenByDefault(pathComponents: ["All Mail"]))
        XCTAssertFalse(MailboxFilter.isHiddenByDefault(pathComponents: []))
    }

    // MARK: — MailStoreEnumerator.currentMailVersionDirectory

    func testPicksHighestVersionDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FMailEnumTests-\(UUID().uuidString)")
        let fm = FileManager.default
        for name in ["V1", "V7", "V10", "MailData", "NotVersioned"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: root) }

        let result = MailStoreEnumerator.currentMailVersionDirectory(in: root)
        XCTAssertEqual(result?.lastPathComponent, "V10",
                       "Highest numeric V<N> wins, not lexicographic (V7 > V10 lexically).")
    }

    func testReturnsNilWhenNoVersionDirectories() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FMailEnumTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("MailData"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(MailStoreEnumerator.currentMailVersionDirectory(in: root))
    }

    func testReturnsNilForMissingRoot() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FMailEnumTests-does-not-exist-\(UUID().uuidString)")
        XCTAssertNil(MailStoreEnumerator.currentMailVersionDirectory(in: root))
    }
}
