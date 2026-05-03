import Foundation

/// Parsed RFC 822 / RFC 5322 header block. Header names are stored lowercased
/// for case-insensitive lookup.
struct ParsedHeaders {
    let headers: [(String, String)]    // preserves order, raw-name lowercased
    private let map: [String: String]   // last-wins for duplicates

    subscript(name: String) -> String? {
        map[name.lowercased()]
    }

    func all(_ name: String) -> [String] {
        let key = name.lowercased()
        return headers.filter { $0.0 == key }.map { $0.1 }
    }

    init(_ entries: [(String, String)]) {
        self.headers = entries
        var m: [String: String] = [:]
        for (k, v) in entries { m[k] = v }
        self.map = m
    }
}

enum HeaderParser {
    /// Parses a header block (without the trailing blank line). Handles RFC 5322
    /// line folding (continuation lines start with whitespace). Returned values
    /// are joined with single spaces and trimmed; encoded-words are NOT decoded
    /// here — call `EncodedWord.decode` on the value for human display.
    static func parse(_ text: String) -> ParsedHeaders {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let rawLines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Fold continuation lines into a single logical line per header.
        var logical: [String] = []
        for line in rawLines {
            if line.isEmpty { continue }
            if let f = line.first, f == " " || f == "\t" {
                if !logical.isEmpty {
                    logical[logical.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
                } else {
                    logical.append(line)
                }
            } else {
                logical.append(line)
            }
        }

        var entries: [(String, String)] = []
        for line in logical {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).lowercased().trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            entries.append((name, value))
        }
        return ParsedHeaders(entries)
    }
}
