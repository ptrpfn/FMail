import Foundation

/// Plain HTML → text converter that does NOT use WebKit. Removes tags, decodes
/// common entities, collapses whitespace, and keeps paragraph/line breaks at
/// `<p>` and `<br>` boundaries. Good enough for indexing and for first-pass
/// reader display. Phase 5 may swap in a richer renderer.
enum HTMLStripper {
    static func toPlainText(_ html: String) -> String {
        // Strip <script> and <style> blocks first (greedy, case-insensitive).
        var s = html
        s = removeBlock(s, openTag: "script")
        s = removeBlock(s, openTag: "style")
        s = removeBlock(s, openTag: "head")

        // Add newlines around block-level tags before stripping.
        let blockTags = ["p", "br", "div", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre"]
        for tag in blockTags {
            s = s.replacingOccurrences(of: "<\(tag)", with: "\n<\(tag)", options: [.caseInsensitive])
            s = s.replacingOccurrences(of: "</\(tag)>", with: "</\(tag)>\n", options: [.caseInsensitive])
        }

        // Strip remaining tags.
        var result = ""
        var inTag = false
        for ch in s {
            if inTag {
                if ch == ">" { inTag = false }
            } else {
                if ch == "<" { inTag = true } else { result.append(ch) }
            }
        }

        // Decode common HTML entities.
        result = decodeEntities(result)

        // Collapse runs of whitespace per line, but keep newlines.
        let collapsed = result
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let t = line.unicodeScalars.split(whereSeparator: { CharacterSet.whitespaces.contains($0) })
                return t.map(String.init).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            }
        // Collapse runs of blank lines to a single blank line.
        var output: [String] = []
        var lastBlank = false
        for line in collapsed {
            let blank = line.isEmpty
            if blank && lastBlank { continue }
            output.append(line)
            lastBlank = blank
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeBlock(_ input: String, openTag: String) -> String {
        let pattern = "<\(openTag)\\b[^>]*>[\\s\\S]*?</\(openTag)\\s*>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return input
        }
        let range = NSRange(input.startIndex..., in: input)
        return re.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: "")
    }

    private static func decodeEntities(_ input: String) -> String {
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
            "&nbsp;": " ", "&hellip;": "…", "&mdash;": "—", "&ndash;": "–",
            "&lsquo;": "‘", "&rsquo;": "’", "&ldquo;": "“", "&rdquo;": "”",
            "&copy;": "©", "&reg;": "®", "&trade;": "™",
        ]
        var s = input
        for (k, v) in named {
            s = s.replacingOccurrences(of: k, with: v)
        }
        // Numeric: &#123; or &#xAB;
        let pattern = "&#(x?)([0-9a-fA-F]+);"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let nsr = NSRange(s.startIndex..., in: s)
        let matches = re.matches(in: s, options: [], range: nsr).reversed()
        for m in matches {
            guard let full = Range(m.range, in: s),
                  let hexFlag = Range(m.range(at: 1), in: s),
                  let digits = Range(m.range(at: 2), in: s)
            else { continue }
            let isHex = !s[hexFlag].isEmpty
            let raw = String(s[digits])
            let value = isHex ? Int(raw, radix: 16) : Int(raw)
            if let value, let scalar = Unicode.Scalar(value) {
                s.replaceSubrange(full, with: String(Character(scalar)))
            }
        }
        return s
    }
}
