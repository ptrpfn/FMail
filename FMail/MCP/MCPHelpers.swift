import Foundation

/// Shared helpers used by handler files. Internal to keep the public
/// surface of the MCP module narrow — only `MCPServer`, `MCPDispatcher`,
/// `MCPTools`, and the DTOs are intended to be consumed outside.

enum MCPHelpers {
    static func clampInt(_ v: Int, min lo: Int, max hi: Int) -> Int {
        Swift.max(lo, Swift.min(hi, v))
    }

    /// Parse YYYY, YYYY-MM, or YYYY-MM-DD as a Date at start-of-period UTC.
    /// Each present segment must be numeric — `"2024-foo"` returns nil
    /// rather than silently degrading to January 1st. Returns nil on any
    /// other shape.
    static func parseISODate(_ s: String) -> Date? {
        let parts = s.split(separator: "-").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        guard let y = Int(parts[0]) else { return nil }
        var components = DateComponents()
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = y
        components.month = 1
        components.day = 1
        if parts.count >= 2 {
            guard let m = Int(parts[1]) else { return nil }
            components.month = m
        }
        if parts.count >= 3 {
            guard let d = Int(parts[2]) else { return nil }
            components.day = d
        }
        return Calendar(identifier: .gregorian).date(from: components)
    }
}
