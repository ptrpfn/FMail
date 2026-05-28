import Foundation

/// Locates Apple Mail's local store and resolves message rowids to `.emlx`
/// file paths on disk.
enum MailStoreEnumerator {
    static let mailRoot = URL(fileURLWithPath: ("~/Library/Mail" as NSString).expandingTildeInPath)

    /// Returns `<root>/V<N>/` for the highest N present, or nil. `root`
    /// defaults to `~/Library/Mail`; it's injectable so the version-selection
    /// logic can be unit tested against a temp directory.
    static func currentMailVersionDirectory(in root: URL = mailRoot) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
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
}
