import Foundation

/// `/.well-known/oauth-authorization-server` response (RFC 8414). MCP
/// clients use this to discover the authorize / token / register
/// endpoints rather than hard-coding them. We populate `issuer` from
/// `MCPSettings.tunnelPublicURL` because the discovery URL the client
/// hit is the tunnel's public hostname, and `issuer` must match.
enum OAuthMetadata {
    static func make(issuer: String) -> [String: JSONValue] {
        let base = issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return [
            "issuer": .string(base),
            "authorization_endpoint": .string(base + "/authorize"),
            "token_endpoint": .string(base + "/token"),
            "registration_endpoint": .string(base + "/register"),
            "response_types_supported": .array([.string("code")]),
            "grant_types_supported": .array([.string("authorization_code")]),
            "code_challenge_methods_supported": .array([.string("S256")]),
            // We're a public client (PKCE). The token endpoint accepts
            // anything that round-trips the PKCE verifier; we don't issue
            // client_secrets.
            "token_endpoint_auth_methods_supported": .array([.string("none")]),
            // Spec compliance niceties.
            "scopes_supported": .array([.string("mcp")]),
            "service_documentation": .string("https://github.com/flx/FMail")
        ]
    }

    /// `/.well-known/oauth-protected-resource` response (RFC 9728). The
    /// MCP authorization spec requires this — when a client gets 401 on
    /// the MCP endpoint, the `WWW-Authenticate` header points here, and
    /// the client follows the `authorization_servers` link to find the
    /// `/.well-known/oauth-authorization-server` metadata above.
    static func makeProtectedResource(issuer: String, resourcePath: String) -> [String: JSONValue] {
        let base = issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return [
            "resource": .string(base + resourcePath),
            "authorization_servers": .array([.string(base)]),
            "bearer_methods_supported": .array([.string("header")]),
            "scopes_supported": .array([.string("mcp")])
        ]
    }
}
