import XCTest
@testable import FMail

/// Pure-logic coverage for `Indexer.normalizeSubject`, the threading fallback
/// key. Regressions here silently mis-group threads, so the Re:/Fwd: stripping
/// and whitespace/case normalization are worth pinning down.
final class IndexerTests: XCTestCase {

    func testStripsSingleReplyPrefix() {
        XCTAssertEqual(Indexer.normalizeSubject("Re: Hello"), "hello")
        XCTAssertEqual(Indexer.normalizeSubject("Fwd: Hello"), "hello")
        XCTAssertEqual(Indexer.normalizeSubject("FW: Hello"), "hello")
    }

    func testStripsNestedPrefixes() {
        XCTAssertEqual(Indexer.normalizeSubject("Re: Fwd: Hello World"), "hello world")
        XCTAssertEqual(Indexer.normalizeSubject("Re:Re:Re: deep"), "deep")
    }

    func testHandlesSpacedColonVariants() {
        XCTAssertEqual(Indexer.normalizeSubject("Re : spaced"), "spaced")
        XCTAssertEqual(Indexer.normalizeSubject("FW : note"), "note")
    }

    func testCollapsesWhitespaceAndLowercases() {
        XCTAssertEqual(Indexer.normalizeSubject("  Quarterly   REVIEW  "), "quarterly review")
    }

    func testLeavesPlainSubjectIntact() {
        XCTAssertEqual(Indexer.normalizeSubject("Invoice 2026"), "invoice 2026")
    }

    /// "Reference…" must not be mistaken for a "Re:" prefix.
    func testDoesNotStripFalsePositivePrefix() {
        XCTAssertEqual(Indexer.normalizeSubject("Reference attached"), "reference attached")
        XCTAssertEqual(Indexer.normalizeSubject("Fwded thoughts"), "fwded thoughts")
    }

    func testEmptyAndPrefixOnly() {
        XCTAssertEqual(Indexer.normalizeSubject(""), "")
        XCTAssertEqual(Indexer.normalizeSubject("Re: "), "")
    }
}
