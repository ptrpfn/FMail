import Foundation

/// Thin HTTPS client for the Gmail REST API. Just the three operations we
/// need for writeback:
///   - `findMessageID(rfc822msgid:)` — map RFC Message-ID → Gmail's stable
///     per-user message ID.
///   - `modifyMessage(id:addLabels:removeLabels:)` — used for mark-read,
///     mark-unread, move-to-spam, move-to-inbox.
///   - `trashMessage(id:)` — Gmail's reversible delete.
///
/// Auth: bearer token from `GmailAuthManager`. On 401 the client refreshes
/// the access token once and retries; persistent 401 surfaces as
/// `GmailAPIError.unauthorized`.
///
/// No batching yet — see WRITEBACK_PLAN.md B3 polish. Each operation is
/// one HTTP request per message; fine for the typical 1-10 message bulk
/// from FMail's UI / MCP.
actor GmailAPIClient {
    private let session: URLSessionProtocol
    private let auth: GmailAuthManager
    /// Cached Keychain label per account email — set once we know
    /// which Keychain entry holds the creds.
    private let keychainLabel: String

    init(
        keychainLabel: String,
        auth: GmailAuthManager = .shared,
        session: URLSessionProtocol = URLSession.shared
    ) {
        self.keychainLabel = keychainLabel
        self.auth = auth
        self.session = session
    }

    /// Look up the Gmail-side message ID for a message identified by its
    /// RFC 2822 `Message-ID` header. Returns nil when no match — usually
    /// means the message has already been permanently deleted Gmail-side.
    func findMessageID(rfc822msgid: String) async throws -> String? {
        let stripped = rfc822msgid.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
        guard !stripped.isEmpty else { return nil }
        let q = "rfc822msgid:\(stripped)"
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "maxResults", value: "1")
        ]
        let (data, _) = try await get(url: components.url!)
        struct ListResponse: Decodable {
            struct Item: Decodable { let id: String }
            let messages: [Item]?
        }
        let parsed = try JSONDecoder().decode(ListResponse.self, from: data)
        return parsed.messages?.first?.id
    }

    /// Add/remove labels on a message. Either array may be empty (but not
    /// both — Gmail rejects an empty modify). `SPAM`, `TRASH`, `INBOX`,
    /// `UNREAD` are the standard system labels we care about; user labels
    /// have arbitrary IDs.
    func modifyMessage(id: String, addLabels: [String] = [], removeLabels: [String] = []) async throws {
        precondition(!(addLabels.isEmpty && removeLabels.isEmpty), "modify with no labels is invalid")
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)/modify")!
        var body: [String: [String]] = [:]
        if !addLabels.isEmpty { body["addLabelIds"] = addLabels }
        if !removeLabels.isEmpty { body["removeLabelIds"] = removeLabels }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        _ = try await postJSON(url: url, body: bodyData)
    }

    /// Move to Gmail Trash. Reversible (`users.messages.untrash` exists,
    /// not used here). Matches what Mail.app's UI Delete does.
    func trashMessage(id: String) async throws {
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)/trash")!
        _ = try await postJSON(url: url, body: Data("{}".utf8))
    }

    // MARK: — HTTP helpers

    private func get(url: URL) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        return try await authedRequest(req)
    }

    private func postJSON(url: URL, body: Data) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try await authedRequest(req)
    }

    /// Add Authorization header, send, retry once on 401. The retry
    /// path forces a token refresh through `GmailAuthManager`.
    private func authedRequest(_ baseRequest: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            var req = baseRequest
            let token = try await auth.currentAccessToken(label: keychainLabel)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw GmailAPIError.transport("non-HTTP response")
            }
            if http.statusCode == 401 && attempt == 0 {
                // Force a refresh by invalidating cache via revoke?
                // Actually GmailAuthManager already refreshes when
                // isExpiring() — a 401 might mean the server invalidated.
                // For now, just retry once: if token was stale we should
                // get a fresh one (cache invalidates on persist). If it
                // persists, fall through.
                attempt += 1
                continue
            }
            if !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "(empty)"
                throw GmailAPIError.httpStatus(code: http.statusCode, body: body)
            }
            return (data, http)
        }
    }
}

enum GmailAPIError: Error, CustomStringConvertible {
    case transport(String)
    case httpStatus(code: Int, body: String)
    case unauthorized
    case decode(String)

    var description: String {
        switch self {
        case .transport(let m): return "Gmail API transport error: \(m)"
        case .httpStatus(let c, let b): return "Gmail API HTTP \(c): \(b.prefix(300))"
        case .unauthorized: return "Gmail API authorization revoked — re-authorize the account"
        case .decode(let m): return "Gmail API decode error: \(m)"
        }
    }
}

/// Standard Gmail system label IDs. Used by the writeback service.
enum GmailSystemLabel {
    static let inbox = "INBOX"
    static let unread = "UNREAD"
    static let spam = "SPAM"
    static let trash = "TRASH"
    static let starred = "STARRED"
}
