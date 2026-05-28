import AppKit
import Observation
import SwiftUI

/// Owns the menu-bar `NSStatusItem` and its drop-down `NSMenu`. The menu is
/// built once in `init`; `menuNeedsUpdate` only mutates the existing items
/// (toggle states, titles, the pre-allocated email-row pool) so the embedded
/// search field never gets torn down and loses keyboard focus mid-type.
///
/// Email rows are driven straight off `IndexDB.search`: `is:unread` when the
/// search field is empty, otherwise the user's query. Bodies are never loaded
/// here — "Open in Mail" is the path for actually reading a message.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: MailModel
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    /// Max email rows shown — also the SQL LIMIT.
    private static let maxEmails = 20
    private static let menuWidth: CGFloat = 460

    // Persistent items mutated on each open.
    private let markAllItem = NSMenuItem()
    private let mcpTunnelItem = NSMenuItem()
    private let mcpItem = NSMenuItem()
    private let tunnelOpenItem = NSMenuItem()
    private let approvalItem = NSMenuItem()
    private let searchView = MenuSearchFieldView(width: StatusItemController.menuWidth)
    private let placeholderItem = NSMenuItem()
    private var emailItems: [NSMenuItem] = []
    private var emailRowViews: [MenuEmailRowView] = []

    // Cached query results backing the email rows.
    private var emails: [MessageHeader] = []
    private var currentSearchText = ""
    private var refreshTask: Task<Void, Never>?

    /// Row ids the user has ticked in the current open session. Cleared each
    /// time the menu opens or the search text changes. Drives whether the top
    /// command reads "Mark all as read" (empty) or "Mark N as read".
    private var selectedRowIds: Set<Int> = []

    /// Settings window, created on first open and reused (see `openSettings`).
    private var settingsWindow: NSWindow?

    init(model: MailModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "envelope", accessibilityDescription: "FMail")
            button.imagePosition = .imageLeading
        }
        buildMenu()
        statusItem.menu = menu
        updateStatusBadge()
        observeUnreadCount()
    }

    // MARK: — Menu construction (once)

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        markAllItem.title = "Mark all as read"
        markAllItem.target = self
        markAllItem.action = #selector(markAllAsRead)
        menu.addItem(markAllItem)

        // MCP + the (more sensitive) tunnel live together under one item so
        // the tunnel's running state is visible at the top level via the
        // parent's checkmark.
        mcpTunnelItem.title = "MCP/Tunnel"
        let subMenu = NSMenu()
        subMenu.autoenablesItems = false
        mcpItem.title = "MCP"
        mcpItem.target = self
        mcpItem.action = #selector(toggleMCP)
        subMenu.addItem(mcpItem)
        tunnelOpenItem.title = "Open tunnel"
        tunnelOpenItem.target = self
        tunnelOpenItem.action = #selector(toggleTunnel)
        subMenu.addItem(tunnelOpenItem)
        approvalItem.title = "Open approval window"
        approvalItem.target = self
        approvalItem.action = #selector(toggleApproval)
        subMenu.addItem(approvalItem)
        mcpTunnelItem.submenu = subMenu
        menu.addItem(mcpTunnelItem)

        let searchItem = NSMenuItem()
        searchItem.view = searchView
        searchView.onChange = { [weak self] text in
            self?.currentSearchText = text
            self?.selectedRowIds.removeAll()
            self?.refreshEmails()
        }
        menu.addItem(searchItem)

        menu.addItem(.separator())

        placeholderItem.isEnabled = false
        placeholderItem.isHidden = true
        menu.addItem(placeholderItem)

        for _ in 0..<Self.maxEmails {
            let item = NSMenuItem()
            let row = MenuEmailRowView(width: Self.menuWidth)
            item.view = row
            item.isHidden = true
            emailItems.append(item)
            emailRowViews.append(row)
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit FMail", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    // MARK: — NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Fresh start every open: clear the search field (programmatic set
        // doesn't fire controlTextDidChange) so the list shows unread, and
        // drop any prior tick selection.
        searchView.field.stringValue = ""
        currentSearchText = ""
        selectedRowIds.removeAll()

        let tunnelLive = model.tunnel.state.isLive
        mcpItem.state = MCPSettings.enabled ? .on : .off
        tunnelOpenItem.state = tunnelLive ? .on : .off
        tunnelOpenItem.title = tunnelOpenTitle()
        approvalItem.state = OAuthStore.shared.approvalWindowIsOpen ? .on : .off
        // Parent checkmark tracks the tunnel only — it's the sensitive,
        // publicly-exposed state. A check here means "tunnel live"; the title
        // spells it out too.
        mcpTunnelItem.state = tunnelLive ? .on : .off
        mcpTunnelItem.title = tunnelLive ? "MCP/Tunnel — Tunnel live" : "MCP/Tunnel"

        updateEmailItems()   // show cached rows instantly
        refreshEmails()      // refresh from the current index

        // Reconcile read/unread against Mail.app's Envelope Index, then
        // refresh again — so marking read/unread in Mail.app shows up as soon
        // as the menu is opened rather than waiting for the next full sync.
        Task { @MainActor in
            await model.syncCoordinator?.syncReadFlagsNow()
            self.refreshEmails()
            self.updateStatusBadge()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        refreshTask?.cancel()
    }

    // MARK: — Email rows

    private func refreshEmails() {
        refreshTask?.cancel()
        let query = currentSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshTask = Task { @MainActor in
            let results = await fetchEmails(query: query)
            if Task.isCancelled { return }
            self.emails = results
            self.updateEmailItems()
            // Keep the menu-bar count in step with the list — recompute the
            // unread total from the same index state the rows came from, so
            // the badge can't lag behind the visible rows.
            if let count = try? await self.model.indexDB?.countAllUnreadExcludingDrafts() {
                if Task.isCancelled { return }
                self.model.allUnreadCount = count
                self.updateStatusBadge()
            }
        }
    }

    private func fetchEmails(query: String) async -> [MessageHeader] {
        guard let db = model.indexDB else { return [] }
        let source = query.isEmpty ? "is:unread" : query
        let compiled = Evaluator.compile(QueryParser.parse(source))
        guard compiled.hasAnyConstraint else { return [] }
        return (try? await db.search(compiled, limit: Self.maxEmails)) ?? []
    }

    private func updateEmailItems() {
        // Drop selections for rows no longer in the list (e.g. after refresh).
        let visibleIds = Set(emails.map(\.rowId))
        selectedRowIds.formIntersection(visibleIds)

        for (i, item) in emailItems.enumerated() {
            if i < emails.count {
                let msg = emails[i]
                configure(row: emailRowViews[i], with: msg)
                item.submenu = makeEmailActionsMenu(for: msg)
                item.isHidden = false
            } else {
                item.isHidden = true
                item.submenu = nil
            }
        }
        if emails.isEmpty {
            placeholderItem.isHidden = false
            configurePlaceholder()
        } else {
            placeholderItem.isHidden = true
            placeholderItem.isEnabled = false
            placeholderItem.target = nil
            placeholderItem.action = nil
        }
        updateMarkAllItem()
    }

    private func configure(row: MenuEmailRowView, with msg: MessageHeader) {
        row.configure(title: rowTitle(for: msg), selected: selectedRowIds.contains(msg.rowId))
        row.onToggleSelect = { [weak self] in self?.toggleSelection(msg.rowId) }
    }

    /// Top command: "Mark all as read" (acts on every displayed unread row)
    /// when nothing is ticked, otherwise "Mark N as read" (acts on the ticks).
    private func updateMarkAllItem() {
        let n = selectedRowIds.count
        if n > 0 {
            markAllItem.title = "Mark \(n) as read"
            markAllItem.isEnabled = true
        } else {
            markAllItem.title = "Mark all as read"
            markAllItem.isEnabled = emails.contains { !$0.isRead } || model.allUnreadCount > 0
        }
    }

    private func toggleSelection(_ rowId: Int) {
        if selectedRowIds.contains(rowId) {
            selectedRowIds.remove(rowId)
        } else {
            selectedRowIds.insert(rowId)
        }
        // The checkbox flipped its own state; only the top command needs
        // updating. A full rebuild here would fight the menu's open state.
        updateMarkAllItem()
    }

    private func makeEmailActionsMenu(for msg: MessageHeader) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false

        let open = NSMenuItem(title: "Open in Mail", action: #selector(openInMail(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = msg
        open.isEnabled = (msg.rfcMessageId?.isEmpty == false)
        sub.addItem(open)

        for (title, sel) in [
            ("Reply", #selector(replyToMessage(_:))),
            ("Reply All", #selector(replyAllToMessage(_:))),
            ("Forward", #selector(forwardMessage(_:))),
        ] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            item.representedObject = msg
            sub.addItem(item)
        }

        sub.addItem(.separator())
        for line in detailLines(for: msg) {
            let detail = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            detail.isEnabled = false
            sub.addItem(detail)
        }
        return sub
    }

    private func configurePlaceholder() {
        switch model.loadState {
        case .fdaDenied:
            placeholderItem.title = "Grant Full Disk Access…"
            placeholderItem.isEnabled = true
            placeholderItem.target = self
            placeholderItem.action = #selector(openFullDiskAccess)
        case .indexing:
            placeholderItem.title = "Indexing…"
            placeholderItem.isEnabled = false
        case .bootstrapping, .idle:
            placeholderItem.title = "Loading…"
            placeholderItem.isEnabled = false
        case .noMailData:
            placeholderItem.title = "No Mail data found"
            placeholderItem.isEnabled = false
        case .failed:
            placeholderItem.title = "Couldn't load mail"
            placeholderItem.isEnabled = false
        case .ready:
            placeholderItem.title = currentSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "No unread messages"
                : "No results"
            placeholderItem.isEnabled = false
        }
        if !placeholderItem.isEnabled {
            placeholderItem.target = nil
            placeholderItem.action = nil
        }
    }

    // MARK: — Row / detail formatting

    /// Checkbox title for a row: an accent-colored dot prefix when unread,
    /// then "Sender — Subject".
    private func rowTitle(for msg: MessageHeader) -> NSAttributedString {
        let sender = msg.senderDisplay.isEmpty ? msg.senderAddress : msg.senderDisplay
        let subject = msg.subject.isEmpty ? "(no subject)" : msg.subject
        // Backstop cutoff for pathological subjects; the row also truncates
        // visually at the menu's edge.
        let text = truncate("\(sender) — \(subject)", to: 90)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .left
        let out = NSMutableAttributedString()
        if !msg.isRead {
            out.append(NSAttributedString(
                string: "● ",
                attributes: [.foregroundColor: NSColor.controlAccentColor, .paragraphStyle: paragraph]
            ))
        }
        out.append(NSAttributedString(
            string: text,
            attributes: [.foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        ))
        return out
    }

    private func detailLines(for msg: MessageHeader) -> [String] {
        var lines: [String] = []
        let from = msg.senderDisplay.isEmpty
            ? msg.senderAddress
            : "\(msg.senderDisplay) <\(msg.senderAddress)>"
        lines.append("From: \(from)")
        if let to = accountEmail(forMailbox: msg.mailboxRowId) {
            lines.append("To: \(to)")
        }
        if let date = msg.dateReceived ?? msg.dateSent {
            lines.append("Date: \(Self.dateFormatter.string(from: date))")
        }
        return lines
    }

    private func accountEmail(forMailbox mailboxRowId: Int) -> String? {
        guard let mbox = model.mailboxes.first(where: { $0.rowId == mailboxRowId }) else { return nil }
        return model.accounts.first(where: { $0.uuid == mbox.accountUUID })?.emailAddress
    }

    private func tunnelOpenTitle() -> String {
        switch model.tunnel.state {
        case .off:      return "Open tunnel"
        case .starting: return "Open tunnel (starting…)"
        case .running:  return "Open tunnel"
        case .stopping: return "Open tunnel (stopping…)"
        case .error:    return "Open tunnel (error)"
        }
    }

    private func truncate(_ s: String, to max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }

    // MARK: — Actions

    /// Mark the ticked rows when any are selected, otherwise every displayed
    /// unread row.
    @objc private func markAllAsRead() {
        let rowids = selectedRowIds.isEmpty
            ? emails.filter { !$0.isRead }.map(\.rowId)
            : Array(selectedRowIds)
        guard !rowids.isEmpty else { return }
        selectedRowIds.removeAll()
        Task { @MainActor in
            _ = await model.readStatus.setReadStatus(rowids: rowids, isRead: true)
            self.refreshEmails()
            self.updateStatusBadge()
        }
    }

    @objc private func toggleMCP() {
        MCPSettings.enabled.toggle()
        model.applyMCPSettings()
        // The tunnel can't function without MCP — switching MCP off tears the
        // (sensitive, publicly-exposed) tunnel down with it.
        if !MCPSettings.enabled, model.tunnel.state.isLive {
            Task { @MainActor in await model.tunnel.stop() }
        }
    }

    @objc private func toggleTunnel() {
        Task { @MainActor in
            if model.tunnel.state.isLive {
                await model.tunnel.stop()
                return
            }
            // The tunnel can't run without the MCP server. If MCP isn't up
            // yet, switch it on and wait for it to start — otherwise
            // tunnel.start() refuses with `.mcpNotRunning`.
            if !isMCPRunning {
                MCPSettings.enabled = true
                model.applyMCPSettings()
                for _ in 0..<30 {
                    if isMCPRunning { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            await model.tunnel.start()
        }
    }

    private var isMCPRunning: Bool {
        if case .running = model.mcpServerStatus { return true }
        return false
    }

    @objc private func toggleApproval() {
        let store = OAuthStore.shared
        if store.approvalWindowIsOpen {
            store.closeApprovalWindow()
        } else {
            store.openApprovalWindow()
        }
    }

    @objc private func openInMail(_ sender: NSMenuItem) {
        guard let msg = sender.representedObject as? MessageHeader else { return }
        model.openInMailApp(msg)
    }

    @objc private func replyToMessage(_ sender: NSMenuItem) { compose(sender, kind: .reply) }
    @objc private func replyAllToMessage(_ sender: NSMenuItem) { compose(sender, kind: .replyAll) }
    @objc private func forwardMessage(_ sender: NSMenuItem) { compose(sender, kind: .forward) }

    private func compose(_ sender: NSMenuItem, kind: MailScripter.ComposeKind) {
        guard let msg = sender.representedObject as? MessageHeader,
              let entry = batchEntry(for: msg) else { return }
        Task { _ = await MailScripter.composeViaMailApp(entry, kind: kind) }
    }

    /// Host Settings in a real AppKit window. The SwiftUI `Settings` scene's
    /// `showSettingsWindow:` action doesn't fire for an `LSUIElement` accessory
    /// app (no key window / no main menu to route through), so we own the
    /// window directly and reuse it across opens.
    @objc private func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: MinimalSettingsView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "FMail Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }

    @objc private func openFullDiskAccess() {
        FullDiskAccess.openSystemSettings()
    }

    private func batchEntry(for msg: MessageHeader) -> MailScripter.BatchEntry? {
        guard let mbox = model.mailboxes.first(where: { $0.rowId == msg.mailboxRowId }) else { return nil }
        let email = model.accounts.first(where: { $0.uuid == mbox.accountUUID })?.emailAddress
        return MailScripter.BatchEntry(
            rfcMessageId: msg.rfcMessageId ?? "",
            appleRowId: msg.rowId,
            accountEmail: email,
            mailboxPathComponents: mbox.pathComponents
        )
    }

    // MARK: — Status-item badge

    /// Keep the menu-bar unread count live even while the menu is closed by
    /// re-arming observation each time `allUnreadCount` changes.
    private func observeUnreadCount() {
        withObservationTracking {
            _ = model.allUnreadCount
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.updateStatusBadge()
                self.refreshEmails()
                self.observeUnreadCount()
            }
        }
    }

    private func updateStatusBadge() {
        guard let button = statusItem.button else { return }
        let count = model.allUnreadCount
        button.title = count > 0 ? " \(min(count, 999))" : ""
    }

    // MARK: — Helpers

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d, yyyy 'at' hh:mm:ss a"
        return f
    }()
}
