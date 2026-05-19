import XCTest
@testable import FMail

/// Verifies the `body_format: "clean"` cleanup passes — reply-chain
/// truncation, signature truncation, tracking-URL collapse, blank-line
/// squash. Targeted at the patterns seen in real Savills / Outlook /
/// Apple Mail threads that motivated the feature.
final class BodyCleanerTests: XCTestCase {

    // MARK: — Reply-chain truncation

    func testTruncatesAtOnWroteMarker() {
        let body = """
            Sure, can do.

            > On 12 May 2026, at 14:32, Anna <anna@example.com> wrote:
            >
            > Are you free for a call?
            """
        let cleaned = BodyCleaner.clean(body)
        XCTAssertEqual(cleaned, "Sure, can do.")
    }

    func testTruncatesAtOriginalMessageBanner() {
        let body = """
            Confirming receipt.

            -----Original Message-----
            From: Anna
            Sent: Monday

            Are we still on for lunch?
            """
        let cleaned = BodyCleaner.clean(body)
        XCTAssertEqual(cleaned, "Confirming receipt.")
    }

    func testTruncatesAtOutlookQuotedHeader() {
        let body = """
            See attached.

            From: Anna <anna@example.com>
            Sent: Monday, 12 May 2026 14:32
            To: Felix
            Subject: Re: contract

            Original message body
            """
        let cleaned = BodyCleaner.clean(body)
        XCTAssertEqual(cleaned, "See attached.")
    }

    func testDoesNotTruncateOnStandaloneOnLine() {
        // "On Monday I'm out" is not a reply marker — it lacks "wrote:"
        let body = """
            Quick update.

            On Monday I'm out of office; talk Tuesday?
            """
        let cleaned = BodyCleaner.clean(body)
        XCTAssertTrue(cleaned.contains("On Monday I'm out"))
    }

    // MARK: — Signature truncation

    func testTruncatesAtDoubleDashSeparator() {
        let body = """
            Cheers,
            Felix

            --
            Felix Matschke
            +1 555 1234
            """
        let cleaned = BodyCleaner.clean(body)
        XCTAssertEqual(cleaned, "Cheers,\nFelix")
    }

    func testTruncatesAtSentFromIPhone() {
        let body = """
            Sounds good.

            Sent from my iPhone
            """
        let cleaned = BodyCleaner.clean(body)
        XCTAssertEqual(cleaned, "Sounds good.")
    }

    func testTruncatesAtGetOutlookForIOS() {
        let body = """
            Got it.

            Get Outlook for iOS
            """
        let cleaned = BodyCleaner.clean(body)
        XCTAssertEqual(cleaned, "Got it.")
    }

    // MARK: — Tracking-URL collapse

    func testCollapsesMimecastURLs() {
        let body = "Click here: https://report.mimecastcybergraph.com/abcdef/long-tracking-payload-tokens"
        let cleaned = BodyCleaner.clean(body)
        XCTAssertTrue(cleaned.contains("[mimecast-link]"))
        XCTAssertFalse(cleaned.contains("mimecastcybergraph.com"))
    }

    func testCollapsesOutlookSafelinks() {
        let body = "Visit https://nam04.safelinks.protection.outlook.com/?url=https%3A%2F%2Fexample.com&data=abc&xyz=tracking"
        let cleaned = BodyCleaner.clean(body)
        XCTAssertTrue(cleaned.contains("[safelink]"))
    }

    func testLeavesShortHttpsURLsAlone() {
        let body = "See https://example.com for details."
        let cleaned = BodyCleaner.clean(body)
        XCTAssertTrue(cleaned.contains("https://example.com"))
    }

    // MARK: — Blank-line collapse

    func testCollapsesRunsOfBlankLines() {
        let body = "Hello.\n\n\n\n\nWorld."
        let cleaned = BodyCleaner.clean(body)
        XCTAssertEqual(cleaned, "Hello.\n\nWorld.")
    }

    // MARK: — Combined real-world pattern

    func testHandlesThreadedReplyWithSignatureAndTracking() {
        let body = """
            Yes please.

            Cheers,
            Felix

            --
            Felix Matschke

            > On 12 May 2026, Anna wrote:
            > Could you confirm? Click https://report.mimecastcybergraph.com/abcdef/xx
            >
            > -----Original Message-----
            > Old message…
            """
        let cleaned = BodyCleaner.clean(body)
        XCTAssertEqual(cleaned, "Yes please.\n\nCheers,\nFelix")
    }
}
