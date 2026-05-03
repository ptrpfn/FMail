import Foundation

/// Granularity at which a date phrase was specified. Used to resolve
/// asymmetric `before:` / `after:` semantics on partial dates:
///   `before:2026`     → before start of 2026  (exclusive of 2026 itself)
///   `after:2024`      → after end of 2024     (i.e. >= start of 2025)
///   `after:2024-03`   → after end of March 2024 (>= start of April 2024)
///   `after:2024-03-15` → on or after March 15 2024 (Gmail-style inclusive)
enum DateGranularity {
    case day, month, year
}

struct ParsedDate {
    let date: Date          // Start of the period.
    let granularity: DateGranularity

    /// Start of the period immediately after this one.
    func startOfNextPeriod() -> Date {
        let cal = Calendar.current
        switch granularity {
        case .day:   return cal.date(byAdding: .day, value: 1, to: date) ?? date
        case .month: return cal.date(byAdding: .month, value: 1, to: date) ?? date
        case .year:  return cal.date(byAdding: .year, value: 1, to: date) ?? date
        }
    }
}

/// Parses date/time phrases used inside the search DSL.
/// Accepts:
///   - ISO 8601: `2024-03-15` (day), `2024-03` (month), `2024` (year)
///   - Single-word: `today`, `yesterday`, `tomorrow` (day)
///   - Compact relative: `7d`, `2w`, `3m`, `1y` — N units ago (day)
///   - Multi-word relative: `"last 30 days"`, `"last week"`, `"this year"` (day)
///   - Month names: `march` (month), `march 2024` (month)
enum DateExpression {
    static func parse(_ input: String) -> ParsedDate? {
        let t = input.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { return nil }

        if let d = parseISO(t) { return d }
        if let d = parseSingleWord(t) { return d }
        if let d = parseCompactRelative(t) { return d }
        if let d = parseMultiWordRelative(t) { return d }
        if let d = parseMonthName(t) { return d }
        return nil
    }

    private static func parseISO(_ s: String) -> ParsedDate? {
        let cases: [(String, DateGranularity)] = [
            ("yyyy-MM-dd", .day),
            ("yyyy-MM", .month),
            ("yyyy", .year),
        ]
        for (fmt, gran) in cases {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            f.timeZone = TimeZone.current
            if let d = f.date(from: s) {
                return ParsedDate(date: d, granularity: gran)
            }
        }
        return nil
    }

    private static func parseSingleWord(_ s: String) -> ParsedDate? {
        let cal = Calendar.current
        let now = Date()
        switch s {
        case "today":     return ParsedDate(date: cal.startOfDay(for: now), granularity: .day)
        case "yesterday": return cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)).map { ParsedDate(date: $0, granularity: .day) }
        case "tomorrow":  return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)).map { ParsedDate(date: $0, granularity: .day) }
        default: return nil
        }
    }

    /// `7d`, `2w`, `3m`, `1y`. Interpreted as "N units ago from now".
    private static func parseCompactRelative(_ s: String) -> ParsedDate? {
        guard let last = s.last else { return nil }
        let prefix = String(s.dropLast())
        guard let n = Int(prefix), n > 0 else { return nil }

        let cal = Calendar.current
        let now = Date()
        let component: Calendar.Component
        switch last {
        case "d": component = .day
        case "w": component = .weekOfYear
        case "m": component = .month
        case "y": component = .year
        default: return nil
        }
        guard let d = cal.date(byAdding: component, value: -n, to: now) else { return nil }
        return ParsedDate(date: cal.startOfDay(for: d), granularity: .day)
    }

    private static func parseMultiWordRelative(_ s: String) -> ParsedDate? {
        let cal = Calendar.current
        let now = Date()
        let parts = s.split(separator: " ").map(String.init)

        if parts == ["last", "week"] { return cal.date(byAdding: .weekOfYear, value: -1, to: now).map { ParsedDate(date: cal.startOfDay(for: $0), granularity: .day) } }
        if parts == ["last", "month"] { return cal.date(byAdding: .month, value: -1, to: now).map { ParsedDate(date: cal.startOfDay(for: $0), granularity: .day) } }
        if parts == ["last", "year"] { return cal.date(byAdding: .year, value: -1, to: now).map { ParsedDate(date: cal.startOfDay(for: $0), granularity: .day) } }
        if parts == ["this", "year"] {
            let comps = cal.dateComponents([.year], from: now)
            return cal.date(from: comps).map { ParsedDate(date: $0, granularity: .day) }
        }
        if parts == ["this", "month"] {
            let comps = cal.dateComponents([.year, .month], from: now)
            return cal.date(from: comps).map { ParsedDate(date: $0, granularity: .day) }
        }
        if parts == ["this", "week"] {
            return cal.dateInterval(of: .weekOfYear, for: now).map { ParsedDate(date: $0.start, granularity: .day) }
        }
        if parts.count == 3, parts[0] == "last", let n = Int(parts[1]) {
            let component: Calendar.Component?
            switch parts[2] {
            case "days", "day": component = .day
            case "weeks", "week": component = .weekOfYear
            case "months", "month": component = .month
            case "years", "year": component = .year
            default: component = nil
            }
            if let component, let d = cal.date(byAdding: component, value: -n, to: now) {
                return ParsedDate(date: cal.startOfDay(for: d), granularity: .day)
            }
        }
        return nil
    }

    private static let monthNames: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3,
        "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7,
        "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
        "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]

    private static func parseMonthName(_ s: String) -> ParsedDate? {
        let parts = s.split(separator: " ").map(String.init)
        let cal = Calendar.current
        let now = Date()
        let nowYear = cal.component(.year, from: now)

        if parts.count == 1, let m = monthNames[parts[0]] {
            // "march" — implies most recent past March.
            var year = nowYear
            let nowMonth = cal.component(.month, from: now)
            if m > nowMonth { year -= 1 }
            return cal.date(from: DateComponents(year: year, month: m, day: 1)).map { ParsedDate(date: $0, granularity: .month) }
        }
        if parts.count == 2, let m = monthNames[parts[0]], let y = Int(parts[1]) {
            return cal.date(from: DateComponents(year: y, month: m, day: 1)).map { ParsedDate(date: $0, granularity: .month) }
        }
        return nil
    }
}
