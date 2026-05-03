import Foundation

/// Compiled query: an FTS5 MATCH expression plus auxiliary SQL conditions.
///
/// FTS5 has its own boolean syntax (AND, OR, NOT, "phrase", `column:value`)
/// which we leverage for text matching across subject/body/sender/recipients.
/// Date and flag predicates are expressed as plain SQL conditions on the
/// `messages` table.
struct CompiledQuery {
    /// FTS5 MATCH string. Empty if no text predicates were present.
    let ftsExpression: String
    /// Extra SQL fragment to AND into the WHERE clause (no leading AND).
    let sqlConditions: String
    /// Bindings for the SQL fragment, in order.
    let bindings: [SQLBinding]
    /// What the parser understood. Shown to the user above the results.
    let interpretation: String

    var hasAnyConstraint: Bool {
        !ftsExpression.isEmpty || !sqlConditions.isEmpty
    }
}

enum SQLBinding {
    case int(Int64)
    case text(String)
}

enum Evaluator {
    static func compile(_ node: QueryNode) -> CompiledQuery {
        var fts = FTSBuilder()
        var sql = SQLBuilder()
        var human = HumanBuilder()
        emit(node, fts: &fts, sql: &sql, human: &human, polarity: true)
        return CompiledQuery(
            ftsExpression: fts.build(),
            sqlConditions: sql.build(),
            bindings: sql.bindings,
            interpretation: human.build()
        )
    }

    private static func emit(_ node: QueryNode, fts: inout FTSBuilder, sql: inout SQLBuilder, human: inout HumanBuilder, polarity: Bool) {
        switch node {
        case .empty:
            return
        case .and(let children):
            for c in children { emit(c, fts: &fts, sql: &sql, human: &human, polarity: polarity) }
        case .or(let children):
            // OR is hard to express across both FTS and SQL. For Phase 3 we
            // only support OR among text predicates (which FTS5 handles).
            // Mixing OR with date/flag SQL conditions requires UNION; defer.
            var inner = FTSBuilder()
            for (i, c) in children.enumerated() {
                if i > 0 { inner.appendRaw(" OR ") }
                emit(c, fts: &inner, sql: &sql, human: &human, polarity: polarity)
            }
            if !inner.isEmpty {
                fts.appendGroup(inner.build())
            }
        case .not(let inner):
            switch inner {
            case .term(let t):
                emitTerm(t, fts: &fts, sql: &sql, human: &human, polarity: !polarity)
            default:
                // Generic NOT around a sub-expression: encode in FTS as NOT (..).
                var sub = FTSBuilder()
                emit(inner, fts: &sub, sql: &sql, human: &human, polarity: !polarity)
                if !sub.isEmpty {
                    fts.appendRaw(" NOT (\(sub.build()))")
                }
            }
        case .term(let t):
            emitTerm(t, fts: &fts, sql: &sql, human: &human, polarity: polarity)
        }
    }

