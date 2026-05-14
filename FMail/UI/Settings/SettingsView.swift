import SwiftUI
import AppKit

/// FMail's Settings window. Currently just MCP configuration.
struct SettingsView: View {
    @Environment(\.openURL) private var openURL
    let model: MailModel

    /// Use `@AppStorage` for the form binding so the toggle/port fields
    /// re-render automatically. The model side reads via `MCPSettings.shared`
    /// — both wrap the same `UserDefaults.standard` keys.
    @AppStorage(MCPSettings.enabledKey) private var enabled: Bool = false
    @AppStorage(MCPSettings.portKey) private var port: Int = MCPSettings.defaultPort

    @State private var copied = false
    @State private var gmailAuthStatus: [String: GmailAuthRowStatus] = [:]
    @State private var gmailLastError: [String: String] = [:]

    var body: some View {
        Form {
            // MARK: — Server-direct writeback (Phase B1)
            Section {
                if !GmailOAuthConfig.isConfigured {
                    Text("Gmail OAuth client ID isn't configured. See README — \"Gmail OAuth setup\".")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if model.gmailDetectedAccounts.isEmpty {
                    Text("No Gmail accounts detected in Mail.app.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.gmailDetectedAccounts, id: \.uuid) { acct in
                        gmailAccountRow(account: acct)
                    }
                }
            } header: {
                Text("Gmail accounts")
            } footer: {
                Text("Authorized accounts use the Gmail API directly for move / junk / delete — bypassing Mail.app's flaky AppleScript bridge. AppleScript stays as a fallback for unauthorized accounts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Enable MCP server", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in model.applyMCPSettings() }

                HStack {
                    Text("Port")
                    Spacer()
                    TextField("8765", value: $port, format: .number.grouping(.never))
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { model.applyMCPSettings() }
                }
                .disabled(!enabled)
            } header: {
                Text("MCP Server")
            } footer: {
                Text("Loopback only — exposed on 127.0.0.1, never on the LAN.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                statusRow
                if case .error(let msg) = model.mcpServerStatus {
                    Text(msg)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Status")
            }

            Section {
                Button {
                    copyClaudeCodeConfig()
                } label: {
                    HStack {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy Claude Code config")
                    }
                }
                .buttonStyle(.bordered)
                Text("Paste this into ~/.claude/settings.json under \"mcpServers\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Set up your MCP client")
            }

            Section {
                Text("FMail's MCP server reads every email in your index — subjects, senders, recipients, body text — and exposes them to whichever local process connects on this port. There is no authentication. Only enable this if you understand and accept that.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Privacy").foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 460, minHeight: 460)
        .task { await refreshAllGmailAuthStatus() }
    }

    // MARK: — Gmail per-account row

    @ViewBuilder
    private func gmailAccountRow(account: MailAccount) -> some View {
        let email = account.emailAddress ?? "(no email)"
        let status = gmailAuthStatus[email] ?? .unknown
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(email)
                    .font(.callout)
                if let err = gmailLastError[email] {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            statusBadge(for: status)
            actionButton(for: account, email: email, status: status)
        }
    }

    @ViewBuilder
    private func statusBadge(for status: GmailAuthRowStatus) -> some View {
        switch status {
        case .unknown:
            ProgressView().controlSize(.small)
        case .notAuthorized:
            HStack(spacing: 4) {
                Circle().fill(.gray).frame(width: 8, height: 8)
                Text("Not authorized").font(.caption).foregroundStyle(.secondary)
            }
        case .authorized:
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Authorized").font(.caption).foregroundStyle(.secondary)
            }
        case .authorizing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Authorizing…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func actionButton(for account: MailAccount, email: String, status: GmailAuthRowStatus) -> some View {
        switch status {
        case .unknown, .authorizing:
            EmptyView()
        case .notAuthorized:
            Button("Authorize…") {
                Task { await authorize(email: email) }
            }
            .controlSize(.small)
        case .authorized:
            Button("Revoke") {
                Task { await revoke(email: email) }
            }
            .controlSize(.small)
        }
    }

    private func authorize(email: String) async {
        gmailAuthStatus[email] = .authorizing
        gmailLastError[email] = nil
        do {
            try await model.authorizeGmailAccount(email: email)
            gmailAuthStatus[email] = .authorized
        } catch {
            gmailAuthStatus[email] = .notAuthorized
            gmailLastError[email] = String(describing: error)
        }
    }

    private func revoke(email: String) async {
        do {
            try await model.revokeGmailAccount(email: email)
            gmailAuthStatus[email] = .notAuthorized
            gmailLastError[email] = nil
        } catch {
            gmailLastError[email] = String(describing: error)
        }
    }

    private func refreshAllGmailAuthStatus() async {
        for acct in model.gmailDetectedAccounts {
            guard let email = acct.emailAddress else { continue }
            let isAuthorized = await model.isGmailAuthorized(email: email)
            gmailAuthStatus[email] = isAuthorized ? .authorized : .notAuthorized
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.mcpServerStatus {
        case .stopped:
            HStack {
                Circle().fill(.gray).frame(width: 8, height: 8)
                Text("Stopped")
            }
        case .starting:
            HStack {
                ProgressView().controlSize(.small)
                Text("Starting…")
            }
        case .running(let p):
            HStack {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Running on 127.0.0.1:\(p, format: .number.grouping(.never))")
            }
        case .error:
            HStack {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Error")
            }
        }
    }

    /// Per-row UI state for the Gmail account list. Computed asynchronously
    /// on view appear; transitions to `.authorizing` while the OAuth flow
    /// runs in the user's browser.
    private enum GmailAuthRowStatus: Sendable, Equatable {
        case unknown        // not yet checked
        case notAuthorized  // no Keychain entry
        case authorizing    // OAuth flow in progress
        case authorized     // has stored credentials
    }

    private func copyClaudeCodeConfig() {
        let snippet = """
        {
          "mcpServers": {
            "fmail": {
              "type": "http",
              "url": "http://127.0.0.1:\(port)/mcp"
            }
          }
        }
        """
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(snippet, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { copied = false }
        }
    }
}
