import Foundation

/// Locates Apple Mail's local store and resolves message rowids to `.emlx`
/// file paths on disk.
enum MailStoreEnumerator {
    static let mailRoot = URL(fileURLWithPath: ("~/Library/Mail" as NSString).expandingTildeInPath)

    /// Returns `~/Library/Mail/V<N>/` for the highest N present, or nil.
    static func currentMailVersionDirectory() -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: mailRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let versioned = entries.compactMap { url -> (URL, Int)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("V"), let n = Int(name.dropFirst()) else { return nil }
            return (url, n)
        }
        return versioned.max(by: { $0.1 < $1.1 })?.0
    }

    static func envelopeIndexURL(in versionDir: URL) -> URL {
        versionDir.appendingPathComponent("MailData/Envelope Index")
    }

    /// Walks the version directory and returns the first non-partial `.emlx`
    /// found. Used only by the Phase 0 diagnostic.
    static func findFirstEmlx(in versionDir: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: versionDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if url.pathExtension == "emlx" && !name.contains(".partial.") {
                return url
            }
        }
        return nil
    }

    /// Finds the on-disk `.emlx` file for a given message rowid within a
    /// mailbox's `.mbox` directory tree. The file structure is
    /// `<inner-uuid>/Data/.../Messages/<rowid>.emlx`. We walk to find the
    /// matching file (full or partial). Returns nil if not found.
    static func findEmlx(rowId: Int, in mailboxDir: URL) -> URL? {
        let target = "\(rowId).emlx"
        let partial = "\(rowId).partial.emlx"
        guard let enumerator = FileManager.default.enumerator(
            at: mailboxDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var partialMatch: URL? = nil
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name == target { return url }
            if name == partial { partialMatch = url }
        }
        return partialMatch
    }
}
