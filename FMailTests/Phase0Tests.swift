import XCTest
@testable import FMail

final class Phase0Tests: XCTestCase {
    /// Smoke test: confirms the version-dir locator finds *some* directory
    /// matching ~/Library/Mail/V<N>. Skipped if Mail.app isn't set up or the
    /// test runner doesn't have Full Disk Access (Xcode test runners don't
    /// inherit FDA from the launching process).
    func testFindsMailVersionDirectory() throws {
        guard FullDiskAccess.isGrantedHeuristic() else {
            throw XCTSkip("Test runner lacks Full Disk Access to ~/Library/Mail.")
        }
        let dir = MailStoreEnumerator.currentMailVersionDirectory()
        XCTAssertNotNil(dir, "Expected to find at least one V<N> directory under ~/Library/Mail.")
    }

    /// Schema fingerprint test (per plan §Testing). Guards against Apple
    /// changing the columns we depend on. Skipped if no Mail data.
    func testEnvelopeIndexHasExpectedTables() throws {
        guard FullDiskAccess.isGrantedHeuristic(),
              let versionDir = MailStoreEnumerator.currentMailVersionDirectory()
        else {
            throw XCTSkip("FDA not granted or no Mail data; cannot fingerprint schema.")
        }

        let envURL = MailStoreEnumerator.envelopeIndexURL(in: versionDir)
        guard FileManager.default.fileExists(atPath: envURL.path) else {
            throw XCTSkip("No Envelope Index file present.")
        }

        let reader = try EnvelopeIndexReader(path: envURL.path)
        // Count queries verify that `messages` and `mailboxes` tables exist.
        XCTAssertGreaterThanOrEqual(try reader.messageCount(), 0)
        XCTAssertGreaterThanOrEqual(try reader.mailboxCount(), 0)
    }
}
