import Foundation

/// Parsed `.emlx` file: headers + body parts.
struct ParsedEmlx {
    let headers: ParsedHeaders
    let mime: MIMEContent
    let flagBits: EmlxFlags?
}

/// Bits unpacked from the `.emlx` binary plist trailer's "flags" entry.
/// Bit positions per Apple's documented Mail flag layout (subset).
struct EmlxFlags {
    let isRead: Bool
    let isFlagged: Bool
    let isReplied: Bool
    let isForwarded: Bool
    let raw: UInt64
}

enum EmlxParserError: Error {
    case fileTooSmall
    case malformed(String)
}

enum EmlxParser {
    /// Returns just the Subject header (RFC 2047 decoded). Used by Phase 0
    /// diagnostic and as a fast path. For full parsing use `parse(url:)`.
    static func subject(of url: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 16_384), !data.isEmpty else { return nil }
        let (text, _) = peelLengthPrefix(data)
        let (headerStr, _) = splitHeaderBody(text)
        let parsed = HeaderParser.parse(headerStr)
        guard let raw = parsed["subject"] else { return nil }
        return EncodedWord.decode(raw)
    }

    /// Full parse. Returns headers, MIME-decoded body, and the trailer flag bits
    /// when present.
    static func parse(url: URL) throws -> ParsedEmlx {
        let data = try Data(contentsOf: url)
        guard data.count > 8 else { throw EmlxParserError.fileTooSmall }

        let (rfc822Bytes, trailerBytes) = peelLengthAndTrailer(data)
        let (headerStr, bodyBytes) = splitHeaderBodyBytes(rfc822Bytes)
        let headers = HeaderParser.parse(headerStr)
        let mime = MIMEParser.parse(headers: headers, body: bodyBytes)
        let flags = parseTrailerFlags(trailerBytes)

        return ParsedEmlx(headers: headers, mime: mime, flagBits: flags)
    }

    // MARK: — Private

    /// `.emlx` starts with a decimal byte length followed by LF, then the
    /// RFC 822 message of that length, then a binary plist trailer.
    /// Returns (rfc822Data, trailerData).
    private static func peelLengthAndTrailer(_ data: Data) -> (Data, Data) {
        // Find first newline.
        var lfIdx = 0
        let bytes = [UInt8](data)
        while lfIdx < bytes.count, bytes[lfIdx] != 0x0A { lfIdx += 1 }
        guard lfIdx < bytes.count else { return (data, Data()) }
        let prefix = String(bytes: bytes[0..<lfIdx], encoding: .ascii) ?? ""
        guard let parsedLength = Int(prefix.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsedLength >= 0
        else {
            return (data, Data())
        }
        let bodyStart = lfIdx + 1
        // Clamp first: an attacker-supplied prefix near Int.max would trap on
        // `bodyStart + parsedLength`. Clamping to remaining bytes makes the
        // arithmetic safe and falls through to the "no trailer" path below.
        let remaining = bytes.count - bodyStart
        let length = min(parsedLength, max(0, remaining))
        guard bodyStart + length <= bytes.count else {
            return (Data(bytes[bodyStart...]), Data())
        }
        let rfc = Data(bytes[bodyStart..<(bodyStart + length)])
        let trailer = Data(bytes[(bodyStart + length)...])
        return (rfc, trailer)
    }

    /// Variant returning a String for the case where the caller wants to read a
    /// fixed prefix from a FileHandle.
    private static func peelLengthPrefix(_ data: Data) -> (String, Int) {
        var lfIdx = 0
        let bytes = [UInt8](data)
        while lfIdx < bytes.count, bytes[lfIdx] != 0x0A { lfIdx += 1 }
        guard lfIdx < bytes.count else {
            return (String(decoding: data, as: UTF8.self), 0)
        }
        let prefix = String(bytes: bytes[0..<lfIdx], encoding: .ascii) ?? ""
        let length = Int(prefix.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let rest = Data(bytes[(lfIdx + 1)...])
        let str = String(data: rest, encoding: .utf8) ?? String(data: rest, encoding: .isoLatin1) ?? ""
        return (str, length)
    }

    /// Split a decoded String into header/body around the first blank line.
    private static func splitHeaderBody(_ text: String) -> (String, String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        if let r = normalized.range(of: "\n\n") {
            return (String(normalized[..<r.lowerBound]), String(normalized[r.upperBound...]))
        }
        return (normalized, "")
    }

    private static func splitHeaderBodyBytes(_ data: Data) -> (String, Data) {
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count - 1 {
            if bytes[i] == 0x0A && bytes[i + 1] == 0x0A {
                let header = String(bytes: bytes[0..<i], encoding: .utf8) ?? String(bytes: bytes[0..<i], encoding: .isoLatin1) ?? ""
                let body = Data(bytes[(i + 2)...])
                return (header, body)
            }
            if i < bytes.count - 3,
               bytes[i] == 0x0D, bytes[i + 1] == 0x0A,
               bytes[i + 2] == 0x0D, bytes[i + 3] == 0x0A {
                let header = String(bytes: bytes[0..<i], encoding: .utf8) ?? String(bytes: bytes[0..<i], encoding: .isoLatin1) ?? ""
                let body = Data(bytes[(i + 4)...])
                return (header, body)
            }
            i += 1
        }
        let header = String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
        return (header, Data())
    }

    /// Parse the binary plist trailer. We're after "flags" (NSNumber).
    /// Apple's bit layout (partial, reverse-engineered):
    ///   bit 0  = read
    ///   bit 4  = answered (replied)
    ///   bit 5  = encrypted
    ///   bit 6  = flagged
    ///   bit 8  = forwarded
    /// Source: jwz-style notes; not officially documented. We're pessimistic.
    private static func parseTrailerFlags(_ data: Data) -> EmlxFlags? {
        guard !data.isEmpty else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        guard let raw = (plist["flags"] as? NSNumber)?.uint64Value else { return nil }
        return EmlxFlags(
            isRead: (raw & (1 << 0)) != 0,
            isFlagged: (raw & (1 << 6)) != 0,
            isReplied: (raw & (1 << 4)) != 0,
            isForwarded: (raw & (1 << 8)) != 0,
            raw: raw
        )
    }
}
