# FMail — Implementation status

Companion to `FMailSpec.md`. The spec captures the design intent; this file captures **what's actually shipped**, what diverges from the spec, and what's left.

Last updated: 2026-05-09 (window-UI era).

> **⚠️ Current UI is menu-bar-only.** Everything below documents the three-pane **window** app, now
> preserved on the [`window-UI`](../../tree/window-UI) branch. `master` ships a **menu-bar** build: a
> status-bar dropdown with the unread/search list (multi-select mark-as-read), per-email
> Open-in-Mail / Reply / Reply All / Forward via Mail.app's native AppleScript commands, and an
> MCP/Tunnel submenu. Removed in the menu-bar build: `AppShell`, the sidebar/thread-list/reader views,
> `HTMLBodyView`, `ReplyConfirmationSheet`, `ContactsService`, the `mailto:` `MailComposer`, and
> contact-prefs. Added: `MenuBar/{AppDelegate, StatusItemController, MenuEmailRowView,
> MenuSearchFieldView, MinimalSettingsView}.swift`, a flag-only read/unread reconcile on menu open,
> host-aware MCP OAuth discovery, and MCP **on by default**. The index / search DSL / threading / MCP
> data layer is unchanged. Current behaviour and setup: [README.md](README.md).

---

## Where each spec pain point stands

| Spec pain point | Status | Where it landed |
|---|---|---|
| #1 Drifting unread counts | **Solved** | Phase 1 (compute from `.emlx` flags), refined in Phase 2 (recompute from our own DB on every sync) |
| #2 Weak search | **Solved** | Phase 3 (FTS5 + DSL with `from:` / `to:` / `subject:` / `body:` / `before:` / `after:` / `during:` / `is:` / `has:` / boolean / phrases) |
| #3 Wrong recipient address | **Solved** | Phase 4 (Contacts integration + per-contact preferred-address overrides + reply confirmation dialog) |
| #4 Illegible thread view | **Mostly solved** | Phase 2 (threading via union-find on Apple's `message_references`) + Phase 3 (single-column stacked thread reader with time-deltas, expand-on-click, unread tinting) + Phase 5 (HTML rendering in locked-down WKWebView). Spec §8 items still open: quote folding, `N` next-unread shortcut, two-column variant, `cid:` inline-image resolution. |

FMail is daily-driver capable today. Remaining work is Phase 5 polish.

---

## Phases as actually implemented

The spec's Phase 2 "Index & search" was split into our Phase 2 (index + threading) and Phase 3 (search). The spec's Phase 3 "Threads & contacts" was split — threading went into our Phase 2, contacts into Phase 4 alongside compose handoff.

### Phase 0 — Skeleton + access validation ✅
Goal: prove the two access paths the project depends on.

Files added:
- `FMailApp.swift`
- `Permissions/FullDiskAccessFlow.swift`
- `MailStore/EnvelopeIndexReader.swift` (Phase 0 form — superseded later)
- `MailStore/MailStoreEnumerator.swift`
- `Core/Emlx/EmlxParser.swift` (subject-only stub)
- `UI/AppShell.swift`, `UI/Phase0DiagnosticView.swift` (later removed)
- Project shell via `xcodegen` + `project.yml`, `.gitignore`
- `FMailTests/Phase0Tests.swift`

Verification: shipped diagnostic view showing `~/Library/Mail/V10` path, message count from Envelope Index, first `.emlx` Subject. Confirmed access works while Mail.app is running.

### Phase 1 — Read & browse ✅
Goal: usable read-only viewer with correct unread counts.

Files added/expanded:
- `Core/Emlx/EncodedWord.swift` — RFC 2047 (Q + B) decoding for headers
- `Core/Emlx/HeaderParser.swift` — RFC 5322 line-folding + header parsing
- `Core/Emlx/MIMEParser.swift` — multipart/alternative + multipart/mixed + base64 + quoted-printable
- `Core/Emlx/EmlxParser.swift` — full parse (length prefix → RFC 822 → MIME → flag plist trailer)
- `Core/HTML/HTMLStripper.swift` — non-WebKit HTML→text (entities, common block tags, whitespace collapse)
- `MailStore/MailboxURL.swift` — parses Apple's `imap://<account-uuid>/<path>` mailbox URLs
- `MailStore/MailboxFilter.swift` — hides `[Gmail]/All Mail`, `Recovered Messages*`, `SendLater` by default
- `MailStore/Models.swift` — `MailAccount`, `Mailbox`, `MessageHeader`, `MessageBody`
- `MailStore/EnvelopeIndexReader.swift` — extended with `loadMailboxes`, `loadMessages`, `perMailboxCount`
- `UI/Sidebar/SidebarView.swift`
- `UI/MessageList/MessageListView.swift`
- `UI/Reader/ReaderView.swift`
- `UI/MailModel.swift`

Pain point #1 (counts) closed. UI bug fix during Phase 1: the message list showed "Loading…" indefinitely for empty mailboxes — fixed by separating `isLoading` from `loaded-empty`.