    private static func emitTerm(_ term: Term, fts: inout FTSBuilder, sql: inout SQLBuilder, human: inout HumanBuilder, polarity: Bool) {
        switch term {
        case .anyText(let w):
            fts.appendBare(w, negate: !polarity)
            human.appendText(w, negate: !polarity)
        case .phrase(let p):
            fts.appendPhrase(p, negate: !polarity)
            human.appendText("\"\(p)\"", negate: !polarity)
        case .fromAddr(let v):
            fts.appendField("sender", v, negate: !polarity)
            human.appendField("from", v, negate: !polarity)
        case .toAddr(let v):
            fts.appendField("recipients", v, negate: !polarity)
            human.appendField("to", v, negate: !polarity)
        case .ccAddr(let v):
            fts.appendField("recipients", v, negate: !polarity)
            human.appendField("cc", v, negate: !polarity)
        case .subject(let v):
            fts.appendField("subject", v, negate: !polarity)
            human.appendField("subject", v, negate: !polarity)
        case .body(let v):
            fts.appendField("body_text", v, negate: !polarity)
            human.appendField("body", v, negate: !polarity)
        case .attachmentName(let v):
            fts.appendField("attachment_names", v, negate: !polarity)
            human.appendField("attachment", v, negate: !polarity)
        case .dateBefore(let d):
            sql.appendCondition("m.date_received < ?", binding: .int(Int64(d.timeIntervalSince1970)))
            human.appendField("before", iso(d), negate: false)
        case .dateAfter(let d):
            sql.appendCondition("m.date_received >= ?", binding: .int(Int64(d.timeIntervalSince1970)))
            human.appendField("after", iso(d), negate: false)
        case .dateInRange(let start, let end):
            sql.appendCondition("m.date_received >= ?", binding: .int(Int64(start.timeIntervalSince1970)))
            sql.appendCondition("m.date_received < ?", binding: .int(Int64(end.timeIntervalSince1970)))
            // Show the user the inclusive range boundaries: end-1day reads
            // more naturally than the half-open form.
            let cal = Calendar.current
            let endInclusive = cal.date(byAdding: .day, value: -1, to: end) ?? end
            let label: String
            if cal.isDate(start, inSameDayAs: endInclusive) {
                label = iso(start)
            } else {
                label = "\(iso(start))..\(iso(endInclusive))"
            }
            human.appendField("during", label, negate: false)
        case .isUnread:
            sql.appendCondition(polarity ? "m.is_read = 0" : "m.is_read = 1")
            human.appendBare("unread", negate: !polarity)
        case .isRead:
            sql.appendCondition(polarity ? "m.is_read = 1" : "m.is_read = 0")
            human.appendBare("read", negate: !polarity)
        case .isFlagged:
            sql.appendCondition(polarity ? "m.is_flagged = 1" : "m.is_flagged = 0")
            human.appendBare("flagged", negate: !polarity)
        case .isUnflagged:
            sql.appendCondition(polarity ? "m.is_flagged = 0" : "m.is_flagged = 1")
            human.appendBare("unflagged", negate: !polarity)
        case .hasAttachment:
            sql.appendCondition(polarity ? "m.has_attachment = 1" : "m.has_attachment = 0")
            human.appendField("has", "attachment", negate: !polarity)
        case .noAttachment:
            sql.appendCondition(polarity ? "m.has_attachment = 0" : "m.has_attachment = 1")
            human.appendField("has", "no attachment", negate: !polarity)
        case .mailboxKind(let kind):
            sql.appendCondition("m.mailbox_rowid IN (SELECT apple_rowid FROM mailboxes WHERE kind = ?)", binding: .text(kind))
            human.appendField("in", kind, negate: !polarity)
        case .account(let acc):
            sql.appendCondition("m.account_uuid IN (SELECT uuid FROM accounts WHERE email_address = ? OR uuid LIKE ?)",
                                bindings: [.text(acc), .text("\(acc)%")])
            human.appendField("account", acc, negate: !polarity)
        case .unknownField(let name, let value):
            // Surface the value as FTS bag-of-words so the user still gets results,
            // and tell them in the interpretation strip.
            fts.appendBare(value, negate: !polarity)
            human.appendField("\(name)?", value, negate: !polarity)
        }
    }

    private static func iso(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

// MARK: — Builders

private struct FTSBuilder {
    private var pieces: [String] = []

    var isEmpty: Bool { pieces.isEmpty }

    mutating func appendBare(_ word: String, negate: Bool) {
        let safe = sanitize(word)
        guard !safe.isEmpty else { return }
        // Prefix match by default so "v" finds "vermont". Use quoted phrase
        // ("v") if you want an exact token.
        let term = "\(safe)*"
        pieces.append(negate ? "NOT \(term)" : term)
    }

    mutating func appendPhrase(_ phrase: String, negate: Bool) {
        let safe = sanitize(phrase)
        guard !safe.isEmpty else { return }
        // Quoted phrases stay exact — that's the point of using quotes.
        let q = "\"\(safe)\""
        pieces.append(negate ? "NOT \(q)" : q)
    }

    mutating func appendField(_ column: String, _ value: String, negate: Bool) {
        let safe = sanitize(value)
        guard !safe.isEmpty else { return }
        // Prefix match for field values too, so subject:v finds vermont.
        let core = "{\(column)}: \(safe)*"
        pieces.append(negate ? "NOT (\(core))" : core)
    }

    mutating func appendRaw(_ s: String) { pieces.append(s) }

    mutating func appendGroup(_ s: String) { pieces.append("(\(s))") }

    func build() -> String {
        // FTS5 implicit AND between space-separated tokens.
        return pieces.joined(separator: " ")
    }

    /// Strip characters that confuse the FTS5 query parser. We're permissive
    /// and let the parser do strict checks.
    private func sanitize(_ s: String) -> String {
        var out = ""
        for ch in s where !"\"():*-".contains(ch) {
            out.append(ch)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

private struct SQLBuilder {
    private var conditions: [String] = []
    private(set) var bindings: [SQLBinding] = []

    mutating func appendCondition(_ sql: String) {
        conditions.append(sql)
    }
    mutating func appendCondition(_ sql: String, binding: SQLBinding) {
        conditions.append(sql)
        bindings.append(binding)
    }
    mutating func appendCondition(_ sql: String, bindings extra: [SQLBinding]) {
        conditions.append(sql)
        bindings.append(contentsOf: extra)
    }
    func build() -> String {
        return conditions.joined(separator: " AND ")
    }
}

private struct HumanBuilder {
    private var pieces: [String] = []

    mutating func appendText(_ s: String, negate: Bool) {
        pieces.append(negate ? "-\(s)" : s)
    }
    mutating func appendField(_ name: String, _ value: String, negate: Bool) {
        let part = "\(name):\(value.contains(" ") ? "\"\(value)\"" : value)"
        pieces.append(negate ? "-\(part)" : part)
    }
    mutating func appendBare(_ s: String, negate: Bool) {
        pieces.append(negate ? "-\(s)" : s)
    }
    func build() -> String { pieces.joined(separator: " ") }
}
