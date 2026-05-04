import Foundation

/// Minimal MIME parser for `.emlx` body content. Handles:
/// - text/plain and text/html parts (single-part)
/// - multipart/alternative, multipart/mixed, multipart/related (recursively)
/// - Content-Transfer-Encoding: 7bit, 8bit, binary, quoted-printable, base64
/// - charset from Content-Type
///
/// Goal is to extract a readable body (preferring text/plain, falling back to
/// text/html stripped) and a list of attachment filenames. Not a fully
/// conformant MIME implementation.
struct MIMEContent {
    let plainText: String?
    let html: String?
    let attachmentNames: [String]
}

enum MIMEParser {
    /// Cap on multipart nesting. Real mail tops out around 5; anything beyond
    /// this is a malformed or hostile message (parser bomb).
    private static let maxMultipartDepth = 20

    /// Parses `bodyData` using the parsed top-level headers.
    static func parse(headers: ParsedHeaders, body: Data) -> MIMEContent {
        let ct = ContentType(headers["content-type"] ?? "text/plain; charset=us-ascii")
        let cte = (headers["content-transfer-encoding"] ?? "7bit").lowercased().trimmingCharacters(in: .whitespaces)
        return parsePart(contentType: ct, transferEncoding: cte, body: body, partHeaders: headers, depth: 0)
    }

    private static func parsePart(contentType: ContentType, transferEncoding: String, body: Data, partHeaders: ParsedHeaders, depth: Int) -> MIMEContent {
        if contentType.major == "multipart", let boundary = contentType.parameters["boundary"] {
            if depth >= maxMultipartDepth {
                return MIMEContent(plainText: nil, html: nil, attachmentNames: [])
            }
            return parseMultipart(body: body, boundary: boundary, subtype: contentType.minor, depth: depth + 1)
        }

        // Single part.
        let decoded = decodeTransferEncoding(body, encoding: transferEncoding)
        let charset = contentType.parameters["charset"] ?? "utf-8"

        switch (contentType.major, contentType.minor) {
        case ("text", "plain"):
            let text = stringFrom(decoded, charset: charset)
            // If there's a filename, treat as attachment too.
            if let name = attachmentName(in: partHeaders) {
                return MIMEContent(plainText: text, html: nil, attachmentNames: [name])
            }
            return MIMEContent(plainText: text, html: nil, attachmentNames: [])
        case ("text", "html"):
            let text = stringFrom(decoded, charset: charset)
            if let name = attachmentName(in: partHeaders) {
                return MIMEContent(plainText: nil, html: text, attachmentNames: [name])
            }
            return MIMEContent(plainText: nil, html: text, attachmentNames: [])
        default:
            // Treat as attachment.
            let name = attachmentName(in: partHeaders) ?? defaultAttachmentName(for: contentType)
            return MIMEContent(plainText: nil, html: nil, attachmentNames: [name])
        }
    }

    private static func parseMultipart(body: Data, boundary: String, subtype: String, depth: Int) -> MIMEContent {
        let parts = splitMultipart(body: body, boundary: boundary)
        var aggregatePlain: String?
        var aggregateHTML: String?
        var attachments: [String] = []

        for partData in parts {
            let (partHeaders, partBody) = splitHeaderBody(partData)
            let partCT = ContentType(partHeaders["content-type"] ?? "text/plain")
            let partCTE = (partHeaders["content-transfer-encoding"] ?? "7bit").lowercased().trimmingCharacters(in: .whitespaces)
            let parsed = parsePart(contentType: partCT, transferEncoding: partCTE, body: partBody, partHeaders: partHeaders, depth: depth)

            if let p = parsed.plainText, aggregatePlain == nil {
                aggregatePlain = p
            }
            if let h = parsed.html, aggregateHTML == nil {
                aggregateHTML = h
            }
            attachments.append(contentsOf: parsed.attachmentNames)
        }

        // For multipart/alternative, prefer plain over html. Both are returned;
        // the caller decides what to render.
        return MIMEContent(plainText: aggregatePlain, html: aggregateHTML, attachmentNames: attachments)
    }

    private static func splitMultipart(body: Data, boundary: String) -> [Data] {
        let delimiter = "--\(boundary)"
        let closeDelimiter = "--\(boundary)--"
        guard let delimData = delimiter.data(using: .ascii),
              let closeData = closeDelimiter.data(using: .ascii)
        else { return [] }

        var parts: [Data] = []
        var cursor = 0
        let bytes = [UInt8](body)
        let delimBytes = [UInt8](delimData)
        let closeBytes = [UInt8](closeData)

        // Find each delimiter occurrence.
        var positions: [Int] = []
        var foundClose = false
        var i = 0
        while i <= bytes.count - delimBytes.count {
            if !foundClose, i <= bytes.count - closeBytes.count, matches(bytes, at: i, with: closeBytes) {
                positions.append(i)
                foundClose = true
                i += closeBytes.count
                continue
            }
            if matches(bytes, at: i, with: delimBytes) {
                // Make sure this isn't a closing delimiter we'd duplicate.
                positions.append(i)
                i += delimBytes.count
                continue
            }
            i += 1
        }

        for k in 0..<positions.count {
            let start = positions[k]
            // Skip the delimiter line itself (until newline).
            var lineEnd = start
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            lineEnd += 1 // consume LF
            let next = (k + 1 < positions.count) ? positions[k + 1] : bytes.count
            if lineEnd < next {
                // Trim trailing CRLF before next delimiter.
                var end = next
                if end > 0, bytes[end - 1] == 0x0A { end -= 1 }
                if end > 0, bytes[end - 1] == 0x0D { end -= 1 }
                if end > lineEnd {
                    parts.append(Data(bytes[lineEnd..<end]))
                }
            }
            cursor = next
        }
        _ = cursor
        return parts
    }

