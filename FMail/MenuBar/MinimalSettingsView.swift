import AppKit
import SwiftUI

/// Minimal settings for the menu-bar build. Deliberately excludes anything
/// already controlled from the menu (MCP on/off, tunnel open, approval
/// window) — this is only for the values you set once: the auth token and
/// the named-tunnel routing details.
struct MinimalSettingsView: View {
    let model: MailModel

    @State private var authToken = MCPSettings.authToken
    @State private var port = String(MCPSettings.port)
    @State private var tunnelName = MCPSettings.tunnelName
    @State private var publicURL = MCPSettings.tunnelPublicURL
    @State private var cloudflaredPath = MCPSettings.cloudflaredPath

    /// Read live from the (now `@Observable`) store so a pairing or revoke
    /// updates the row immediately — no `.onAppear` re-sampling needed.
    private var sessionCount: Int { OAuthStore.shared.sessions.count }

    var body: some View {
        Form {
            Section("MCP") {
                TextField("Port", text: $port)
                    .onChange(of: port) { _, new in
                        if let v = Int(new) { MCPSettings.port = v }
                    }
            }

            Section("Auth token") {
                HStack {
                    TextField("Bearer token", text: $authToken)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: authToken) { _, new in MCPSettings.authToken = new }
                    Button("Generate") {
                        authToken = MCPSettings.generateAuthToken()
                        MCPSettings.authToken = authToken
                    }
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(authToken, forType: .string)
                    }
                    .disabled(authToken.isEmpty)
                }
                Text("Required before exposing the server through a tunnel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Tunnel") {
                TextField("Tunnel name", text: $tunnelName)
                    .onChange(of: tunnelName) { _, new in MCPSettings.tunnelName = new }
                TextField("Public URL (https://…)", text: $publicURL)
                    .onChange(of: publicURL) { _, new in MCPSettings.tunnelPublicURL = new }
                TextField("cloudflared path (optional)", text: $cloudflaredPath)
                    .onChange(of: cloudflaredPath) { _, new in MCPSettings.cloudflaredPath = new }
            }

            Section("Paired sessions") {
                HStack {
                    Text(sessionCount == 0
                         ? "No paired sessions"
                         : "\(sessionCount) paired session\(sessionCount == 1 ? "" : "s")")
                    Spacer()
                    Button("Revoke all paired sessions") {
                        OAuthStore.shared.revokeAllSessions()
                    }
                    .disabled(sessionCount == 0)
                }
                Text("OAuth-paired remote clients (e.g. a claude.ai connector). Revoking is immediate — the next request from a revoked client gets a 401 and it must re-authorize.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 440)
    }
}
