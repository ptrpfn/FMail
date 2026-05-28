import XCTest
@testable import FMail

/// Verifies `BodyLoader.fillExternalAttachments` against a synthetic copy of
/// Mail.app's on-disk layout for Gmail accounts: a `.partial.emlx` with
/// `X-Apple-Content-Length` placeholders and the real bytes living in a
/// sibling `Attachments/<rowid>/<partIdx>/<filename>` tree.
final class BodyLoaderTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FMailBodyLoaderTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        super.tearDown()
    }

    // MARK: — Helpers

    private func makeFixture(
        accountUUID: String = "TEST-ACCOUNT-UUID",
        rowId: Int,
        rfc822: String,
        attachments: [(partIdx: Int, filename: String, bytes: Data)]
    ) throws -> Mailbox {
        // Path: <versionDir>/<account>/INBOX.mbox/<uuid>/Data/0/0/0/Messages|Attachments/...
        let mboxRoot = tempRoot
            .appendingPathComponent(accountUUID)
            .appendingPathComponent("INBOX.mbox")
            .appendingPathComponent("MAILBOX-UUID")
            .appendingPathComponent("Data")
            .appendingPathComponent("0")
            .appendingPathComponent("0")
            .appendingPathComponent("0")
        let messagesDir = mboxRoot.appendingPathComponent("Messages")
        let attRoot = mboxRoot.appendingPathComponent("Attachments").appendingPathComponent(String(rowId))
        try FileManager.default.createDirectory(at: messagesDir, withIntermediateDirectories: true)

        // .emlx framing: decimal byte length + LF + RFC822 message.
        let rfcData = rfc822.data(using: .utf8)!
        let framed = "\(rfcData.count)\n".data(using: .ascii)! + rfcData
        try framed.write(to: messagesDir.appendingPathComponent("\(rowId).partial.emlx"))

        for att in attachments {
            let partDir = attRoot.appendingPathComponent(String(att.partIdx))
            try FileManager.default.createDirectory(at: partDir, withIntermediateDirectories: true)
            try att.bytes.write(to: partDir.appendingPathComponent(att.filename))
        }

        return Mailbox(
            rowId: 1,
            accountUUID: accountUUID,
            pathComponents: ["INBOX"],
            totalCount: 1,
            unreadCount: 0,
            hidden: false,
            kind: .inbox
        )
    }

    // MARK: — Tests

    /// Plain `filename="..."` attachment: BodyLoader must fill the empty
    /// MIME-parsed payload from the on-disk Attachments dir.
    func testFillsExternalAttachmentByFilename() async throws {
        let rowId = 42
        let attBytes = Data("HELLO-PDF-BYTES".utf8)
        let rfc822 = """
            From: a@example.com
            To: b@example.com
            Subject: t
            Content-Type: multipart/mixed; boundary="bdry"

            --bdry
            Content-Type: text/plain; charset=utf-8

            Body text.
            --bdry
            Content-Disposition: attachment; filename="simple.pdf"
            Content-Type: application/pdf
            X-Apple-Content-Length: \(attBytes.count)


            --bdry--

            """
        let mailbox = try makeFixture(
            rowId: rowId,
            rfc822: rfc822,
            attachments: [(partIdx: 2, filename: "simple.pdf", bytes: attBytes)]
        )

        let loader = BodyLoader(mailVersionDir: tempRoot)
        let body = try await loader.loadBody(messageRowId: rowId, mailbox: mailbox)
        let unwrapped = try XCTUnwrap(body)

        XCTAssertEqual(unwrapped.attachments.count, 1)
        let att = try XCTUnwrap(unwrapped.attachments.first)
        XCTAssertEqual(att.name, "simple.pdf")
        XCTAssertEqual(att.contentType, "application/pdf")
        XCTAssertEqual(att.data, attBytes)
    }

    /// RFC 2231 `filename*0=...; filename*1=...` continuations: the MIME
    /// parser must reassemble the name so the disk lookup succeeds.
    func testFillsExternalAttachmentForRFC2231Filename() async throws {
        let rowId = 43
        let fullName = "very_long_filename_segment_one_segment_two.pdf"
        let attBytes = Data(repeating: 0xAB, count: 17)
        let rfc822 = """
            From: a@example.com
            To: b@example.com
            Subject: t
            Content-Type: multipart/mixed; boundary="bdry"

            --bdry
            Content-Type: text/plain; charset=utf-8

            Body.
            --bdry
            Content-Disposition: attachment;
            \tfilename*0=very_long_filename_segment_one_;
            \tfilename*1=segment_two.pdf
            Content-Type: application/pdf
            X-Apple-Content-Length: \(attBytes.count)


            --bdry--

            """
        let mailbox = try makeFixture(
            rowId: rowId,
            rfc822: rfc822,
            attachments: [(partIdx: 2, filename: fullName, bytes: attBytes)]
        )

        let loader = BodyLoader(mailVersionDir: tempRoot)
        let body = try await loader.loadBody(messageRowId: rowId, mailbox: mailbox)
        let unwrapped = try XCTUnwrap(body)

        XCTAssertEqual(unwrapped.attachments.count, 1, "Expected one attachment from the stripped part")
        let att = try XCTUnwrap(unwrapped.attachments.first)
        XCTAssertEqual(att.name, fullName, "RFC 2231 continuation must be reassembled")
        XCTAssertEqual(att.data, attBytes, "Bytes must come from the external Attachments dir")
    }

    /// Multiple attachments with distinct filenames — both filled by name.
    /// Matches the real Tredegar-AGM case (three PDFs across part indices 2,3,4).
    func testFillsMultipleExternalAttachments() async throws {
        let rowId = 44
        let a1 = Data("AAAAA".utf8)
        let a2 = Data("BBBBBB".utf8)
        let a3 = Data("CCCCCCC".utf8)
        let rfc822 = """
            From: a@example.com
            To: b@example.com
            Subject: t
            Content-Type: multipart/mixed; boundary="bdry"

            --bdry
            Content-Type: text/plain; charset=utf-8

            Body.
            --bdry
            Content-Disposition: attachment; filename="first.pdf"
            Content-Type: application/pdf
            X-Apple-Content-Length: \(a1.count)


            --bdry
            Content-Disposition: attachment; filename="second.pdf"
            Content-Type: application/pdf
            X-Apple-Content-Length: \(a2.count)


            --bdry
            Content-Disposition: attachment; filename="third.pdf"
            Content-Type: application/pdf
            X-Apple-Content-Length: \(a3.count)


            --bdry--

            """
        let mailbox = try makeFixture(
            rowId: rowId,
            rfc822: rfc822,
            attachments: [
                (partIdx: 2, filename: "first.pdf", bytes: a1),
                (partIdx: 3, filename: "second.pdf", bytes: a2),
                (partIdx: 4, filename: "third.pdf", bytes: a3)
            ]
        )

        let loader = BodyLoader(mailVersionDir: tempRoot)
        let body = try await loader.loadBody(messageRowId: rowId, mailbox: mailbox)
        let unwrapped = try XCTUnwrap(body)
        XCTAssertEqual(unwrapped.attachments.count, 3)
        let byName = Dictionary(uniqueKeysWithValues: unwrapped.attachments.map { ($0.name, $0.data) })
        XCTAssertEqual(byName["first.pdf"], a1)
        XCTAssertEqual(byName["second.pdf"], a2)
        XCTAssertEqual(byName["third.pdf"], a3)
    }

    /// A message that arrives AFTER a mailbox's emlx map is first cached is
    /// invisible until `invalidateAll()` drops the stale map. Regression test
    /// for the cache-staleness bug (BodyLoader never self-refreshes; the sync
    /// path must invalidate it).
    func testInvalidateAllPicksUpNewlyArrivedMessage() async throws {
        let mailbox = try makeFixture(
            rowId: 100,
            rfc822: "From: a@example.com\nSubject: first\n\nBody one.\n",
            attachments: []
        )
        let loader = BodyLoader(mailVersionDir: tempRoot)

        // Prime the cache for this mailbox.
        _ = try await loader.loadBody(messageRowId: 100, mailbox: mailbox)

        // A new message lands on disk in the same mailbox after caching.
        let messagesDir = tempRoot
            .appendingPathComponent(mailbox.accountUUID)
            .appendingPathComponent("INBOX.mbox")
            .appendingPathComponent("MAILBOX-UUID")
            .appendingPathComponent("Data").appendingPathComponent("0")
            .appendingPathComponent("0").appendingPathComponent("0")
            .appendingPathComponent("Messages")
        let rfc = "From: b@example.com\nSubject: second\n\nBody two.\n"
        let rfcData = Data(rfc.utf8)
        let framed = Data("\(rfcData.count)\n".utf8) + rfcData
        try framed.write(to: messagesDir.appendingPathComponent("101.emlx"))

        // Stale cache: the new message is not found.
        let stale = try await loader.loadBody(messageRowId: 101, mailbox: mailbox)
        XCTAssertNil(stale, "Stale per-mailbox cache should not see the new file yet")

        // After invalidation the rescan finds it.
        await loader.invalidateAll()
        let fresh = try await loader.loadBody(messageRowId: 101, mailbox: mailbox)
        let body = try XCTUnwrap(fresh, "invalidateAll() should let the rescan find the new message")
        XCTAssertEqual(body.displayText.trimmingCharacters(in: .whitespacesAndNewlines), "Body two.")
    }

    /// A `.partial.emlx` cached before its full `.emlx` lands keeps resolving
    /// to the partial until `invalidateAll()`; afterwards the full body wins.
    func testInvalidateAllUpgradesPartialToFull() async throws {
        let rowId = 102
        let mailbox = try makeFixture(
            rowId: rowId,
            rfc822: "From: a@example.com\nSubject: t\n\nPARTIAL body.\n",
            attachments: []
        )
        let loader = BodyLoader(mailVersionDir: tempRoot)
        let partial = try await loader.loadBody(messageRowId: rowId, mailbox: mailbox)
        XCTAssertEqual(
            try XCTUnwrap(partial).displayText.trimmingCharacters(in: .whitespacesAndNewlines),
            "PARTIAL body."
        )

        // Full body lands; full always wins over partial once the map rebuilds.
        let messagesDir = tempRoot
            .appendingPathComponent(mailbox.accountUUID)
            .appendingPathComponent("INBOX.mbox")
            .appendingPathComponent("MAILBOX-UUID")
            .appendingPathComponent("Data").appendingPathComponent("0")
            .appendingPathComponent("0").appendingPathComponent("0")
            .appendingPathComponent("Messages")
        let rfc = "From: a@example.com\nSubject: t\n\nFULL body.\n"
        let rfcData = Data(rfc.utf8)
        let framed = Data("\(rfcData.count)\n".utf8) + rfcData
        try framed.write(to: messagesDir.appendingPathComponent("\(rowId).emlx"))

        await loader.invalidateAll()
        let full = try await loader.loadBody(messageRowId: rowId, mailbox: mailbox)
        XCTAssertEqual(
            try XCTUnwrap(full).displayText.trimmingCharacters(in: .whitespacesAndNewlines),
            "FULL body.",
            "After invalidation, the full .emlx should replace the .partial.emlx"
        )
    }

    /// Inline attachment whose bytes ARE in the emlx (no X-Apple-Content-Length)
    /// must not be clobbered by the external-attachment fill pass.
    func testInlineAttachmentBytesArePreserved() async throws {
        let rowId = 45
        // Base64 of "INLINE!" — fits one line.
        let inlineB64 = Data("INLINE!".utf8).base64EncodedString()
        let rfc822 = """
            From: a@example.com
            To: b@example.com
            Subject: t
            Content-Type: multipart/mixed; boundary="bdry"

            --bdry
            Content-Type: text/plain; charset=utf-8

            Body.
            --bdry
            Content-Disposition: attachment; filename="inline.bin"
            Content-Type: application/octet-stream
            Content-Transfer-Encoding: base64

            \(inlineB64)
            --bdry--

            """
        // No external file on disk — the inline bytes must survive untouched.
        let mailbox = try makeFixture(rowId: rowId, rfc822: rfc822, attachments: [])

        let loader = BodyLoader(mailVersionDir: tempRoot)
        let body = try await loader.loadBody(messageRowId: rowId, mailbox: mailbox)
        let unwrapped = try XCTUnwrap(body)
        XCTAssertEqual(unwrapped.attachments.count, 1)
        XCTAssertEqual(unwrapped.attachments[0].name, "inline.bin")
        XCTAssertEqual(unwrapped.attachments[0].data, Data("INLINE!".utf8))
    }
}
