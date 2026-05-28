import Foundation

/// User-facing toggles for the MCP server. Backed by `UserDefaults.standard`.
/// Off by default — the server reads every email so the user has to opt in
/// explicitly.
enum MCPSettings {
    static let enabledKey = "mcp_enabled"
    static let portKey = "mcp_port"
    static let defaultPort: Int = 8765

    static let authTokenKey = "mcp.auth.token"
    static let cloudflaredPathKey = "mcp.cloudflared.path"
    static let tunnelNameKey = "mcp.tunnel.name"
    static let tunnelPublicURLKey = "mcp.tunnel.publicURL"

    /// On by default after a fresh start; an explicit toggle-off persists.
    /// (The server is loopback-only and, once a tunnel is configured, requires
    /// the auth token — so default-on is safe for this single-user tool.)
    static var enabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: enabledKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 1–65535. Returns `defaultPort` when unset or out of range.
    static var port: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: portKey)
            return (v >= 1 && v <= 65535) ? v : defaultPort
        }
        set {
            let clamped = max(1, min(65535, newValue))
            UserDefaults.standard.set(clamped, forKey: portKey)
        }
    }

    /// Bearer token required on every request when non-empty. Empty string
    /// disables static-token auth.
    ///
    /// Empty + no active OAuth sessions + no `tunnelPublicURL` set →
    /// server runs anonymously on loopback (legacy local-only behaviour).
    /// Empty + no sessions + `tunnelPublicURL` set → the server fails
    /// closed and refuses every request (see `MCPServer.denyIfMissingAuth`).
    /// Set this token (or pair via OAuth) before exposing via a tunnel.
    static var authToken: String {
        get { UserDefaults.standard.string(forKey: authTokenKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: authTokenKey) }
    }

    /// Override for the `cloudflared` binary path; empty string means use
    /// the locator's default search order.
    static var cloudflaredPath: String {
        get { UserDefaults.standard.string(forKey: cloudflaredPathKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: cloudflaredPathKey) }
    }

    /// Named tunnel identifier — the name passed to `cloudflared tunnel
    /// create <name>`. FMail invokes `cloudflared tunnel run <name>` with
    /// this value.
    static var tunnelName: String {
        get { UserDefaults.standard.string(forKey: tunnelNameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: tunnelNameKey) }
    }

    /// Public hostname / URL the named tunnel maps to (e.g.
    /// `https://fmail.example.com`). Source of truth for what FMail
    /// shows in the banner and bakes into the Cowork config snippet —
    /// cloudflared doesn't print it for named tunnels.
    static var tunnelPublicURL: String {
        get { UserDefaults.standard.string(forKey: tunnelPublicURLKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: tunnelPublicURLKey) }
    }

    /// Generate a new auth token: 32 random bytes, base64url-encoded
    /// (URL-safe alphabet, no padding). ~43 chars long.
    static func generateAuthToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let rc = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if rc != errSecSuccess {
            // Fall back to arc4random; SecRandom failure is exceptional.
            for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        }
        let standard = Data(bytes).base64EncodedString()
        return standard
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
