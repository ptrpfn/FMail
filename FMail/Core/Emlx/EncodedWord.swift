import Foundation

/// RFC 2047 "encoded-word" decoder for header values like Subject and From.
///
/// Decodes patterns of the form `=?charset?B?text?=` (base64) or
/// `=?charset?Q?text?=` (quoted-printable variant where `_` is space).
/// Adjacent encoded-words separated only by whitespace have that whitespace
/// removed (RFC 2047 §6.2). Anything not in encoded-word form is passed
/// through unchanged.
enum EncodedWord {
    static func decode(_ input: String) -> String {
        guard input.contains("=?") else { return input }

        var result = ""
        var idx = input.startIndex
        var lastWasEncodedWord = false
        var pendingWhitespace = ""

        while idx < input.endIndex {
            if let (decoded, end) = parseOneEncodedWord(in: input, from: idx) {
                if lastWasEncodedWord {
                    // Drop whitespace between adjacent encoded-words.
                } else {
                    result.append(pendingWhitespace)
                }
                pendingWhitespace = ""
                result.append(decoded)
                lastWasEncodedWord = true
                idx = end
                continue
            }

            let ch = input[idx]
            if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
                pendingWhitespace.append(ch)
            } else {
                if lastWasEncodedWord {
                    result.append(pendingWhitespace)
                    lastWasEncodedWord = false
                }
                result.append(pendingWhitespace)
                pendingWhitespace = ""
                result.append(ch)
            }
            idx = input.index(after: idx)
        }
        result.append(pendingWhitespace)
        return result
    }

    /// Returns (decoded, endIndex) if `input` starts an encoded-word at `start`.
    private static func parseOneEncodedWord(in input: String, from start: String.Index) -> (String, String.Index)? {
        let remaining = input[start...]
        guard remaining.hasPrefix("=?") else { return nil }

        // Find ?B? or ?Q? then closing ?=
        // Format: =?charset?encoding?text?=
        let afterPrefix = input.index(start, offsetBy: 2)
        guard let charsetEnd = input.range(of: "?", range: afterPrefix..<input.endIndex)?.lowerBound,
              charsetEnd > afterPrefix
        else { return nil }
        let charset = String(input[afterPrefix..<charsetEnd])

        let afterCharset = input.index(after: charsetEnd)
        guard input.distance(from: afterCharset, to: input.endIndex) >= 2 else { return nil }
        let encodingChar = input[afterCharset]
        let afterEncoding = input.index(afterCharset, offsetBy: 1)
        guard afterEncoding < input.endIndex, input[afterEncoding] == "?" else { return nil }

        let textStart = input.index(after: afterEncoding)
        guard let closingRange = input.range(of: "?=", range: textStart..<input.endIndex) else {
            return nil
        }
        let textEnd = closingRange.lowerBound
        let encodedText = String(input[textStart..<textEnd])
        let endIdx = closingRange.upperBound

        let decoded: String?
        switch encodingChar {
        case "B", "b":
            decoded = decodeBase64(encodedText, charset: charset)
        case "Q", "q":
            decoded = decodeQ(encodedText, charset: charset)
        default:
            return nil
        }
        guard let decoded else { return nil }
        return (decoded, endIdx)
    }

    private static func decodeBase64(_ text: String, charset: String) -> String? {
        let cleaned = text.replacingOccurrences(of: " ", with: "")
        guard let data = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return decodeBytes(data, charset: charset)
    }

    private static func decodeQ(_ text: String, charset: String) -> String? {
        var bytes: [UInt8] = []
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "_" {
                bytes.append(0x20)
                i = text.index(after: i)
            } else if c == "=" {
                let nextEnd = text.index(i, offsetBy: 3, limitedBy: text.endIndex) ?? text.endIndex
                if text.distance(from: i, to: nextEnd) == 3 {
                    let hex = text[text.index(after: i)..<nextEnd]
                    if let byte = UInt8(hex, radix: 16) {
                        bytes.append(byte)
                        i = nextEnd
                        continue
                    }
                }
                // Malformed; pass through.
                bytes.append(UInt8(ascii: "="))
                i = text.index(after: i)
            } else {
                for b in c.utf8 { bytes.append(b) }
                i = text.index(after: i)
            }
        }
        return decodeBytes(Data(bytes), charset: charset)
    }

    private static func decodeBytes(_ data: Data, charset: String) -> String? {
        let enc = stringEncoding(forCharsetName: charset)
        return String(data: data, encoding: enc)
    }

    static func stringEncoding(forCharsetName charset: String) -> String.Encoding {
        let upper = charset.uppercased()
        switch upper {
        case "UTF-8", "UTF8": return .utf8
        case "US-ASCII", "ASCII": return .ascii
        case "ISO-8859-1", "LATIN1", "LATIN-1", "ISO_8859-1", "ISO-8859": return .isoLatin1
        case "ISO-8859-2": return .isoLatin2
        case "ISO-8859-15": return cfEncoding(0x020F)   // kCFStringEncodingISOLatin9
        case "WINDOWS-1252", "CP1252": return cfEncoding(0x0500) // kCFStringEncodingWindowsLatin1
        case "WINDOWS-1250", "CP1250": return cfEncoding(0x0501) // kCFStringEncodingWindowsLatin2
        case "UTF-16", "UTF16": return .utf16
        default:
            return .utf8
        }
    }

    private static func cfEncoding(_ raw: UInt32) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(raw)))
    }
}
