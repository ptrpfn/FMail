import Foundation

/// Parses Apple Mail's `mailboxes.url` field, which has the form
/// `imap://<account-uuid>/<path1>/<path2>` (URL-encoded path components).
/// Local mailboxes use other schemes (e.g. `local-only://`); we treat the host
/// as the account identifier in all cases.
enum MailboxURL {
    static func parse(_ raw: String) -> (accountUUID: String, pathComponents: [String])? {
        guard let comps = URLComponents(string: raw) else {
            return fallbackParse(raw)
        }
        let host = comps.host ?? comps.user ?? ""
        let pathParts = comps.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? String($0) }
        guard !host.isEmpty else { return fallbackParse(raw) }
        return (host, pathParts)
    }

    /// `URLComponents` chokes on some URLs Apple emits (especially with
    /// embedded `[`). Fallback: split manually.
    private static func fallbackParse(_ raw: String) -> (String, [String])? {
        guard let schemeRange = raw.range(of: "://") else { return nil }
        let afterScheme = raw[schemeRange.upperBound...]
        guard let firstSlash = afterScheme.firstIndex(of: "/") else {
            return (String(afterScheme), [])
        }
        let host = String(afterScheme[..<firstSlash])
        let pathStr = String(afterScheme[afterScheme.index(after: firstSlash)...])
        let parts = pathStr
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? String($0) }
        return (host, parts)
    }
}
