import AppKit
import Foundation

/// Hands a composed message off to the user's default mail client (typically
/// Mail.app) via a `mailto:` URL. RFC 6068 lets us pass subject/body/cc/bcc/
/// in-reply-to/references as query parameters, so threading mostly works
/// without needing AppleScript.
///
/// Limitation: very long bodies (~ several thousand characters) can be
/// truncated by URL length limits in some clients. If we hit that in
/// practice, fall back to writing the body to the pasteboard with a
/// notice in the body.
enum MailComposer {
    /// Approximate practical safe ceiling for `mailto:` URLs on macOS.
    private static let maxURLLength = 8000

    @MainActor
    static func handOff(_ req: ComposeRequest) -> Result<Void, ComposerError> {
        guard let url = makeURL(req) else {
            return .failure(.couldNotBuildURL)
        }
        if NSWorkspace.shared.open(url) {
            return .success(())
        }
        return .failure(.openFailed)
    }

    static func makeURL(_ req: ComposeRequest) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = req.to.joined(separator: ",")

        var items: [URLQueryItem] = []
        if !req.subject.isEmpty {
            items.append(URLQueryItem(name: "subject", value: req.subject))
        }
        if !req.cc.isEmpty {
            items.append(URLQueryItem(name: "cc", value: req.cc.joined(separator: ",")))
        }
        if let irt = req.inReplyTo, !irt.isEmpty {
            items.append(URLQueryItem(name: "in-reply-to", value: irt))
        }
        if !req.references.isEmpty {
            items.append(URLQueryItem(name: "references", value: req.references.joined(separator: " ")))
        }
        if !req.body.isEmpty {
            // Truncate body if total URL would blow past safe length. Better
            // to ship a shorter quote than to fail silently.
            var body = req.body
            // Estimate prefix length (everything but body). Crude but close.
            let prefixGuess = (components.url?.absoluteString.count ?? 200)
                + items.reduce(0) { $0 + ($1.name.count + ($1.value?.count ?? 0) + 2) }
            let budget = max(500, maxURLLength - prefixGuess)
            if body.count > budget {
                let cut = body.index(body.startIndex, offsetBy: budget)
                body = String(body[..<cut]) + "\n\n[...quote truncated; open original in FMail to see full content...]"
            }
            items.append(URLQueryItem(name: "body", value: body))
        }
        components.queryItems = items
        return components.url
    }
}

enum ComposerError: Error, CustomStringConvertible {
    case couldNotBuildURL
    case openFailed

    var description: String {
        switch self {
        case .couldNotBuildURL: return "Could not build mailto URL."
        case .openFailed: return "macOS refused to open the mailto URL — is a mail client configured?"
        }
    }
}

/// Opens an existing message in Mail.app via the `message://` URL scheme.
/// Mail.app handles the URL natively (no AppleScript / Automation permission
/// needed) — it navigates to the message *and* triggers a body fetch from
/// the IMAP server if the body isn't downloaded yet.
enum MailAppOpener {
    @MainActor
    static func openMessage(rfcMessageId: String) -> Bool {
        let id = rfcMessageId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return false }
        // message:// expects the full Message-ID including the angle brackets.
        // Percent-encode anything that isn't safe in a URL path; Mail.app
        // decodes back to the original `<...>` form.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
        guard let url = URL(string: "message://\(encoded)") else { return false }
        return NSWorkspace.shared.open(url)
    }
}