### Phase 2 — Own index + threading + file watcher ✅
Goal: own SQLite index foundation; correct thread grouping; real-time change detection.

Decision: **raw SQLite3 instead of GRDB.swift** (deviation from spec §10) — keeps zero deps. Schema migrations + FTS5 access via `import SQLite3` are verbose but small and fully understood.

Files added:
- `Core/Index/Schema.swift` — versioned schema; v1 created `accounts`, `mailboxes`, `messages`, `recipients`, `message_links`, `threads`, `messages_fts` (FTS5), `index_metadata`. Later v2 added `contact_prefs`. v3 added `message_labels` (Gmail).
- `Core/Index/IndexDB.swift` — actor wrapping our SQLite handle; bulk upserts in transactions of ~2000 rows; read API for the UI.
- `Core/Index/Indexer.swift` — orchestrator. Mirrors Apple's Envelope Index → our DB in chunks. Includes account-name heuristic (most-common-sender from Sent mailboxes; falls back to most-common-recipient).
- `Core/Threading/ThreadGrouper.swift` — union-find over `(message_rowid, parent_message_id_hash)` from Apple's `message_references` table. thread_id = smallest member rowid (deterministic).
- `MailStore/FileWatcher.swift` — `FSEventStream` rooted at `~/Library/Mail/V10/`. 2 s coalescer. Persists `lastEventId` to UserDefaults. Filters to `*.emlx` + `Envelope Index*`.
- `MailStore/BodyLoader.swift` — actor that lazily indexes `.emlx` files per mailbox by ROWID, then parses on demand. (Replaced the body-lookup half of the Phase 1 `MailDataStore`.)

UI rewrites:
- `UI/MailModel.swift` — switched data path from Envelope Index to our IndexDB. Added indexer progress state, sync-coalescing flag.
- `UI/AppShell.swift` — full-screen indexing progress on first launch; bottom footer status during incremental sync.
- `UI/MessageList/MessageListView.swift` — switched to threads list backed by `loadThreadSummaries`.
- `UI/Reader/ReaderView.swift` — single-column stacked thread reader with time-deltas (`+3d`, `+12m`).

Bug fix mid-phase: `IndexDB`'s SQLite handle marked `nonisolated(unsafe)` to allow access in `deinit` (Swift 6 actor-deinit isolation rules). FSEvents callback fixed (was casting eventPaths as CFArray; correct interpretation is `const char **`).

### Phase 3 — Search ✅
Goal: query DSL + FTS5 + body indexing for content search.

Files added:
- `Core/QueryDSL/Token.swift`, `Lexer.swift`, `AST.swift`, `Parser.swift`, `Evaluator.swift`, `DateExpression.swift`
- `Core/Index/BodyIndexer.swift` — actor that walks `.emlx` files for messages where `body_indexed = 0`, parses body, updates the FTS5 row in place (DELETE + INSERT). Resumable across launches.
- `UI/Search/SearchBar.swift` (with interpreted-query strip)
- `UI/Search/SearchResultsView.swift`

Indexer change: now rebuilds `messages_fts` from joined `messages` ⨝ `recipients` at the end of every full sync, so subject + sender + recipients are searchable immediately. Body content becomes searchable progressively as the body indexer sweeps.

