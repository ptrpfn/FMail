import Foundation

/// What to put in the compose window. Built by `ReplyBuilder`, executed by
/// `MailComposer`.
struct ComposeRequest: Sendable {
    let to: [String]
    let cc: [String]
    let subject: String
    let body: String
    let inReplyTo: String?       // RFC 2822 Message-ID, including angle brackets
    let references: [String]     // RFC 2822 Message-IDs
}

enum ReplyKind: Sendable {
    case reply, replyAll, forward
}

/// Converts a MessageHeader + parsed MessageBody into a ComposeRequest.
enum ReplyBuilder {
    static func build(kind: ReplyKind,
                      message: MessageHeader,
                      body: MessageBody?,
                      ourAddress: String?,
                      toAddressOverride: String? = nil) -> ComposeRequest {
        switch kind {
        case .reply:
            return reply(to: message, body: body, toAddress: toAddressOverride)
        case .replyAll:
            return replyAll(to: message, body: body, ourAddress: ourAddress ?? "", toAddress: toAddressOverride)
        case .forward:
            return forward(message: message, body: body)
        }
    }

    private static func reply(to message: MessageHeader, body: MessageBody?, toAddress: String?) -> ComposeRequest {
        let to = toAddress ?? message.senderAddress
        let subject = ensureSubjectPrefix(message.subject, prefix: "Re: ")
        let quoted = quoteBody(body?.displayText ?? "",
                               originalDate: message.dateReceived ?? message.dateSent,
                               originalSender: senderLabel(of: message))
        let messageId = body?.headers["message-id"]
        return ComposeRequest(
            to: [to],
            cc: [],
            subject: subject,
            body: quoted,
            inReplyTo: messageId,
            references: messageId.map { [$0] } ?? []
        )
    }

    private static func replyAll(to message: MessageHeader, body: MessageBody?, ourAddress: String, toAddress: String?) -> ComposeRequest {
        let to = toAddress ?? message.senderAddress
        let originalTo = body?.headers["to"].map { extractAddresses(from: $0) } ?? []
        let originalCc = body?.headers["cc"].map { extractAddresses(from: $0) } ?? []
        let ourLower = ourAddress.lowercased()
        let toLower = to.lowercased()
        var cc = (originalTo + originalCc)
            .map { $0.lowercased() }
            .filter { $0 != ourLower && $0 != toLower && !$0.isEmpty }
        cc = Array(Set(cc))
        let subject = ensureSubjectPrefix(message.subject, prefix: "Re: ")
        let quoted = quoteBody(body?.displayText ?? "",
                               originalDate: message.dateReceived ?? message.dateSent,
                               originalSender: senderLabel(of: message))
        let messageId = body?.headers["message-id"]
        return ComposeRequest(
            to: [to],
            cc: cc.sorted(),
            subject: subject,
            body: quoted,
            inReplyTo: messageId,
            references: messageId.map { [$0] } ?? []
        )
    }

    private static func forward(message: MessageHeader, body: MessageBody?) -> ComposeRequest {
        let subject = ensureSubjectPrefix(message.subject, prefix: "Fwd: ")
        let header = forwardHeaderBlock(message: message, body: body)
        let bodyText = body?.displayText ?? ""
        return ComposeRequest(
            to: [],
            cc: [],
            subject: subject,
            body: "\n\n" + header + "\n\n" + bodyText,
            inReplyTo: nil,
            references: []
        )
    }

    private static func ensureSubjectPrefix(_ subject: String, prefix: String) -> String {
        if subject.lowercased().hasPrefix(prefix.lowercased()) { return subject }
        return prefix + subject
    }

    private static func senderLabel(of message: MessageHeader) -> String {
        message.senderDisplay.isEmpty ? message.senderAddress : message.senderDisplay
    }

    private static func quoteBody(_ body: String, originalDate: Date?, originalSender: String) -> String {
        let dateStr: String
        if let originalDate {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            dateStr = f.string(from: originalDate)
        } else {
            dateStr = "(unknown date)"
        }
        let header = "On \(dateStr), \(originalSender) wrote:"
        // Normalise line endings — some HTML→text and plain-text bodies use
        // CRLF or bare CR. Without this, `split(\"\\n\")` saw the whole body
        // as one line, only the first line got a `> ` prefix, and Mail.app's
        // compose then re-rendered the `\r`s as line breaks (orphans).
        let normalized = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let quoted = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.isEmpty ? ">" : "> \(line)" }
            .joined(separator: "\n")
        return "\n\n" + header + "\n" + quoted + "\n"
    }

    private static func forwardHeaderBlock(message: MessageHeader, body: MessageBody?) -> String {
        var lines: [String] = ["----- Forwarded message -----"]
        let from: String
        if message.senderDisplay.isEmpty {
            from = message.senderAddress
        } else {
            from = "\(message.senderDisplay) <\(message.senderAddress)>"
        }
        lines.append("From: \(from)")
        if let date = message.dateReceived ?? message.dateSent {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            lines.append("Date: \(f.string(from: date))")
        }
        if let to = body?.headers["to"] { lines.append("To: \(EncodedWord.decode(to))") }
        if let cc = body?.headers["cc"] { lines.append("Cc: \(EncodedWord.decode(cc))") }
        lines.append("Subject: \(message.subject)")
        return lines.joined(separator: "\n")
    }

    /// Extract bare email addresses from a header value like
    /// `"Anna <a@b>, Felix <f@g>"` or `"a@b, f@g"`.
    static func extractAddresses(from header: String) -> [String] {
        let chars = Array(header)
        var result: [String] = []
        var i = 0
        while i < chars.count {
            // Skip leading whitespace + comma
            while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\t" { i += 1 }
            if i >= chars.count { break }

            if let lt = chars[i...].firstIndex(of: "<"),
               let gt = chars[lt...].firstIndex(of: ">") {
                // Look for a name<addr> form ending before next comma.
                let nextComma = chars[i...].firstIndex(of: ",") ?? chars.endIndex
                if lt < nextComma {
                    let addr = String(chars[(lt + 1)..<gt]).trimmingCharacters(in: .whitespaces)
                    if addr.contains("@") { result.append(addr) }
                    i = max(gt + 1, nextComma)
                    continue
                }
            }
            // Bare addr: read until comma.
            var end = i
            while end < chars.count, chars[end] != "," { end += 1 }
            let bare = String(chars[i..<end]).trimmingCharacters(in: .whitespaces)
            if bare.contains("@") { result.append(bare) }
            i = end + 1
        }
        return result
    }
}
