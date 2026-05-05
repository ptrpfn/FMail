# FMail — Implementation status

Companion to `FMailSpec.md`. The spec captures the design intent; this file captures **what's actually shipped**, what diverges from the spec, and what's left.

Last updated: 2026-05-03.

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
- DSL tests (snapshot for parser, property-based for boolean operators).
- Sandbox attempt + verify FSEventStream still fires.
- AppleScript compose path for "send from this account" precision (currently Mail.app picks).
- Schema-fingerprint test against live Envelope Index (catches Apple changing column names in a future macOS).
- iCloud alias unification (`@me.com` ≡ `@icloud.com` ≡ `@mac.com`) for `to:me` and account matching.

**Deferred (spec §14)**: iOS companion via iCloud Drive sync, after Mac v1 has been in daily use for 1+ month.

## File inventory

```
FMail/
├── FMailApp.swift                  Entry point
├── Compose/
│   ├── ComposeRequest.swift        ReplyBuilder (reply / reply-all / forward → ComposeRequest)
│   └── MailComposer.swift          mailto: URL builder
├── Contacts/
│   └── ContactsService.swift       CNContactStore wrapper, address→contact map
├── Core/
│   ├── Emlx/
│   │   ├── EmlxParser.swift        .emlx file parser (length prefix + RFC 822 + flag plist)
│   │   ├── EncodedWord.swift       RFC 2047 (Q + B encoding)
│   │   ├── HeaderParser.swift      RFC 5322 headers + line folding
│   │   └── MIMEParser.swift        Multipart, base64, quoted-printable
│   ├── HTML/
│   │   └── HTMLStripper.swift      Non-WebKit HTML → text
│   ├── Index/
│   │   ├── Schema.swift            Versioned schema (v1, v2, v3)
│   │   ├── IndexDB.swift           Actor wrapping our SQLite handle
│   │   ├── Indexer.swift           Mirrors Apple's Envelope Index → our DB
│   │   └── BodyIndexer.swift       Background sweep that fills FTS body content
│   ├── QueryDSL/
│   │   ├── Token.swift             Token kinds
│   │   ├── Lexer.swift             String → tokens
│   │   ├── AST.swift               Boolean tree + Term cases
│   │   ├── Parser.swift            Tokens → AST + field-term mapping
│   │   ├── DateExpression.swift    ISO / relative / month-name dates with granularity
│   │   └── Evaluator.swift         AST → FTS5 expression + SQL conditions + bindings
│   └── Threading/
│       └── ThreadGrouper.swift     Union-find over message_references
├── MailStore/
│   ├── BodyLoader.swift            Actor: per-mailbox rowid→.emlx URL cache + parse on demand
│   ├── EnvelopeIndexReader.swift   Phase 1 reader (mostly superseded; kept for diagnostics + tests)
│   ├── FileWatcher.swift           FSEventStream wrapper
│   ├── MailboxFilter.swift         Hide rules ([Gmail]/All Mail, Recovered, SendLater)
│   ├── MailboxURL.swift            Parses Apple's `imap://<uuid>/<path>` mailbox URLs
│   ├── MailStoreEnumerator.swift   Locates ~/Library/Mail/V<N>; finds .emlx by rowid
│   └── Models.swift                MailAccount, Mailbox, MessageHeader, MessageBody
├── Permissions/
│   └── FullDiskAccessFlow.swift    First-run FDA prompt + System Settings deep-link
└── UI/
    ├── AppShell.swift              Top-level shell + states (loading / FDA / indexing / ready)
    ├── MailModel.swift             Main @Observable @MainActor view-model
    ├── MessageList/
    │   └── MessageListView.swift   Search bar + threads list / search results list
    ├── Reader/
    │   ├── ReaderView.swift        Stacked thread reader
    │   ├── HTMLBodyView.swift      WKWebView wrapper (locked-down CSP, height auto-measure)
    │   └── ReplyConfirmationSheet.swift  Address-picker dialog
    ├── Search/
    │   ├── SearchBar.swift         With interpreted-query strip
    │   └── SearchResultsView.swift
    └── Sidebar/
        └── SidebarView.swift       Accounts → mailboxes with unread counts

FMailTests/
└── Phase0Tests.swift               Smoke tests (skip when test runner lacks FDA)

Top-level:
├── FMailSpec.md                    Original design spec (intent)
├── IMPLEMENTATION.md               This file (status)
├── project.yml                     xcodegen project definition
├── .gitignore                      Includes generated FMail.xcodeproj + Info.plist
```
