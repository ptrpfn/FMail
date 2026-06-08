import AppKit
import SwiftUI

/// Settings for the menu-bar build, split into two tabs:
///   - **Connection**: the values you set once — MCP port, auth token, tunnel
///     routing, paired sessions.
///   - **Priority Messages**: who lands in the menu's "Priority Messages" block.
struct MinimalSettingsView: View {
    let model: MailModel

    var body: some View {
        TabView {
            ConnectionSettingsView()
                .tabItem { Label("Connection", systemImage: "network") }
            PrioritySettingsView(model: model)
                .tabItem { Label("Priority Messages", systemImage: "star") }
        }
        // Inset the TabView so its content-box border reads as a proper frame
        // (rather than a stray line flush under the title bar) and the tab bar
        // sits a little below the title bar.
        .padding(20)
        .frame(width: 560, height: 700)
    }
}

// MARK: — Connection tab

/// MCP / tunnel / OAuth settings. Deliberately excludes anything already
/// controlled from the menu (MCP on/off, tunnel open, approval window).
private struct ConnectionSettingsView: View {
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
    }
}

// MARK: — Priority Messages tab

/// Edit who counts as a priority sender. Everyone you've emailed is included
/// automatically (shown greyed, can't be removed); below that you can add
/// specific addresses or `*wildcard*` patterns.
private struct PrioritySettingsView: View {
    let model: MailModel

    @State private var userEntries: [String] = PriorityListSettings.supplementalAddresses
    @State private var autoSenders: [String] = []
    @State private var recentSenders: [RecentSender] = []
    @State private var showingAdd = false
    @State private var newText = ""
    @State private var loaded = false

    /// Auto addresses the user hasn't also added by hand (avoids showing the
    /// same address as both removable and greyed).
    private var autoOnly: [String] {
        let added = Set(userEntries.map { $0.lowercased() })
        return autoSenders.filter { !added.contains($0.lowercased()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Priority senders").font(.headline)
                Spacer()
                Button {
                    withAnimation { showingAdd.toggle() }
                } label: {
                    Image(systemName: showingAdd ? "minus" : "plus")
                }
                .help("Add addresses or wildcard patterns")
            }

            if showingAdd { addArea }

            List {
                Section("Added") {
                    if userEntries.isEmpty {
                        Text("None yet — use the + button to add senders or patterns.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(userEntries, id: \.self) { entry in
                            HStack {
                                Image(systemName: PriorityListSettings.isPattern(entry) ? "asterisk" : "person.crop.circle")
                                    .foregroundStyle(.secondary)
                                Text(entry)
                                Spacer()
                                Button(role: .destructive) {
                                    remove(entry)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove")
                            }
                        }
                    }
                }

                Section("From people you've emailed (\(autoOnly.count))") {
                    if autoOnly.isEmpty {
                        Text(loaded ? "No sent mail found yet." : "Loading…")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(autoOnly, id: \.self) { addr in
                            Text(addr).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            Text("Unread mail from these senders is grouped under “Priority Messages”; everything else goes under “Other Messages”. People you've emailed are always included and can't be removed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .task { await load() }
    }

    private var addArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("alice@example.com; *savills*", text: $newText)
                .textFieldStyle(.roundedBorder)
            HStack {
                if recentSenders.isEmpty {
                    Text("No recent senders").font(.caption).foregroundStyle(.secondary)
                } else {
                    Menu("Add from recent…") {
                        ForEach(recentSenders) { sender in
                            Button(sender.label) { append(sender.address) }
                        }
                    }
                    .frame(maxWidth: 240)
                }
                Spacer()
                Button("Cancel") {
                    newText = ""
                    withAnimation { showingAdd = false }
                }
                Button("Add") { commitAdd() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(PriorityListSettings.parse(newText).isEmpty)
            }
            Text("Separate several with “;”. A full address matches exactly; a word or domain (savills, ubs.com) matches any address containing it; or use * / ? wildcards (e.g. *@savills.com).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: — Actions

    private func append(_ address: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            newText = address
        } else if trimmed.hasSuffix(";") {
            newText = trimmed + " " + address
        } else {
            newText = trimmed + "; " + address
        }
    }

    private func commitAdd() {
        let additions = PriorityListSettings.parse(newText)
        guard !additions.isEmpty else { return }
        userEntries = PriorityListSettings.add(additions)
        newText = ""
        withAnimation { showingAdd = false }
        Task { await model.refreshPrioritySenders() }
    }

    private func remove(_ entry: String) {
        userEntries = PriorityListSettings.remove(entry)
        Task { await model.refreshPrioritySenders() }
    }

    private func load() async {
        guard let db = model.indexDB else { loaded = true; return }
        let auto = (try? await db.sentToAddresses()) ?? []
        let recent = (try? await db.recentReceivedFromAddresses(limit: 20)) ?? []
        autoSenders = auto.sorted()
        recentSenders = recent
        loaded = true
    }
}
