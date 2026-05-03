import Foundation

struct Lexer {
    private let chars: [Character]
    private var pos: Int = 0

    init(_ input: String) {
        self.chars = Array(input)
    }

    mutating func tokenize() -> [Token] {
        var out: [Token] = []
        while pos < chars.count {
            skipWhitespace()
            if pos >= chars.count { break }

            let c = chars[pos]

            if c == "(" { pos += 1; out.append(.lparen); continue }
            if c == ")" { pos += 1; out.append(.rparen); continue }

            if c == "-" {
                // - is NOT-shortcut only when followed by an atom-starting char.
                let next = pos + 1 < chars.count ? chars[pos + 1] : " "
                if !next.isWhitespace && next != ")" {
                    pos += 1
                    out.append(.minus)
                    continue
                }
            }

            if c == "\"" {
                let s = readQuoted()
                out.append(.quoted(s))
                continue
            }

            // Otherwise read a bareword. If a colon follows immediately, treat
            // as field:value (value can be quoted or another bareword).
            let word = readBareword()
            if pos < chars.count, chars[pos] == ":" {
                pos += 1 // consume :
                let value: String
                if pos < chars.count, chars[pos] == "\"" {
                    value = readQuoted()
                } else {
                    value = readBareword()
                }
                out.append(.field(word.lowercased(), value))
                continue
            }

            // Operators are case-insensitive bare words.
            switch word.uppercased() {
            case "AND": out.append(.andOp)
            case "OR": out.append(.orOp)
            case "NOT": out.append(.notOp)
            default: out.append(.word(word))
            }
        }
        return out
    }

    // MARK: — Read helpers

    private mutating func skipWhitespace() {
        while pos < chars.count, chars[pos].isWhitespace { pos += 1 }
    }

    private mutating func readQuoted() -> String {
        // Assumes current char is the opening ".
        pos += 1
        var s = ""
        while pos < chars.count, chars[pos] != "\"" {
            // Allow simple backslash escape of " and \.
            if chars[pos] == "\\", pos + 1 < chars.count {
                s.append(chars[pos + 1])
                pos += 2
            } else {
                s.append(chars[pos])
                pos += 1
            }
        }
        if pos < chars.count, chars[pos] == "\"" { pos += 1 }
        return s
    }

    private mutating func readBareword() -> String {
        var s = ""
        while pos < chars.count {
            let c = chars[pos]
            if c.isWhitespace || c == "(" || c == ")" || c == "\"" || c == ":" {
                break
            }
            s.append(c)
            pos += 1
        }
        return s
    }
}
