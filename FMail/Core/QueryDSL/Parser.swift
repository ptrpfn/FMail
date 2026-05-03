import Foundation

/// Grammar (informal):
///   query  := orExpr | empty
///   orExpr := andExpr (OR andExpr)*
///   andExpr := notExpr (AND? notExpr)*    // implicit AND between adjacent atoms
///   notExpr := ('-' | NOT)? atom
///   atom   := '(' query ')' | term
///   term   := word | quoted | field
struct QueryParser {
    private var tokens: [Token]
    private var pos: Int = 0

    init(_ tokens: [Token]) {
        self.tokens = tokens
    }

    static func parse(_ input: String) -> QueryNode {
        var lex = Lexer(input)
        let toks = lex.tokenize()
        if toks.isEmpty { return .empty }
        var p = QueryParser(toks)
        return p.parseOr()
    }

    private mutating func parseOr() -> QueryNode {
        var nodes: [QueryNode] = [parseAnd()]
        while pos < tokens.count {
            if case .orOp = tokens[pos] {
                pos += 1
                nodes.append(parseAnd())
            } else {
                break
            }
        }
        return nodes.count == 1 ? nodes[0] : .or(nodes)
    }

    private mutating func parseAnd() -> QueryNode {
        var nodes: [QueryNode] = []
        while pos < tokens.count {
            // Bail if the next token would be consumed by an outer caller.
            if isOuterTerminator(tokens[pos]) { break }
            if case .andOp = tokens[pos] { pos += 1; continue }
            nodes.append(parseNot())
        }
        if nodes.isEmpty { return .empty }
        return nodes.count == 1 ? nodes[0] : .and(nodes)
    }

    private mutating func parseNot() -> QueryNode {
        var negate = false
        while pos < tokens.count {
            switch tokens[pos] {
            case .minus, .notOp:
                negate.toggle()
                pos += 1
            default:
                let atom = parseAtom()
                return negate ? .not(atom) : atom
            }
        }
        return .empty
    }

    private mutating func parseAtom() -> QueryNode {
        guard pos < tokens.count else { return .empty }
        let tok = tokens[pos]
        switch tok {
        case .lparen:
            pos += 1
            let inner = parseOr()
            if pos < tokens.count, case .rparen = tokens[pos] {
                pos += 1
            }
            return inner
        case .word(let w):
            pos += 1
            // Recognise a few common single-word shortcuts so users don't
            // need to memorise the field:value syntax. Use quotes ("word")
            // to force a literal text match.
            switch w.lowercased() {
            case "hasattachment", "hasattachments":
                return .term(.hasAttachment)
            case "isunread":
                return .term(.isUnread)
            case "isread":
                return .term(.isRead)
            case "isflagged", "isstarred":
                return .term(.isFlagged)
            default:
                return .term(.anyText(w))
            }
        case .quoted(let s):
            pos += 1
            return .term(.phrase(s))
        case .field(let name, let value):
            pos += 1
            return .term(makeFieldTerm(name: name, value: value))
        default:
            pos += 1
            return .empty
        }
    }

    private func isOuterTerminator(_ t: Token) -> Bool {
        switch t {
        case .rparen, .orOp: return true
        default: return false
        }
    }

    private func makeFieldTerm(name: String, value: String) -> Term {
        let v = value.trimmingCharacters(in: .whitespaces)
        switch name {
        case "from": return .fromAddr(v)
        case "to": return .toAddr(v)
        case "cc": return .ccAddr(v)
        case "subject", "subj": return .subject(v)
        case "body": return .body(v)
        case "attachment", "filename": return .attachmentName(v)
        case "in": return .mailboxKind(v.lowercased())
        case "account": return .account(v)
        case "before":
            // `before:2026` → < start of 2026.    (exclusive of 2026)
            // `before:2024-03-15` → < that day.   (exclusive of that day)
            if let p = DateExpression.parse(v) { return .dateBefore(p.date) }
        case "after", "since":
            // `after:2024`     → >= start of 2025      (after the period)
            // `after:2024-03`  → >= start of Apr 2024  (after the period)
            // `after:2024-03-15` → >= start of that day (Gmail-style inclusive)
            if let p = DateExpression.parse(v) {
                let bound: Date = (p.granularity == .day) ? p.date : p.startOfNextPeriod()
                return .dateAfter(bound)
            }
        case "on", "during":
            // Granular range. Width = the precision the user typed at:
            //   `during:2026`        → all of 2026
            //   `during:2026-03`     → all of March 2026
            //   `during:2026-03-15`  → that one day
            if let p = DateExpression.parse(v) {
                return .dateInRange(p.date, p.startOfNextPeriod())
            }
        case "is":
            switch v.lowercased() {
            case "unread": return .isUnread
            case "read": return .isRead
            case "flagged", "starred": return .isFlagged
            case "unflagged", "unstarred": return .isUnflagged
            default: break
            }
        case "has":
            switch v.lowercased() {
            case "attachment", "attachments", "att": return .hasAttachment
            default: break
            }
        default:
            break
        }
        return .unknownField(name: name, value: v)
    }
}
