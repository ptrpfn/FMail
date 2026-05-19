import Foundation

/// Locates the `cloudflared` binary. Looks first at the user override, then
/// at the two standard Homebrew install paths. We don't shell out to
/// `which` — Apple's TCC sandbox would block the resulting exec on a
/// signed/notarised build, and a small ordered list of well-known paths
/// covers every Homebrew install (`/opt/homebrew` on Apple Silicon,
/// `/usr/local` on Intel). The user override exists for the edge case of
/// a custom install or a non-Homebrew package.
enum CloudflaredLocator {
    /// Candidate absolute paths in priority order. The user override is
    /// only consulted when non-empty; otherwise the two Homebrew defaults.
    static func candidatePaths(override: String) -> [String] {
        var paths: [String] = []
        let trimmed = override.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            paths.append(trimmed)
        }
        paths.append("/opt/homebrew/bin/cloudflared")
        paths.append("/usr/local/bin/cloudflared")
        return paths
    }

    /// Returns the first candidate path that exists on disk and is
    /// executable, or nil if none match.
    static func locate(override: String, fileManager: FileManager = .default) -> String? {
        for path in candidatePaths(override: override) {
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// True when `~/.cloudflared/cert.pem` exists — the credential
    /// `cloudflared tunnel login` writes. Absence is a hard error for
    /// named tunnels (cloudflared refuses to start without it).
    static func isLoggedIn(fileManager: FileManager = .default) -> Bool {
        let path = NSHomeDirectory() + "/.cloudflared/cert.pem"
        return fileManager.fileExists(atPath: path)
    }

    /// Find the tunnel credentials JSON file written by
    /// `cloudflared tunnel create <name>`. The file is named after the
    /// tunnel's UUID (e.g. `e7a78b42-….json`) and lives in
    /// `~/.cloudflared/`. Returns the path when exactly one such file is
    /// present; nil if zero or more than one (in the multi-tunnel case
    /// we'd need a Settings override to disambiguate — out of scope for v1).
    static func findCredentialsFile(fileManager: FileManager = .default) -> String? {
        let dir = NSHomeDirectory() + "/.cloudflared"
        guard let entries = try? fileManager.contentsOfDirectory(atPath: dir) else { return nil }
        let candidates = entries.filter { name in
            // UUID-formatted filename with .json extension. Skips
            // cert.pem, config.yml, dotfiles, anything not matching the
            // UUID layout.
            name.hasSuffix(".json") && looksLikeUUIDFilename(name)
        }
        guard candidates.count == 1, let only = candidates.first else { return nil }
        return dir + "/" + only
    }

    private static func looksLikeUUIDFilename(_ name: String) -> Bool {
        let stem = name.replacingOccurrences(of: ".json", with: "")
        let parts = stem.split(separator: "-")
        guard parts.count == 5 else { return false }
        let expectedLengths = [8, 4, 4, 4, 12]
        for (i, part) in parts.enumerated() {
            guard part.count == expectedLengths[i] else { return false }
            for ch in part where !ch.isHexDigit { return false }
        }
        return true
    }
}
