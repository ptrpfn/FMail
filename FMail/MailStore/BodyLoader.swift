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
        return MessageBody(
            headers: parsed.headers,
            plainText: parsed.mime.plainText,
            html: parsed.mime.html,
            attachmentNames: parsed.mime.attachmentNames
        )
    }

    /// Drop the cached file map for one mailbox — call when we know its
    /// contents on disk have changed.
    func invalidate(mailboxRowId: Int) {
        emlxIndexByMailbox.removeValue(forKey: mailboxRowId)
    }

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
