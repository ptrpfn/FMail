import Foundation

/// Handles `.emlx` body lookup + parsing. Per-mailbox `rowid -> URL` map is
/// built lazily on first body lookup for that mailbox; subsequent lookups in
/// the same session are O(1).
actor BodyLoader {
    private let mailVersionDir: URL

    private var mboxDirCache: [Int: URL] = [:]
    private var emlxIndexByMailbox: [Int: [Int: URL]] = [:]

    init(mailVersionDir: URL) {
        self.mailVersionDir = mailVersionDir
    }

    func loadBody(messageRowId: Int, mailbox: Mailbox) throws -> MessageBody? {
        let mboxURL = mailboxDiskURL(for: mailbox)
        let map = try indexEmlxFiles(in: mailbox.rowId, dir: mboxURL)
        guard let url = map[messageRowId] else { return nil }

        let parsed = try EmlxParser.parse(url: url)
        let attachments = Self.fillExternalAttachments(
            parsed.mime.attachments,
            emlxURL: url,
            messageRowId: messageRowId
        )
        return MessageBody(
            headers: parsed.headers,
            plainText: parsed.mime.plainText,
            html: parsed.mime.html,
            attachments: attachments
        )
    }

    /// For Gmail / IMAP messages, Mail.app commonly stores attachment bytes
    /// out-of-line in `<dataDir>/Attachments/<rowid>/<partIdx>/<filename>`
    /// and strips them from the `.partial.emlx` (leaving an
    /// `X-Apple-Content-Length: NNN` header as a placeholder). The MIME
    /// parser then sees the part headers but produces an `Attachment` with
    /// zero data bytes — which is no good for MCP clients trying to read
    /// the actual file.
    ///
    /// This pass enumerates the on-disk Attachments directory and pairs up
    /// any zero-byte attachment with its file by filename. The fallback —
    /// when filenames don't match (corrupted index, unusual MIME shapes) —
    /// walks the disk files in part-index order and fills the remaining
    /// zero-byte attachments in MIME-traversal order, which matches IMAP
    /// part numbering for the common multipart/mixed layout.
    private static func fillExternalAttachments(_ attachments: [Attachment], emlxURL: URL, messageRowId: Int) -> [Attachment] {
        guard attachments.contains(where: { $0.data.isEmpty }) else { return attachments }

        // emlxURL = <dataDir>/Messages/<rowid>(.partial)?.emlx
        // attachments root = <dataDir>/Attachments/<rowid>/
        let dataDir = emlxURL.deletingLastPathComponent().deletingLastPathComponent()
        let attRoot = dataDir
            .appendingPathComponent("Attachments")
            .appendingPathComponent(String(messageRowId))
        let fm = FileManager.default
        guard fm.fileExists(atPath: attRoot.path) else { return attachments }

        // Collect every regular file under attRoot, indexed by both
        // basename (for the by-name match) and by numeric part-index
        // subdirectory (for the fallback ordering pass).
        var byName: [String: URL] = [:]
        var byPart: [(part: Int, url: URL)] = []
        if let walker = fm.enumerator(at: attRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                guard isFile else { continue }
                byName[url.lastPathComponent] = url
                // Part-index dir is the immediate subdir of attRoot.
                let rel = url.path.dropFirst(attRoot.path.count).drop(while: { $0 == "/" })
                let firstComponent = rel.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
                if let p = Int(firstComponent) {
                    byPart.append((p, url))
                }
            }
        }
        guard !byName.isEmpty else { return attachments }
        byPart.sort { $0.part < $1.part }

        var fallback = byPart.map(\.url).makeIterator()
        return attachments.map { att in
            guard att.data.isEmpty else { return att }
            if let onDisk = byName[att.name], let bytes = try? Data(contentsOf: onDisk) {
                return Attachment(name: att.name, contentType: att.contentType, data: bytes)
            }
            // Name mismatch — fall through to part-order pairing.
            while let next = fallback.next() {
                if let bytes = try? Data(contentsOf: next) {
                    return Attachment(name: next.lastPathComponent, contentType: att.contentType, data: bytes)
                }
            }
            return att
        }
    }

    /// Drop every cached `rowid → URL` map. Called after a sync, since new
    /// `.emlx` files on disk (and `.partial.emlx` upgraded to full bodies)
    /// won't be visible through a stale cache.
    func invalidateAll() {
        emlxIndexByMailbox.removeAll()
        mboxDirCache.removeAll()
    }

    private func mailboxDiskURL(for mailbox: Mailbox) -> URL {
        if let cached = mboxDirCache[mailbox.rowId] { return cached }
        let accountRoot = mailVersionDir.appendingPathComponent(mailbox.accountUUID)
        let dir = mailbox.diskURL(under: accountRoot)
        mboxDirCache[mailbox.rowId] = dir
        return dir
    }

    private func indexEmlxFiles(in mailboxRowId: Int, dir: URL) throws -> [Int: URL] {
        if let cached = emlxIndexByMailbox[mailboxRowId] { return cached }

        var map: [Int: URL] = [:]
        guard let walker = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            emlxIndexByMailbox[mailboxRowId] = map
            return map
        }

        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard name.hasSuffix(".emlx") else { continue }
            let stem = name.replacingOccurrences(of: ".partial.emlx", with: "")
                .replacingOccurrences(of: ".emlx", with: "")
            guard let rowid = Int(stem) else { continue }
            if let existing = map[rowid], !existing.lastPathComponent.contains(".partial.") {
                continue
            }
            map[rowid] = url
        }

        emlxIndexByMailbox[mailboxRowId] = map
        return map
    }
}