    private static func matches(_ bytes: [UInt8], at i: Int, with pat: [UInt8]) -> Bool {
        if i + pat.count > bytes.count { return false }
        for j in 0..<pat.count where bytes[i + j] != pat[j] { return false }
        return true
    }

    private static func splitHeaderBody(_ data: Data) -> (ParsedHeaders, Data) {
        // Find the first occurrence of CRLF CRLF or LF LF.
        let bytes = [UInt8](data)
        var split: Int? = nil
        var i = 0
        while i < bytes.count - 1 {
            if bytes[i] == 0x0A && bytes[i + 1] == 0x0A {
                split = i + 2
                break
            }
            if i < bytes.count - 3,
               bytes[i] == 0x0D, bytes[i + 1] == 0x0A,
               bytes[i + 2] == 0x0D, bytes[i + 3] == 0x0A {
                split = i + 4
                break
            }
            i += 1
        }
        let headerEnd = split ?? bytes.count
        let headerBytes = Array(bytes.prefix(headerEnd))
        let bodyBytes = headerEnd < bytes.count ? Array(bytes[headerEnd...]) : []

        let headerString = String(bytes: headerBytes, encoding: .utf8)
            ?? String(bytes: headerBytes, encoding: .isoLatin1)
            ?? ""
        return (HeaderParser.parse(headerString), Data(bodyBytes))
    }

    private static func decodeTransferEncoding(_ data: Data, encoding: String) -> Data {
        switch encoding {
        case "base64":
            let str = String(data: data, encoding: .ascii) ?? ""
            let cleaned = str.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            return Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters) ?? data
        case "quoted-printable":
            return decodeQuotedPrintable(data)
        case "7bit", "8bit", "binary", "":
            return data
        default:
            return data
        }
    }

    private static func decodeQuotedPrintable(_ data: Data) -> Data {
        var out: [UInt8] = []
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x3D { // '='
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A {
                    // soft line break (LF)
                    i += 2
                    continue
                }
                if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A {
                    // soft line break (CRLF)
                    i += 3
                    continue
                }
                if i + 2 < bytes.count {
                    let hex = String(bytes: [bytes[i + 1], bytes[i + 2]], encoding: .ascii) ?? ""
                    if let v = UInt8(hex, radix: 16) {
                        out.append(v)
                        i += 3
                        continue
                    }
                }
                out.append(b)
                i += 1
            } else {
                out.append(b)
                i += 1
            }
        }
        return Data(out)
    }

    private static func stringFrom(_ data: Data, charset: String) -> String {
        let enc = EncodedWord.stringEncoding(forCharsetName: charset)
        if let s = String(data: data, encoding: enc) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    private static func attachmentName(in headers: ParsedHeaders) -> String? {
        if let cd = headers["content-disposition"] {
            if let name = paramValue(in: cd, key: "filename") { return name }
        }
        if let ct = headers["content-type"] {
            if let name = paramValue(in: ct, key: "name") { return name }
        }
        return nil
    }

    private static func paramValue(in header: String, key: String) -> String? {
        let lowered = header.lowercased()
        let target = key.lowercased() + "="
        guard let r = lowered.range(of: target) else { return nil }
        let after = header.index(header.startIndex, offsetBy: header.distance(from: lowered.startIndex, to: r.upperBound))
        var i = after
        if i < header.endIndex, header[i] == "\"" {
            i = header.index(after: i)
            var v = ""
            while i < header.endIndex, header[i] != "\"" {
                v.append(header[i])
                i = header.index(after: i)
            }
            return EncodedWord.decode(v)
        } else {
            var v = ""
            while i < header.endIndex, header[i] != ";", !header[i].isWhitespace || !v.isEmpty {
                if header[i] == ";" { break }
                v.append(header[i])
                i = header.index(after: i)
            }
            return EncodedWord.decode(v.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func defaultAttachmentName(for ct: ContentType) -> String {
        return "attachment.\(ct.minor)"
    }
}

struct ContentType {
    let major: String
    let minor: String
    let parameters: [String: String]

    init(_ raw: String) {
        let parts = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let typeSpec = parts.first ?? "text/plain"
        let typeParts = typeSpec.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        self.major = (typeParts.first.map(String.init) ?? "text").lowercased()
        self.minor = (typeParts.count > 1 ? String(typeParts[1]) : "plain").lowercased()

        var params: [String: String] = [:]
        if parts.count > 1 {
            let paramsPart = parts[1]
            for chunk in paramsPart.split(separator: ";") {
                let kv = chunk.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                if kv.count == 2 {
                    var v = kv[1]
                    if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
                        v = String(v.dropFirst().dropLast())
                    }
                    params[kv[0].lowercased()] = v
                }
            }
        }
        self.parameters = params
    }
}
