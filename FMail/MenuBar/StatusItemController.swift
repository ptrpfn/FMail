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

    /// Max rows shown per block — also the per-block SQL LIMIT.
    private static let maxPerBlock = 15
    private static let menuWidth: CGFloat = 460

    // Persistent items mutated on each open.
    // Per-block "Mark all …" commands, shown when nothing is ticked.
    private let markPriorityReadItem = NSMenuItem()
    private let markPriorityUnreadItem = NSMenuItem()
    private let markOtherReadItem = NSMenuItem()
    private let markOtherUnreadItem = NSMenuItem()
    // Selection commands, shown instead while one or more rows are ticked.
    private let markSelReadItem = NSMenuItem()
    private let markSelUnreadItem = NSMenuItem()
    private let mcpTunnelItem = NSMenuItem()
    private let mcpItem = NSMenuItem()
    private let tunnelOpenItem = NSMenuItem()
    private let approvalItem = NSMenuItem()
    private let searchView = MenuSearchFieldView(width: StatusItemController.menuWidth)
    private let placeholderItem = NSMenuItem()

    /// The two list sections. Each is a "Priority/Other Messages" divider over a
    /// pre-allocated pool of (date sub-header + row) pairs. Pairing one header
    /// per row keeps menu mutation to title/`isHidden` toggles — the in-place
    /// pattern that avoids disturbing the embedded search field.
    private let priorityBlock = MenuBlock(width: StatusItemController.menuWidth, capacity: StatusItemController.maxPerBlock)
    private let otherBlock = MenuBlock(width: StatusItemController.menuWidth, capacity: StatusItemController.maxPerBlock)

    // Cached query results backing each block's rows.
    private var priorityEmails: [MessageHeader] = []
    private var otherEmails: [MessageHeader] = []
    private var currentSearchText = ""
    private var refreshTask: Task<Void, Never>?

    /// Row ids the user has ticked in the current open session. Cleared each
    /// time the menu opens or the search text changes. Drives whether the top
    /// commands read "Mark all as read/unread" (empty) or "Mark N as
    /// read/unread", and which of the two is enabled.
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

        configureMarkItem(markPriorityReadItem, "Mark all Priority Messages as read", #selector(markPriorityRead))
        configureMarkItem(markPriorityUnreadItem, "Mark all Priority Messages as unread", #selector(markPriorityUnread))
        configureMarkItem(markOtherReadItem, "Mark all Other Messages as read", #selector(markOtherRead))
        configureMarkItem(markOtherUnreadItem, "Mark all Other Messages as unread", #selector(markOtherUnread))
        configureMarkItem(markSelReadItem, "Mark as read", #selector(markSelectionRead))
        configureMarkItem(markSelUnreadItem, "Mark as unread", #selector(markSelectionUnread))
        for item in [markPriorityReadItem, markPriorityUnreadItem,
                     markOtherReadItem, markOtherUnreadItem,
                     markSelReadItem, markSelUnreadItem] {
            menu.addItem(item)
        }

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

        priorityBlock.addItems(to: menu)
        otherBlock.addItems(to: menu)

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
            let split = await fetchSplit(query: query)
            if Task.isCancelled { return }
            self.priorityEmails = split.priority
            self.otherEmails = split.other
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

    /// The active source compiled for the DB: `is:unread` when the search field
    /// is empty, otherwise the user's query.
    private func compiledSource() -> CompiledQuery? {
        let query = currentSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = query.isEmpty ? "is:unread" : query
        let compiled = Evaluator.compile(QueryParser.parse(source))
        return compiled.hasAnyConstraint ? compiled : nil
    }

    private func fetchSplit(query: String) async -> (priority: [MessageHeader], other: [MessageHeader]) {
        guard let db = model.indexDB, let compiled = compiledSource() else { return ([], []) }
        return (try? await db.searchSplitByPriority(compiled, limitPerBlock: Self.maxPerBlock)) ?? ([], [])
    }

    private func updateEmailItems() {
        // Drop selections for rows no longer in either list (e.g. after refresh).
        let visibleIds = Set((priorityEmails + otherEmails).map(\.rowId))
        selectedRowIds.formIntersection(visibleIds)

        updateBlock(priorityBlock, title: "Priority Messages", emails: priorityEmails)
        updateBlock(otherBlock, title: "Other Messages", emails: otherEmails)

        if priorityEmails.isEmpty && otherEmails.isEmpty {
            placeholderItem.isHidden = false
            configurePlaceholder()
        } else {
            placeholderItem.isHidden = true
            placeholderItem.isEnabled = false
            placeholderItem.target = nil
            placeholderItem.action = nil
        }
        updateMarkItems()
    }

    /// Fill one block's pre-allocated pool: show its divider, then a row per
    /// message with a date sub-header at each new date group. The whole block
    /// hides when it has no messages.
    private func updateBlock(_ block: MenuBlock, title: String, emails: [MessageHeader]) {
        guard !emails.isEmpty else { block.hideAll(); return }
        block.headerView.configure(title: title)
        block.headerItem.isHidden = false

        var prevGroup: String?
        for i in block.rowItems.indices {
            guard i < emails.count else {
                block.dateItems[i].isHidden = true
                block.rowItems[i].isHidden = true
                block.rowItems[i].submenu = nil
                continue
            }
            let msg = emails[i]
            // Date sub-header: shown only when this row opens a new group
            // (each block is already newest-first).
            let group = Self.dateGroupLabel(for: msg.dateReceived ?? msg.dateSent)
            if group != prevGroup {
                block.dateViews[i].configure(title: group)
                block.dateItems[i].isHidden = false
            } else {
                block.dateItems[i].isHidden = true
            }
            prevGroup = group

            configure(row: block.rowViews[i], with: msg)
            block.rowItems[i].submenu = makeEmailActionsMenu(for: msg)
            block.rowItems[i].isHidden = false
        }
    }

    private func configure(row: MenuEmailRowView, with msg: MessageHeader) {
        row.configure(title: rowTitle(for: msg), selected: selectedRowIds.contains(msg.rowId))
        row.onToggleSelect = { [weak self] in self?.toggleSelection(msg.rowId) }
    }

    /// Displayed messages the user has ticked (across both blocks).
    private var actionableMessages: [MessageHeader] {
        (priorityEmails + otherEmails).filter { selectedRowIds.contains($0.rowId) }
    }

    /// Top commands. With nothing ticked: the four per-block "Mark all …"
    /// commands, each enabled only when its block has a message in the opposite
    /// state. With rows ticked: a single "Mark N as read/unread" pair acting on
    /// the ticks (the per-block commands hide). Either way, a command is
    /// disabled when it would be a no-op.
    private func updateMarkItems() {
        let n = selectedRowIds.count
        let selecting = n > 0

        markSelReadItem.isHidden = !selecting
        markSelUnreadItem.isHidden = !selecting
        for item in [markPriorityReadItem, markPriorityUnreadItem, markOtherReadItem, markOtherUnreadItem] {
            item.isHidden = selecting
        }

        if selecting {
            let set = actionableMessages
            markSelReadItem.title = "Mark \(n) as read"
            markSelReadItem.isEnabled = set.contains { !$0.isRead }
            markSelUnreadItem.title = "Mark \(n) as unread"
            markSelUnreadItem.isEnabled = set.contains { $0.isRead }
        } else {
            markPriorityReadItem.isEnabled = priorityEmails.contains { !$0.isRead }
            markPriorityUnreadItem.isEnabled = priorityEmails.contains { $0.isRead }
            markOtherReadItem.isEnabled = otherEmails.contains { !$0.isRead }
            markOtherUnreadItem.isEnabled = otherEmails.contains { $0.isRead }
        }
    }

    private func toggleSelection(_ rowId: Int) {
        if selectedRowIds.contains(rowId) {
            selectedRowIds.remove(rowId)
        } else {
            selectedRowIds.insert(rowId)
        }
        // The checkbox flipped its own state; only the top commands need
        // updating. A full rebuild here would fight the menu's open state.
        updateMarkItems()
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
        let subjectItem = NSMenuItem()
        subjectItem.attributedTitle = subjectDetailTitle(for: msg)
        subjectItem.isEnabled = false
        sub.addItem(subjectItem)
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
        // Only real file attachments reach here — inline signature images are
        // filtered out when `has_attachment` is computed at index time.
        if msg.hasAttachment {
            lines.append("📎 Has attachments")
        }
        return lines
    }

    /// Multi-line "Subject: …" title for the actions submenu, soft-wrapped so a
    /// long subject stays readable (a plain menu item would truncate it). The
    /// row above shows a one-line, sender-prefixed truncation; this is the full
    /// text.
    private func subjectDetailTitle(for msg: MessageHeader) -> NSAttributedString {
        let subject = msg.subject.isEmpty ? "(no subject)" : msg.subject
        let wrapped = Self.softWrap("Subject: \(subject)", width: 58)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: wrapped, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
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

    private func configureMarkItem(_ item: NSMenuItem, _ title: String, _ action: Selector) {
        item.title = title
        item.target = self
        item.action = action
    }

    /// Soft-wrap on word boundaries to `width` columns, hard-breaking any single
    /// word longer than the column budget. Returns the lines joined by "\n".
    private static func softWrap(_ s: String, width: Int) -> String {
        var lines: [String] = []
        var current = ""
        for word in s.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
            var word = word
            // A single over-long word: emit full-width chunks, keep the tail.
            while word.count > width {
                if !current.isEmpty { lines.append(current); current = "" }
                lines.append(String(word.prefix(width)))
                word = String(word.dropFirst(width))
            }
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\n")
    }

    /// Bucket a message's date into a list separator label: "Today",
    /// "Yesterday", an explicit "5 Jun 26" for the rest of the past week, then
    /// a single "Older than a week" bucket. Future-dated mail (clock skew)
    /// folds into "Today".
    private static func dateGroupLabel(for date: Date?) -> String {
        guard let date else { return "Unknown date" }
        let cal = Calendar.current
        let days = cal.dateComponents(
            [.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())
        ).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days <= 7 { return groupDateFormatter.string(from: date) }
        return "Older than a week"
    }

    // MARK: — Actions

    @objc private func markPriorityRead() { markBlock(priority: true, isRead: true) }
    @objc private func markPriorityUnread() { markBlock(priority: true, isRead: false) }
    @objc private func markOtherRead() { markBlock(priority: false, isRead: true) }
    @objc private func markOtherUnread() { markBlock(priority: false, isRead: false) }
    @objc private func markSelectionRead() { markSelection(isRead: true) }
    @objc private func markSelectionUnread() { markSelection(isRead: false) }

    /// Flip *every* message in the given block (not just the visible rows) that
    /// matches the active source and is in the opposite state. The rowids are
    /// re-queried so "Mark all" really means all, even past the display cap.
    private func markBlock(priority: Bool, isRead: Bool) {
        guard let db = model.indexDB, let compiled = compiledSource() else { return }
        selectedRowIds.removeAll()
        Task { @MainActor in
            let rowids = (try? await db.rowidsMatching(compiled, priority: priority, isRead: !isRead)) ?? []
            guard !rowids.isEmpty else { return }
            _ = await model.readStatus.setReadStatus(rowids: rowids, isRead: isRead)
            self.refreshEmails()
            self.updateStatusBadge()
        }
    }

    /// Flip the ticked rows to `isRead`, touching only those that need it.
    private func markSelection(isRead: Bool) {
        let rowids = actionableMessages.filter { $0.isRead != isRead }.map(\.rowId)
        guard !rowids.isEmpty else { return }
        selectedRowIds.removeAll()
        Task { @MainActor in
            _ = await model.readStatus.setReadStatus(rowids: rowids, isRead: isRead)
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

    /// Compact date for the list separators, e.g. "5 Jun 26".
    private static let groupDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yy"
        return f
    }()
}

/// One list section ("Priority Messages" / "Other Messages") and its
/// pre-allocated item pool: a block divider, then `capacity` (date sub-header +
/// row) pairs. Items are created once and reused via `isHidden`/title toggles so
/// the menu never tears views down mid-open. The owning controller drives the
/// content; this type only owns the items and their menu placement.
@MainActor
final class MenuBlock {
    let headerItem = NSMenuItem()
    let headerView: MenuSectionHeaderView
    private(set) var dateItems: [NSMenuItem] = []
    private(set) var dateViews: [MenuSectionHeaderView] = []
    private(set) var rowItems: [NSMenuItem] = []
    private(set) var rowViews: [MenuEmailRowView] = []

    init(width: CGFloat, capacity: Int) {
        headerView = MenuSectionHeaderView(width: width, style: .block)
        headerItem.view = headerView
        headerItem.isEnabled = false
        headerItem.isHidden = true

        for _ in 0..<capacity {
            let dateItem = NSMenuItem()
            let dateView = MenuSectionHeaderView(width: width, style: .date)
            dateItem.view = dateView
            dateItem.isEnabled = false
            dateItem.isHidden = true
            dateItems.append(dateItem)
            dateViews.append(dateView)

            let rowItem = NSMenuItem()
            let rowView = MenuEmailRowView(width: width)
            rowItem.view = rowView
            rowItem.isHidden = true
            rowItems.append(rowItem)
            rowViews.append(rowView)
        }
    }

    /// Append the divider and every (date, row) pair to the menu, in order.
    func addItems(to menu: NSMenu) {
        menu.addItem(headerItem)
        for i in rowItems.indices {
            menu.addItem(dateItems[i])
            menu.addItem(rowItems[i])
        }
    }

    /// Hide the whole block (empty result).
    func hideAll() {
        headerItem.isHidden = true
        for i in rowItems.indices {
            dateItems[i].isHidden = true
            rowItems[i].isHidden = true
            rowItems[i].submenu = nil
        }
    }
}