Bug fixes during Phase 3:
- FTS5 `MATCH` operator can't accept a table alias on its LHS — changed `FROM messages_fts f WHERE f MATCH ?` to `FROM messages_fts WHERE messages_fts MATCH ?`.
- `MessageListView` was centred (no `frame(maxHeight:.infinity, alignment:.top)`) — fixed.
- Search results used `onTapGesture` with no selection state — switched to `List(selection:)` bound to `selectedSearchResultId` so the highlight persists.
- Apple Mail stores Unix epoch in `date_received`/`date_sent`, not Cocoa epoch (`timeIntervalSinceReferenceDate`) — fixed everywhere (was reading 2024 dates as 2055).
- FTS5 single-token queries didn't match anything (`subject:v` returned no `vermont`) — added implicit `*` prefix on bareword and field-value tokens. Quoted phrases stay exact.
- `during:` operator added (not in original spec) — granular range query whose width matches the precision of the supplied date (`during:2026` = all of 2026, `during:2026-03` = all of March, `during:2026-03-15` = that day).
- `after:` semantics fixed for partial dates so `after:2024` means `>= 2025-01-01` (after the period), not `>= 2024-01-01`.
- No-colon shortcuts added: `hasattachment`, `isunread`, `isread`, `isflagged` map to their field forms.
- Body-indexer now pauses during incremental sync (was racing the indexer's writes through the same SQLite connection — caused a SIGTRAP in `btreeParseCellPtrIndex` on one occasion).
- ReaderView OOB crash fixed (was reading the live `messagesInSelectedThread` array via index from a stale `enumerated()` snapshot when `openFromSearch` mutated it mid-render).

### Phase 4 — Contacts + compose handoff ✅
Goal: pain point #3 (wrong recipient).

Files added:
- `Contacts/ContactsService.swift` — actor wrapping `CNContactStore`; lazy permission request on first reply; in-memory `email → contact` map.
- `Compose/ComposeRequest.swift` — `ComposeRequest` value type + `ReplyBuilder` that turns a `MessageHeader` + `MessageBody` into a request for reply / reply-all / forward.
- `Compose/MailComposer.swift` — `mailto:` URL builder that drives Mail.app via `NSWorkspace.shared.open(url)`. Uses RFC 6068 query parameters (`subject`, `body`, `cc`, `in-reply-to`, `references`).
- `UI/Reader/ReplyConfirmationSheet.swift` — modal sheet showing resolved recipient, contact name, alternate addresses (with picker), "Always reply to X" / "Hide Y from suggestions" checkboxes. Wrong-address-catching mechanic.
- Schema v2: `contact_prefs(contact_id, preferred_address, blocked_addresses JSON)` + helper methods on `IndexDB`.
- `MailModel` extensions: `startReply`, `cancelReply`, `sendReply`, `startNewMail`, `replyDraft` state.
- Reply / Reply-All / Forward toolbar in expanded `MessageBlock` (⌘R, ⌘⇧R, ⌘⌥F).
- Account email addresses now exposed on `MailAccount` (Indexer was already extracting them; now surfaced in the model).
- `Info.plist` (via `project.yml`): `NSContactsUsageDescription`, `NSAppleEventsUsageDescription`.

**Decision: `mailto:` only, not AppleScript.** Spec §10 said `NSAppleScript`; we shipped `mailto:` because (a) RFC 6068 supports everything we need including In-Reply-To/References for threading, (b) no Automation permission prompt, (c) no AppleScript escaping headaches with arbitrary message bodies. Trade-off: Mail.app picks the From-account by heuristic from the original recipient, not from us. If that's wrong in practice, the AppleScript path is still a Phase 5 polish task.

Bug fixes during Phase 4:
- Schema v3 + `message_labels` mirror added: Gmail stores all messages in `[Gmail]/All Mail` (canonical) and uses Apple's `labels` table to map them to virtual mailboxes (INBOX, Important, Sent Mail). Without mirroring labels, Gmail INBOX/Sent Mail/Important showed empty. Now `loadMessagesInMailbox`, `loadThreadSummaries`, `recomputeMailboxCounts`, and the account-naming heuristic all UNION via labels.
- Recipient-heuristic fallback for account naming (handles accounts with mail but no Sent mailbox).
- Quote-builder bug: HTML→text bodies sometimes use CRLF or bare CR; my single-line `split("\n")` saw the whole body as one line and only the first line got the `>` prefix. Now normalises CRLF/CR → LF before splitting.
- Empty quote lines now `>` (not `> `) — matches convention.

### Phase 5 — Polish (ongoing) 🚧
Items already shipped that the original spec put in Phase 5 (chronological-ish order):
- `during:` operator (above and beyond original DSL).
- Per-account email address detection (Sent-mailbox heuristic + recipient-of-incoming fallback).
- Persistent search-result selection.
- "All Mailboxes" virtual mailbox at top of sidebar with global unread count + Dock-tile badge. Auto-selected on launch.
- Drafts/Trash/Junk filtered from "All Mailboxes" + global search results (canonical mailbox + Gmail label).
- App icon (`AppIcon.icns`, multi-size, built via `iconutil`).
- "Open in Mail.app" button per message via `message://` URL scheme — handles "body not yet downloaded" cases. Schema v4 added `rfc_message_id` mirrored from `message_global_data` (FK is `messages.global_message_id` → `mgd.ROWID`).
- Reply toolbar moved to top of each expanded message (so long footers don't push it off-screen).
- **Mark as Read / Mark as Unread** via AppleScript (`osascript` subprocess, targeted to the canonical mailbox to keep Mail.app's lockup window minimal). Optimistic-first: FMail's UI updates instantly; sync is suppressed for 30s to avoid full re-mirror; `osascript` runs in background. Permission-denied (-1743) errors surface a one-click button that opens System Settings → Privacy → Automation.
- Body-text loss bug fixed: incremental FTS update (don't wipe + reinsert each sync); Schema v5 reset of `body_indexed` to recover existing data.
- DSL aliases added for body search (`content:`, `text:`).
- **HTML body rendering** via locked-down `WKWebView` (`Core/UI/Reader/HTMLBodyView.swift`). Strict CSP blocks all network — no tracking pixels, no remote images, no scripts, no fonts. Height auto-measured via `evaluateJavaScript` so the WebView fits naturally inside the outer `ScrollView`. Reload guarded against feedback loops (compares last-loaded `(html, allowRemoteImages)` before reloading).
- **Per-message "Load remote images"** opt-in. CSP relaxes to `img-src data: cid: http: https:` for that one message instance; scripts/iframes/fonts stay blocked. Per-instance state, not persisted — re-opening the same email starts blocked again.
- **Boolean `OR` / `NOT` now compose across all predicate types.** Previously the Evaluator routed text predicates into one FTS5 expression and date/flag/scope predicates into a separate SQL `AND` chain — so `(during:2025 OR during:2023)` silently became `during:2025 AND during:2023` (empty). The Evaluator now compiles each AST node into a uniform SQL boolean fragment: text predicates lift into `apple_rowid IN (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ?)` subqueries, date/flag/scope predicates emit direct `m.*` conditions. Pure-text subtrees still fuse into one MATCH for efficiency. The interpreted-query strip now also shows `(a OR b)` and `-x` in proper form.
- **Bulk-action errors split from body-load errors.** Bulk Mark Read/Unread failures used to set `bodyError`, which the reader rendered inline alongside actual body-load failures (and tried to surface a `-1743` Automation deep-link). Bulk failures now land in `bulkActionError` and surface as a modal `.alert` from `AppShell`, with `bodyError` reserved for the reader's "couldn't read this message's `.emlx`" cases.
- **Internal refactor: god-class split.** `MailModel` (1145 LOC) and `IndexDB` (1170 LOC) were near the top of the file-size list and absorbing too many responsibilities. Refactor split them up:
  - `UI/ReadStatusController.swift` — owns Mark Read / Unread for messages, threads, search results. Holds `unowned MailModel`. Absorbs the per-message and per-thread optimistic-flip siblings, the AppleScript-entry construction (previously duplicated 3×), and the `skipSyncsUntil` window. `MailModel` now exposes thin forwarders for `markSelectedSearchResultsAsRead` / `markSelectedThreadsAsRead`.
  - `Core/Index/IndexModels.swift` — wire types (`IndexedMessage`, `IndexedRecipient`, `IndexedMessageLink`, `IndexedThread`, `ThreadSummary`, `ContactPrefs`) lifted out of `IndexDB.swift`.
  - `Core/Index/IndexDB+ContactPrefs.swift` — contact-prefs CRUD as an actor extension. Required widening `prepare` / `bind` / `bindOptional` / `stepDone` from `private` to internal so the extension can use them.
  - `MailScripter.swift` — `bucketByMailbox`, `buildAccountScopedBlock`, `buildCrossAccountFallback` extracted; `setReadStatusBatch` and `fetchBodies` now share the bucketing + scaffold. Net `setReadStatusBatch` ≈220→30 LOC.
  - `MailStore/EnvelopeIndexReader.swift` — `EnvelopeReadOnly` (production sync reader) merged in from `Indexer.swift`. The Phase-1 `EnvelopeIndexReader` was pruned to its smoke methods (`messageCount`, `mailboxCount`); dead `loadMailboxes` / `perMailboxCount` / `loadMessages` removed.
  - Sidebar selection: `selectAllMailboxes()` / `selectMailbox(_:)` collapse onto one `select(_ s: SidebarSelection)`. `SidebarView`'s `Binding(get:set:)` hand-roll became one line. Existence guard preserved (silent no-op for `.mailbox(id)` on a missing id).
  - `Core/Logging.swift` — central `Log.{sync, mailScripter, fileWatcher, bodyIndexer}` over `os.Logger`. Replaced ad-hoc `print` / `fputs` and surfaced previously-silent FSEventStream failure paths.
  - Cosmetic: dropped dead `MailModel.setReadStatus(_:isRead:)` (single), `applyOptimisticReadFlag` (singular), `MailScripter.setReadStatus` (single) + `makeScript` + `buildMailboxRef`, `MailStoreEnumerator.findFirstEmlx` / `findEmlx`, `EmlxParser.subject(of:)` + `peelLengthPrefix` + the String-overload `splitHeaderBody`. Removed `MIMEParser.splitMultipart` `cursor` vestige.
- **Second internal refactor pass: `MailModel` decomposition + DB-error surfacing + UI-layer dedupe** (commit `ee55b53`).
  - `MailModel` (760 → 675 LOC) split further. New `UI/SyncCoordinator.swift` (123 LOC, `@MainActor`, weak ref to MailModel) owns the file watcher, body-indexer task lifecycle, sync-coalescing flags (`syncInFlight` / `syncRequestedWhileBusy`), `skipSyncsUntil` window, `runIncrementalSync`, and the post-sync `fetchMissingUnreadBodies` prefetch. New `UI/BodyFetchPoller.swift` (30 LOC) owns the on-demand `.emlx` poll loop (the 8s retry-with-invalidate after the AppleScript `source of msg` triggers Mail.app's IMAP fetch). `ReadStatusController` now writes `model.syncCoordinator?.skipSyncsUntil` instead of reaching into MailModel.
  - **`MailboxKind` enum** replaces `Mailbox.kind: String`. One `MailboxKind.viewScope(forSelectedKind:allMailboxesScope:)` helper plus `MailboxKind.isSystemIsolated` consolidate the three previously-duplicated `["drafts", "trash", "junk"]` predicates (in `MailModel.openFromSearch`, `MailModel.loadMessagesForSelectedThread`, `ReadStatusController.currentViewScope`). Enum's `rawValue`s match the strings already in DB so SQL filters (`kind IN ('drafts','trash','junk')`) keep working unchanged; `IndexDB.loadMailboxes` decodes via `MailboxKind(rawValue:) ?? .other`.
  - **DB errors surfaced** instead of silent `try?`: `countAllUnreadExcludingDrafts` failure now keeps the previous count and logs (rather than zeroing the badge); `openFromSearch` distinguishes "DB error" from "no thread" and sets `threadsError` for both; bulk Mark-Read writes batch through new `IndexDB.setIsReadBatch(rowids:isRead:)` (one transaction, single throw — `setIsRead(rowid:)` now delegates to it), failures alert via `bulkActionError`; `setPreferredAddress` / `addBlockedAddress` failures log via the new `Log.db` os.Logger category instead of being silently dropped.
  - **Shared list components** in `UI/Components/`: `BulkActionHeader.swift` collapses the duplicated "row count + selection count + Mark Read / Mark Unread / Clear" header used by both the threads list and search results. `ListSelectionGesture.swift` collapses the plain/⌘/⇧ click resolver into one `action(from: NSEvent.ModifierFlags)` returning `.open` / `.toggle` / `.rangeFromAnchor`.
  - **Other small cleanups:** `UI/DateFormats.swift` (`Date.listFormat()`) extension unifies the threads-list and search-results row date format (was duplicated verbatim in both files). `MailAppOpener.openMessage` calls now route through `MailModel.openInMailApp(_:)` (ReaderView no longer reaches into the Compose layer). Dropped unnecessary `@Bindable` from 7 views (only `SidebarView` actually uses `$model.x`). Two compiler warnings cleared (redundant `await` on synchronous `IndexDB.init`; dead `body != nil` after `if let body = ...`). Removed unused `FocusedValues.mailModel` extension. `Task.detached { runIncrementalSync }` simplified to `Task` since `runIncrementalSync` is `@MainActor` (no detach benefit). Inner `Task { @MainActor }` removed from `BodyIndexer` progress callback (parameter was already `@MainActor`-isolated). Magic numbers extracted: `MailModel.dockBadgeMaxDisplay = 999`, `HTMLBodyView.imageReflowDelaySeconds = 1.5`. Dead `_ = acctMap`. To enable testing, `ReplyConfirmationSheet.subjectPreview` lifted onto `ReplyKind.subjectPreview(forKind:originalSubject:)` and `ReaderView.formatDelta` lifted into a free `TimeDeltaFormatter.format(_:)`.
  - **First UI-layer tests** (`FMailTests/UILogicTests.swift`, 24 cases, no FDA needed): `MailboxKind` view-scope decision tree (4 cases) + `isSystemIsolated`; `Date.listFormat` rendering buckets (3 cases); `ReplyKind.subjectPreview` Re/Fwd cases including case-insensitive existing-prefix detection (5 cases); `TimeDeltaFormatter.format` six time buckets (6 cases); `MailModel.select` stale-id silent guard, `selectAllMailboxes`, `mailboxesByAccount` INBOX-first sort + hidden filtering (5 cases). All pass; pre-existing `Phase0Tests` still skip without FDA.
- **MCP server (opt-in).** Loopback HTTP/JSON-RPC server on `127.0.0.1:8765` (configurable in Settings). Eight tools — `search_emails`, `list_threads`, `get_thread`, `get_email`, `find_unanswered_threads`, `mark_read`, `delete_messages`, `move_to_junk` — all hit the existing index/threading/DSL/ReadStatus pipeline. Off by default; gated by `MCPSettings.enabled` and a privacy banner in the Settings window. Hand-rolled JSON-RPC 2.0 + minimal HTTP/1.1 framing on `Network.framework`'s `NWListener` (no SDK dep). Loopback-only via `requiredInterfaceType = .loopback` plus per-connection peer check. Write tools (`mark_read`, `delete_messages`, `move_to_junk`) block on `MailScripter` so the LLM sees the result; tool descriptions tell the LLM to keep batches ≤ ~50 to avoid client timeouts (no SSE in v1). Tests cover the JSON-RPC envelope, HTTP framing, every read tool against an in-memory IndexDB fixture, the `find_unanswered_threads` SQL, the write thunk paths, and a full TCP handshake bound on port 0 — 33 cases. Files: `FMail/MCP/{MCPSettings, MCPProtocol, MCPDispatcher, MCPServer, MCPModels, MCPHandlers, MCPHandlers+A3, MCPHandlers+Move, MCPTools}.swift`, `FMail/Core/Index/IndexDB+MCP.swift`, `FMail/UI/Settings/SettingsView.swift`, plus `MCPServer` lifecycle + thunks (markRead, delete, junk) wired in `MailModel.applyMCPSettings`. Settings scene gives `⌘,`; `AppShell` footer adds a green pill when running. See [MCP_PLAN.md](MCP_PLAN.md) for the full design.
- **Bulk Delete + Move to Junk** (UI + MCP). `BulkActionHeader` gains two buttons next to Mark Read / Mark Unread — Delete (`trash` icon, `.destructive` role) and Junk (`exclamationmark.octagon`). Both apply to threads-list selections and search-results selections. `MailScripter` adds `deleteBatch` and `moveToJunkBatch` via a shared `runActionBatch` scaffold that accepts per-context action strings (account-scoped `theAccount` vs cross-account `anAccount`); `setReadStatusBatch` was refactored to use the same scaffold. `ReadStatusController` adds `deleteMessages` / `moveMessagesToJunk` (fire-and-forget UI) plus awaitable `deleteMessages(rowids:) async` / `moveToJunk(rowids:) async` for MCP. Optimistic flip is a *removal* (rows leave their mailbox), not an in-place update: drops from `messagesInSelectedThread` / `searchResults`, decrements thread + mailbox + global counts, drops empty threads. DB is untouched; the next FSEvent-driven sync re-mirrors Apple's Envelope Index. MCP exposes both as `delete_messages` and `move_to_junk` with the same `MarkReadResult` shape (`applied`, `error`).
- **AppleScript move_to_junk removed entirely** (after writeback B1 landed). macOS Tahoe broke `junk mailbox of <account>` for every account in observed setups, and follow-up attempts (name walk fallback, `move msg to` verb, dropping `ignoring application responses`) all left the call hanging Mail.app's AppleEvent queue. The Gmail API path via `GmailAPIWritebackService` (writeback B1) is the reliable path for authorized Gmail accounts; B2 will add IMAP for the rest. `AppleScriptWritebackService.moveToJunk` now returns an explicit "unsupported — authorize Gmail or wait for IMAP" error per message instead of trying and hanging. `MailScripter.moveToJunkBatch` and `moveToJunkAction` deleted along with their unit tests; `mark_read` and `delete` via AppleScript stay.
- **Junk script: status + fallback lookup** (now-deleted follow-up — pre-writeback). The first cut of `move_to_junk` ran a single statement (`set mailbox of msg to junk mailbox of theAccount`) and silently no-op'd when `junk mailbox of <account>` returned `missing value` — observed in practice against a Gmail account where the message was in `[Gmail]/All Mail`. The MCP call also blocked while Mail.app evaluated the property + did a slow IMAP MOVE, exceeding the LLM client's HTTP timeout. Rewrite: `MailScripter.moveToJunkAction(accountVar:)` emits a 3-step block — (1) `set junk mail status of msg to true` (always succeeds, fast, trains Gmail's filter), (2) `try junk mailbox of <accountVar>`; if `missing value`, walk `mailboxes of <accountVar>` for names `Spam` / `Junk` / `Spam mail` / `Bulk Mail` / `[Gmail]/Spam`, (3) `set mailbox of msg to tgtMbox`. `MailScripter.makeLookupBlock` was updated to indent every line of a multi-line action, not just the first. New `MailScripter.diagnoseJunkMailboxes()` enumerates each account's `junk mailbox of acc` property + every Spam/Junk-named mailbox; exposed via Tools → "Diagnose Junk mailboxes…". `MailScripter.buildScriptSource` factored out as internal so `FMailTests/MailScripterTests.swift` (13 cases) can pin the script invariants without invoking Mail.app — junk-status-first, junk-mailbox lookup, name-search fallback, set-mailbox, correct account variable per context, multi-line indentation, action grouping for same-mailbox batches.

Remaining (see "Open work" below).

---

## Deviations from the spec

These are intentional choices made during implementation; the spec hasn't been edited to match (it's the design-intent doc). Cross-referenced for review.

| Spec § | Said | Shipped | Reason |
|---|---|---|---|
| §6.1 | Index path under `~/Library/Containers/<bundle-id>/...` (sandboxed) | `~/Library/Application Support/FMail/index.sqlite` | Non-sandboxed v1; sandbox attempt deferred (FSEventStream + sandbox interaction unproven). |
| §6.1 | Incremental indexing per FSEvent | Each FSEvent triggers a **full** re-mirror of Apple's Envelope Index. Cheap with WAL but wasteful. | Simplicity. True incremental sync deferred. |
| §6.3 | Natural-language fallback (heuristic translator) | Not yet | Deferred to Phase 5. The DSL covers the common cases. |
| §6.4 | Saved searches (sidebar virtual mailboxes) | Not yet | Deferred to Phase 5. |
| §7 | "Address Book Overrides" pane in settings | Inline in reply confirmation sheet only | Deferred Settings UI to Phase 5. |
| §8 | Two-column thread reader option | Single-column stacked only | Single-column was simpler; user preference for two-column hasn't surfaced. |
| §8 | `N` next-unread shortcut | Not yet | Deferred. |
| §8 | Quote folding (`> > >` blocks collapsed) | Not yet | Deferred. |
| §8 | Inline images | `cid:` (attachment-bundled) images: not yet wired (CSP allows them, resolver TBD). External images: opt-in per message via "Load remote images" button (Phase 5). | Privacy: external images are tracking signals; opt-in only. |
| §10 | GRDB.swift | Raw `SQLite3` C API | Zero new deps. Schema migrations + FTS5 work fine via prepare/step/finalize. |
| §10 | `NSAttributedString(html:)` for HTML→text | Two paths: custom `HTMLStripper` for *indexing* (FTS body extraction — WebKit-per-message would tank perf at 150k); `WKWebView` for *display* (in the reader, with strict CSP that blocks all network). | Different requirements: indexing must be cheap; display must be faithful. |
| §10 | `NSAppleScript` for compose | `mailto:` URL via `NSWorkspace` | Simpler, no Automation permission, RFC 6068 covers our needs. |
| §11 | Sandboxed (try first, fall back) | Not sandboxed | Deferred to Phase 5. |
| §11 | Automation permission "for the future AppleScript path" | Required *now* for Mark as Read / Unread | Phase 5 added the AppleScript path. UI shows a Settings deep-link when -1743 is seen. |
| §12 | 5 phases | 5 phases — ordering shifted: spec P2 split into our P2 (index+threading) and P3 (search); spec P3 split into our P2 (threading) and P4 (contacts) | Threading is FTS-adjacent (affects index design); doing it in P2 was cheaper than retrofitting later. |

## Additions beyond the spec

Things the spec didn't mention but proved necessary or useful:

- **Apple `labels` table mirroring (Schema v3).** Gmail's data model uses labels, not folders. Without mirroring, Gmail's INBOX/Sent/Important all appeared empty.
- **`during:` operator.** Granular date-range query with auto-width based on precision of the input.
- **No-colon DSL shortcuts** (`hasattachment`, `isunread`, `isread`, `isflagged`).
- **Recipient-heuristic account naming.** Sent-mailbox heuristic doesn't cover accounts with no Sent mailbox; fallback queries the most common To-recipient.
- **Sync coalescing.** FileWatcher fires per `.emlx` change; without coalescing, Mail.app's IMAP sync would put us in a constant-resync loop.
- **Body-indexer pause-during-sync.** Avoided a SQLite memory access fault from concurrent connection use.
- **Persistent search-result selection** (List(selection:) on `selectedSearchResultId`).

## Resolved open questions (spec §13)

| Question | Decision |
|---|---|
| Sandbox or not? | Non-sandboxed for v1. Phase 5 may attempt. |
| GRDB vs raw SQLite3? | Raw `SQLite3`. |
| Single window or document-style? | Single window, three-pane. |
| `[Gmail]/All Mail` handling? | Hidden by default; eye toggle reveals. |
| iCloud aliases (`@me.com` / `@icloud.com` / `@mac.com`)? | Not handled yet. Treat as separate identities currently. |
| Bundled `.emlx` parser vs reuse Apple's? | Hand-rolled parser. |

## Open work (Phase 5 candidates)

Roughly in order of value-to-cost.

**Quick wins (each ~1 evening)**:
- Saved searches (star a query → sidebar virtual mailbox).
- Keyboard shortcuts: `J` / `K` next/prev message, `N` next-unread within thread then across.
- Quote folding in reader (`> > >` blocks collapsed by default).
- Quick Look on attachments.
- "Pause indexing" toggle in settings.
- Bottom-of-list "Show more" / load more than 500 threads / search results.

**Real cleanup (each ~weekend)**:
- True incremental sync — currently every FSEvent triggers a full re-mirror.
- Body indexer that picks up new mail discovered by FSEvents (currently only sweeps the initial backlog).
- Settings pane for address overrides (review/edit `contact_prefs` rows).
- DSL tests (snapshot for parser, property-based for boolean operators). UI pure-helper tests are now in place; the DSL parser/evaluator is still untested.
- Sandbox attempt + verify FSEventStream still fires.
- AppleScript compose path for "send from this account" precision (currently Mail.app picks).
- Schema-fingerprint test against live Envelope Index (catches Apple changing column names in a future macOS).
- iCloud alias unification (`@me.com` ≡ `@icloud.com` ≡ `@mac.com`) for `to:me` and account matching.

**Deferred (spec §14)**: iOS companion via iCloud Drive sync, after Mac v1 has been in daily use for 1+ month.

## File inventory

```
FMail/
├── FMailApp.swift                  Entry point + Tools menu (Diagnose Mail.app structure)
├── Compose/
│   ├── ComposeRequest.swift        ReplyBuilder (reply / reply-all / forward → ComposeRequest)
│   └── MailComposer.swift          mailto: URL builder + MailAppOpener (message:// scheme)
├── Contacts/
│   └── ContactsService.swift       CNContactStore wrapper, address→contact map
├── Core/
│   ├── Logging.swift               os.Logger namespace (Log.sync / .mailScripter / …)
│   ├── Emlx/
│   │   ├── EmlxParser.swift        .emlx file parser (length prefix + RFC 822 + flag plist)
│   │   ├── EncodedWord.swift       RFC 2047 (Q + B encoding)
│   │   ├── HeaderParser.swift      RFC 5322 headers + line folding
│   │   └── MIMEParser.swift        Multipart, base64, quoted-printable
│   ├── HTML/
│   │   └── HTMLStripper.swift      Non-WebKit HTML → text
│   ├── Index/
│   │   ├── Schema.swift            Versioned schema (v1..v6: contact_prefs, message_labels,
│   │   │                            rfc_message_id, body_indexed reset, imap_uid)
│   │   ├── IndexDB.swift           Actor wrapping our SQLite handle (read API + bulk writes)
│   │   ├── IndexDB+ContactPrefs.swift  Actor extension: contact_prefs CRUD
│   │   ├── IndexModels.swift       Wire types (IndexedMessage, IndexedRecipient, …,
│   │   │                            ThreadSummary, ContactPrefs)
│   │   ├── Indexer.swift           Mirrors Apple's Envelope Index → our DB
│   │   └── BodyIndexer.swift       Background sweep that fills FTS body content
│   ├── QueryDSL/
│   │   ├── Token.swift             Token kinds
│   │   ├── Lexer.swift             String → tokens
│   │   ├── AST.swift               Boolean tree + Term cases
│   │   ├── Parser.swift            Tokens → AST + field-term mapping
│   │   ├── DateExpression.swift    ISO / relative / month-name dates with granularity
│   │   └── Evaluator.swift         AST → SQL boolean WHERE clause + bindings (text leaves
│   │                                use `apple_rowid IN (… messages_fts MATCH ?)` subqueries;
│   │                                pure-text subtrees fuse into one MATCH)
│   └── Threading/
│       └── ThreadGrouper.swift     Union-find over message_references
├── MailStore/
│   ├── BodyLoader.swift            Actor: per-mailbox rowid→.emlx URL cache + parse on demand
│   ├── EnvelopeIndexReader.swift   Two readers: EnvelopeIndexReader (smoke / Phase0Tests
│   │                                — messageCount / mailboxCount only); EnvelopeReadOnly
│   │                                (production sync reader: mailboxes / messages /
│   │                                recipients / labels / references)
│   ├── FileWatcher.swift           FSEventStream wrapper (logs setup failures via os.Logger)
│   ├── MailboxFilter.swift         Hide rules ([Gmail]/All Mail, Recovered, SendLater)
│   ├── MailboxURL.swift            Parses Apple's `imap://<uuid>/<path>` mailbox URLs
│   ├── MailStoreEnumerator.swift   Locates ~/Library/Mail/V<N>; envelope index URL helper
│   └── Models.swift                MailAccount, Mailbox, MessageHeader, MessageBody,
│                                    MailboxKind enum (with viewScope helper)
├── Permissions/
│   └── FullDiskAccessFlow.swift    First-run FDA prompt + System Settings deep-link
└── UI/
    ├── AppShell.swift              Top-level shell + states (loading / FDA / indexing /
    │                                ready) + bulkActionError alert
    ├── MailModel.swift             Main @Observable @MainActor view-model. Sync
    │                                orchestration delegated to SyncCoordinator;
    │                                Mark Read / Unread to ReadStatusController; the
    │                                on-demand body retry loop to BodyFetchPoller
    │                                (all ObservationIgnored).
    ├── SyncCoordinator.swift       Owns file watcher + body-indexer task lifecycle +
    │                                runIncrementalSync + sync coalescing + post-sync
    │                                missing-body prefetch + skipSyncsUntil window.
    ├── ReadStatusController.swift  Owns Mark Read / Unread: optimistic flip across
    │                                threads/messages/search-results, AppleScript
    │                                dispatch, batched DB write via setIsReadBatch.
    ├── BodyFetchPoller.swift       8s retry-with-invalidate poll loop after the
    │                                AppleScript `source of msg` IMAP fetch.
    ├── DateFormats.swift           Date.listFormat() — shared row date format.
    ├── Components/
    │   ├── BulkActionHeader.swift  Selection-count + Mark Read/Unread/Clear header
    │   │                            (shared by threads list and search results).
    │   └── ListSelectionGesture.swift  Plain/⌘/⇧ click resolver.
    ├── MessageList/
    │   └── MessageListView.swift   Search bar + threads list / search results list
    ├── Reader/
    │   ├── ReaderView.swift        Stacked thread reader (+ TimeDeltaFormatter)
    │   ├── HTMLBodyView.swift      WKWebView wrapper (locked-down CSP, height auto-measure)
    │   └── ReplyConfirmationSheet.swift  Address-picker dialog
    ├── Search/
    │   ├── SearchBar.swift         With interpreted-query strip
    │   └── SearchResultsView.swift
    └── Sidebar/
        └── SidebarView.swift       Accounts → mailboxes with unread counts

FMailTests/
├── Phase0Tests.swift               Smoke tests (skip when test runner lacks FDA)
└── UILogicTests.swift              Pure-helper unit tests: MailboxKind view-scope,
                                     Date.listFormat, ReplyKind.subjectPreview,
                                     TimeDeltaFormatter, MailModel selection/sort
                                     (24 cases, no FDA needed).

Top-level:
├── FMailSpec.md                    Original design spec (intent)
├── IMPLEMENTATION.md               This file (status)
├── project.yml                     xcodegen project definition
├── .gitignore                      Includes generated FMail.xcodeproj + Info.plist
```
