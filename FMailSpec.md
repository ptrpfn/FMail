# FMail — Spec

A small, opinionated macOS email **viewer** that fixes the four things about Apple Mail you actually hit every day. Compose/send stays in Mail.app — FMail does not try to be a full mail client.

> **Implementation status**: see [IMPLEMENTATION.md](IMPLEMENTATION.md). This file remains the design-intent spec; deviations and decisions made during build are tracked there.

> **⚠️ UI has changed — read this first.** The shipping app on `master` is now a **menu-bar-only**
> build (no main window, no Dock icon): unread/search list, multi-select mark-as-read, and per-email
> Open-in-Mail / Reply / Forward, all from a status-bar dropdown. Reply/Forward drive Mail.app's
> native AppleScript commands (not `mailto:`); there is no in-app thread reader, HTML rendering, or
> per-contact preferred-address handling — reading and replying are delegated to Mail.app. The MCP
> server is **on by default**. This document describes the original **three-pane window UI**, which is
> preserved on the [`window-UI`](../../tree/window-UI) branch. For current behaviour and setup, see
> [README.md](README.md). The data layer (index, search DSL, threading, MCP) is shared by both UIs and
> still accurately described here.

---

## 1. Why this exists

Concrete pain points with Apple Mail (macOS + iOS) that FMail must fix:

1. **Unread counts drift.** The badge and the actual unread set disagree. Opening Mail "discovers" mail that should already have been counted, or shows fewer unreads than really exist.
2. **Search is weak.** No real boolean operators, awkward date syntax, no good way to scope by topic + time + person at once. Finding "that thing Anna sent in March about the school trip" is a chore.
3. **Wrong recipient address gets picked.** Contacts with multiple addresses (e.g. Kyoko: real address + AppStore-only address) — Mail picks essentially at random when you type a name. Easy to send to the wrong one.
4. **Threads are hard to read.** Hard to see what's actually new vs. old in a long reply chain; both the macOS and iOS layouts hide the new message badly.

Surveyed alternatives (Mimestream, MailMate, Spark, Canary, Airmail, etc.) have either fundamental issues — Gmail-only, subscription churn, cloud-routed (privacy), or ironically the *same* unread-count bug — or, historically, get abandoned within a year or two. Hence: build something tiny and personal.

## 2. Goals

A v1 that:

- **Always shows correct unread counts** for every mailbox, computed from authoritative source data each launch (no syncing of counts).
- **Has search that doesn't suck**: boolean operators, persons, date ranges, mailbox/account scoping, folder scoping, attachment-yes/no, and a "lazy" natural-language fallback that translates a typed phrase into the structured query.
- **Remembers preferred address per contact**, so typing "Kyoko" never offers her AppStore address unless explicitly overridden.
- **Renders threads clearly**, with unmistakable visual separation between read and unread messages and a one-keystroke "jump to next unread within thread."
- **Opens replies/forwards/new mail in Mail.app**, prefilled (To, Cc, Subject, In-Reply-To, quoted body). FMail does not send mail itself.
- **Stays small**: macOS-only, single SwiftUI app, no server, no account in the cloud, no sync of FMail's own state across devices.

## 3. Non-goals (hard scope boundary)

These are explicitly **out** for v1 and probably forever — they are what turns "small viewer" into "all-consuming project":

- Composing, sending, drafts, signatures, aliases, scheduled send → all delegated to Mail.app.
- Calendar, contacts editing, snooze, send-later, follow-up reminders, undo-send.
- Push notifications (Mail.app already does this).
- Filters / rules / smart mailboxes that mutate server state.
- Attachments handling in the GUI beyond view/quick-look/save. (Read-only access to attachment bytes from a local LLM client via the MCP server is in scope — see §15.)
- HTML composing, Markdown composing.
- Tracking pixel blocking, "read receipts," remote content blocking (Mail.app's setting governs what's cached).
- iOS / iPadOS app **in v1**. (iOS sandboxes Mail's data — see §14 for a deferred plan that reuses the Mac index without building a full IMAP/Gmail client.)
- Multi-device sync of FMail-specific state (preferred-address overrides, search history). v1 stores them locally; if needed, sync via a single iCloud-Drive plist file later.
- Encrypted/PGP/S-MIME mail. Display-only if Mail.app already decrypted.

## 4. Architecture

Single SwiftUI macOS app, three layers:

```
┌────────────────────────────────────────────────────────────┐
│  UI  (SwiftUI)                                             │
│  - 3-pane: account/mailbox sidebar │ thread list │ reader  │
│  - Search bar with live results & query DSL                │
└──────────────────────┬─────────────────────────────────────┘
                       │
┌──────────────────────┴─────────────────────────────────────┐
│  Index  (own SQLite + FTS5, read-only to user)             │
│  - `messages`, `addresses`, `threads`, `mailboxes`         │
│  - `messages_fts` virtual table (subject, body, names)     │
│  - `contact_prefs` (preferred address per contact)         │
└──────────────────────┬─────────────────────────────────────┘
                       │ rebuilds from / mirrors
┌──────────────────────┴─────────────────────────────────────┐
│  Sources                                                   │
│  - Apple Mail's `~/Library/Mail/V10/` (.emlx + Envelope    │
│    Index sqlite)  — primary source                         │
│  - Apple Contacts framework                                │
│  - Mail.app via AppleScript (compose/reply only)           │
└────────────────────────────────────────────────────────────┘
```

**Key idea:** FMail does not talk to mail servers in v1. Apple Mail already syncs (and will keep syncing) your accounts. FMail reads its on-disk store, builds a *better* index on top, and presents a *better* UI. If Mail.app's sync is too laggy for your taste, that's a v2 question (see §11).

## 5. Data sources

### 5.1 Apple Mail local store

- Location on macOS Sequoia / Tahoe: `~/Library/Mail/V10/` (the version directory bumps with major macOS releases — detect dynamically by listing `~/Library/Mail/V*` and picking the highest).
- Per-account folders: `<UUID>/<Mailbox>.mbox/<UUID>/Data/Messages/*.emlx`.
- Metadata DB: `~/Library/Mail/V10/MailData/Envelope Index` (SQLite). Tables include `messages`, `addresses`, `recipients`, `subjects`, `mailboxes`, plus thread/labels tables. Schema is undocumented and *can change between macOS versions* — see §9.
- `.emlx` is RFC 822 + a small binary plist trailer with flags. Standard MIME parsers handle the RFC 822 part; the plist gives `read`, `flagged`, `replied`, `forwarded` bits.
- **Attachments are stored out-of-line for Gmail/IMAP accounts.** Mail.app strips attachment payloads from the `.emlx` (leaving an `X-Apple-Content-Length: N` placeholder on the part) and writes the decoded bytes to `<dataDir>/Attachments/<rowid>/<partIdx>/<filename>` — sibling of the `Messages/` directory. `BodyLoader.fillExternalAttachments` reads them back after MIME parsing, matching by filename (with RFC 2231 `filename*0=…; filename*1=…` continuations reassembled) and falling back to part-index order. Without this step, `data.count == 0` for every attachment on a Gmail message.
- **Draft autosaves are excluded.** Apple's `messages.type` column distinguishes regular mail (0) from Gmail draft autosaves (5). The reader filters `type = 5` and the indexer's `pruneMessagesNotIn` drops any previously-imported drafts on the next sync. Drafts live in Mail.app; FMail doesn't show them.

**Access mode**: read-only. FMail never writes into `~/Library/Mail/`.

**Permission**: requires **Full Disk Access** (System Settings → Privacy & Security → Full Disk Access). Spec must surface a clear first-run dialog explaining this and linking directly to the settings pane.

### 5.2 Contacts

- `Contacts.framework` (CNContactStore) for names + email addresses + photos. Permission prompt on first run.
- Used to resolve sender/recipient addresses to display names and to populate the address picker.

### 5.3 Mail.app (compose only)

- AppleScript bridge for "reply", "reply all", "forward", "new mail". Pre-populates To/Cc/Subject/quoted body and surfaces the window in Mail.app. The user types and hits send there.
- Fallback: `mailto:` URL with `body=` and `in-reply-to=` headers when AppleScript is unavailable.

## 6. Search — the headline feature

### 6.1 Index

- Own SQLite database. Path depends on sandbox decision; non-sandboxed v1 lives at `~/Library/Application Support/FMail/index.sqlite`.
- FTS5 virtual table on: subject, body (plain-text rendition of HTML), sender display name, sender address, recipient display names, recipient addresses, attachment filenames.
- Auxiliary columns indexed (non-FTS): `date_received`, `account_id`, `mailbox_id`, `is_read`, `is_flagged`, `has_attachment`, `thread_id`.
- Body text is extracted from the `.emlx` once at index time via a small custom stripper (avoiding `NSAttributedString(html:)` because it loads WebKit and would auto-fetch remote `<img>`s).
- Apple's `labels` table is mirrored into `message_labels` so Gmail label-mailboxes (INBOX, Sent Mail, Important — all virtual; the canonical store is `[Gmail]/All Mail`) actually find their messages.
- **Incremental indexing**: an `FSEventStream` rooted at `~/Library/Mail/V10/` (with `kFSEventStreamCreateFlagFileEvents`, 2 s coalescer, persistent `lastEventId`) detects changes. *Implementation note*: v1 triggers a full re-mirror of Apple's Envelope Index per fired event rather than per-`.emlx` incremental update — cheap enough with WAL, but wasteful; true incremental sync is a Phase 5 cleanup.
- Full re-index on schema-version change or by user request ("Rebuild Index" menu).

### 6.2 Query DSL

User-typed query is parsed into a structured form. Examples:

| Typed query | Meaning |
|---|---|
| `kyoko school trip` | bag-of-words match anywhere |
| `from:kyoko school trip` | `school trip` text + sender contains "kyoko" |
| `from:kyoko@gmail.com` | exact sender address |
| `to:me from:anna` | sent to me, from Anna |
| `after:2024-03-01 before:2024-04-01 school` | date range |
| `last 30 days school` | relative date range |
| `since march school` | "since" / "before" with month names |
| `account:icloud invoice` | scope to one account |
| `in:inbox` / `in:archive` / `in:sent` | mailbox scope |
| `has:attachment pdf` | only with attachments |
| `is:unread` / `is:flagged` | flag scope |
| `(anna OR kyoko) school -homework` | boolean + negation + grouping |
| `"exact phrase"` | quoted phrase match |

**Operators**: `AND` (implicit), `OR`, `-` / `NOT`, parentheses, quoted phrases.

**Field operators**: `from:`, `to:`, `cc:`, `subject:`, `body:` (or `content:`, `text:`), `attachment:`, `account:`, `in:`, `has:`, `is:`, `before:`, `after:` / `since:`, `on:`, `during:`. No-colon shortcuts: `hasattachment`, `isunread`, `isread`, `isflagged`.

**Date forms accepted**:
- ISO: `2024-03-15`, `2024-03`, `2024`
- Relative single-word: `today`, `yesterday`, `tomorrow`
- Compact relative ("N units ago"): `7d`, `2w`, `3m`, `1y`
- Multi-word relative (must be quoted in DSL): `"last 30 days"`, `"last week"`, `"this year"`
- Month names: `march`, `march 2024`

**Date range semantics**:
- `before:DATE` → `< start of period containing DATE` (so `before:2026` is `< 2026-01-01`).
- `after:DATE` → for partial dates, `>= start of next period` (so `after:2024` is `>= 2025-01-01`); for full dates, `>= DATE` (Gmail-style inclusive).
- `during:DATE` / `on:DATE` → `[start of period, start of next period)` — width matches the precision of DATE (`during:2026` = all of 2026, `during:2026-03` = all of March, `during:2026-03-15` = that day).

**Token-prefix matching**: bareword search terms and field values implicitly match by prefix (`subject:v` matches `vermont`). Quoted phrases (`"vermont"`) match exactly.

### 6.3 Natural-language fallback (deferred to Phase 5)

If the DSL parser yields zero structured tokens (i.e. the user typed a sentence), apply a small heuristic translator before falling back to bag-of-words:

- Spot person names against the contact list → `from:` / `to:`
- Spot month/year/relative-time phrases → date range
- Spot keywords like "attachment", "pdf", "invoice" → `has:attachment` and a content term
- Show the *interpreted* structured query above the results so the user can see and tweak what FMail did.

We are explicitly **not** shipping an LLM in v1. Heuristics only. If the heuristics aren't enough, the user can read the parsed query and fix it manually.

*Implementation status*: not built. The interpreted-query strip exists (always shown) — the heuristic translator does not. Skipped because the structured DSL covers the common cases.

### 6.4 Saved searches (deferred to Phase 5)

- Star a query → appears in sidebar as a virtual mailbox.
- Persisted in the FMail index DB, not in Apple Mail.

*Implementation status*: not built.

## 7. Contact / preferred-address handling

The address-picking bug is almost the whole point of fixing this:

- FMail maintains a `contact_prefs` table: `(contact_id, preferred_address, blocked_addresses[])`.
- When you start typing a name in the To/Cc field of the *FMail-driven compose* (i.e. before handing off to Mail.app), FMail:
  - Looks up matching contacts.
  - Shows **only the preferred address** for each contact unless you press a disclosure key (e.g. ⌥) to expand all known addresses.
  - Lets you mark an address as "never suggest" inline (e.g. the AppStore address).
- First-time learning: when you reply to a thread, FMail records that "this is the address Kyoko actually uses for human conversation" and offers to set it as preferred.
- Contact-prefs UI: a small "Address Book Overrides" pane listing all overrides for review/edit.

Critical: this preference is FMail-local. We don't write back to Apple Contacts. (Avoids touching shared state; survives Mail.app updates; easy to back up.)

## 8. Thread view

Single-column stacked thread reader (v1 — two-column variant deferred). Each message is a card; click to expand. Requirements:

- **Unread messages are visually unmistakable**: tinted background, bold sender, dot indicator. No ambiguity. ✅
- **Read messages are collapsed by default** to a one-line summary (sender · date · first 60 chars). ✅
- **Time deltas**: between consecutive messages, show "+3 days" / "+12 min" so you can see the rhythm of the conversation. ✅
- **Reply target indicator**: when you hit ⌘R, FMail shows in the compose-launch dialog *which* message you're replying to and *which* address it's going to (lets you catch a wrong-address selection before it's too late). ✅
- **HTML rendering**: HTML message bodies render in a locked-down `WKWebView` with strict `Content-Security-Policy` (`default-src 'none'; img-src data: cid:; style-src 'unsafe-inline'`). No network calls — no read-tracking pixels, no remote font/script/iframe loads. Plain-text bodies fall back to a `Text` view. ✅
- **Per-message "Load remote images" opt-in**: when an HTML message contains `<img src="http(s)://…">`, a button appears above the body. Clicking it relaxes CSP for *that message instance only* to allow `img-src http: https:` (scripts/iframes/fonts stay blocked even then). The choice is per-instance and not persisted — re-opening the same email starts blocked again. ✅

Deferred to Phase 5:
- **`N` keyboard shortcut**: jump to next unread message *within this thread*; then next unread *across threads*.
- **Quote folding**: `> > >` history blocks collapsed by default with "show quoted text" toggle.
- **`cid:` inline-attached images**: CSP already allows them; the resolver that maps `cid:foo` to the corresponding bundled attachment isn't wired yet.
- **Two-column variant** (list of messages on the left, currently-selected message on the right) as an alternative layout.

## 9. Robustness against Apple changing things

The `~/Library/Mail/V*/` path and Envelope Index schema are private API in spirit. Mitigations:

- **Detect schema version on launch**. Run a quick `PRAGMA table_info` on critical tables; if columns we depend on are missing, show a "FMail needs an update for this macOS version" banner instead of crashing.
- **Treat the Envelope Index as a hint, not as truth.** The `.emlx` files on disk are the canonical content; the DB is just for fast metadata lookups. If the DB looks wrong, fall back to walking `.emlx` files (slower; one-time pain).
- **Version-pin a known-good schema per macOS major version** (V10 = Sonoma/Sequoia, future Vs = future macOS). Each version gets a small adapter module.
- **Never write to Apple's files.** All FMail state lives in our own sqlite DB.

## 10. Tech stack

- **Language**: Swift 6, SwiftUI, `@Observable` view-models, actors for SQLite isolation.
- **Min target**: macOS 14 (Sonoma).
- **Storage**: **Raw `SQLite3` C API** (decision: zero new deps; GRDB was the spec's first choice but raw works fine for our schema size).
- **Mail parsing**: hand-rolled `.emlx` parser (~250 LoC across `EmlxParser` + `MIMEParser` + `EncodedWord` + `HeaderParser`). Handles RFC 822 line folding, RFC 2047 encoded-words, multipart MIME, base64, quoted-printable.
- **HTML → text** (for indexing): **custom `HTMLStripper`** (decision: avoiding `NSAttributedString(html:)` because it pulls in WebKit, would auto-fetch remote images, and tanks reindex performance at 150k messages).
- **HTML rendering** (for the reader): **`WKWebView`** wrapped in `NSViewRepresentable`, with strict CSP and `allowsContentJavaScript = false`. Height auto-measured via `evaluateJavaScript("document.documentElement.scrollHeight")`. Content cached per (html, allowRemoteImages) to avoid feedback-loop reloads when SwiftUI re-renders for unrelated reasons.
- **Compose**: **`mailto:` URL via `NSWorkspace.shared.open(_:)`** (decision: simpler than AppleScript, no Automation permission, RFC 6068 supports `subject` / `body` / `cc` / `in-reply-to` / `references`). Trade-off: Mail.app picks the From-account by heuristic. AppleScript path is a Phase 5 polish if needed.
- **Project shape**: single Xcode app target driven by **`xcodegen`** (`project.yml` checked in; `.xcodeproj` regenerated, gitignored).
- **Contacts**: `Contacts.framework`.
- **Tests**: XCTest. Phase 0 smoke tests (FDA-gated), UI pure-helper unit tests (`MailboxKind` view-scope, `Date.listFormat`, `ReplyKind.subjectPreview`, `TimeDeltaFormatter`, `MailModel` selection/sort), MCP dispatcher / handler / HTTP-framing coverage against an in-memory `IndexDB`, `MailScripter.buildScriptSource` assertions for the read + delete AppleScript shapes, query DSL parser+evaluator coverage (including the FTS5 column-filter-AND regression), `IndexDB.deleteMessagesByRowid` + `pruneMessagesNotIn` coverage, and `BodyLoader` external-attachment + RFC 2231 filename coverage against a synthetic Mail.app layout. Schema-fingerprint test against a live Envelope Index still Phase 5 debt.

## 11. Permissions, privacy, security

- **Full Disk Access** required (read `~/Library/Mail/`). Surfaced via a clear first-run flow.
- **Contacts permission** required for name resolution. Lazy-requested on first reply.
- **Automation permission** ("FMail wants to control Mail.app") required for **Mark as Read / Mark as Unread** and **Delete**. Triggered the first time the user clicks one of those buttons; if denied (or never prompted because dismissed), surfacing a one-click button that opens **System Settings → Privacy & Security → Automation → FMail → Mail**. The TCC error -1743 ("Not authorized to send Apple events to Mail") is the user-visible signal. `NSAppleEventsUsageDescription` is set in `Info.plist`. Compose / reply do NOT use AppleScript — those go via `mailto:` URLs through `NSWorkspace`, no Automation permission needed. **Move to Junk is not exposed** — macOS Tahoe broke `junk mailbox of <account>` AppleScript resolution; the planned bypass (a Gmail API writeback path) was attempted and removed (see §12 v2 candidates).
- **No network** in v1 *by default*. Opt-in exception: the **MCP server with the Cloudflare tunnel toggle** (Settings → MCP) spawns a `cloudflared` child process that holds an outbound TLS connection to Cloudflare's edge, making the loopback MCP endpoint reachable at a named hostname (e.g. `https://fmail.your-domain.com`). Off by default; visibly indicated when on (a red banner across the top of the main window with the live URL + close button, plus a red dot in the footer status row). Bearer-token auth required before the toggle is allowed to open; the token is generated in Settings and stored in `UserDefaults`. The server's existing loopback-peer check stays as defense-in-depth — even with the tunnel up, the connection FMail sees comes from `cloudflared` on `127.0.0.1`. User does the one-time `cloudflared tunnel login` / `create <name>` / `route dns <name> <host>` setup in Terminal; FMail invokes `cloudflared tunnel --url http://127.0.0.1:<port> run <name>` and tears it down on toggle-off and on `applicationWillTerminate`.
- **Sandboxing**: **not sandboxed in v1** (deferred to Phase 5 — FSEventStream + sandbox interaction unproven; subprocess-spawning for the tunnel also presumes non-sandboxed). Signed ad-hoc for local dev; no notarisation yet.
- **No telemetry**. Period.

## 12. Phased plan

Each phase is a usable app. Per-phase status here is the design intent; for what each phase actually shipped, see [IMPLEMENTATION.md](IMPLEMENTATION.md).

### Phase 0 — Skeleton (1–2 evenings) ✅
- Swift app via `xcodegen`, three-pane SwiftUI shell, FDA prompt, diagnostic view that reads the Envelope Index and renders one `.emlx`'s Subject. Validates both access paths.

### Phase 1 — Read & browse (1 weekend) ✅
- Walk `~/Library/Mail/V*` to enumerate accounts and mailboxes.
- Parse `.emlx` (headers + body + flag plist trailer + RFC 2047 + multipart MIME).
- Show message list and reader.
- **Closes pain point #1** (correct unread counts).

### Phase 2 — Own index + threading + watcher (1 weekend) ✅
- Build our own SQLite index (raw `SQLite3`, schema-versioned). Mirror Apple's metadata via `Indexer`.
- Group messages into threads via union-find on Apple's `message_references` (don't trust Apple's `conversation_id`).
- `FSEventStream` rooted at `~/Library/Mail/V10/`, persistent `lastEventId`, sync-coalescing.
- Switch UI to read from our DB (instant after the first index).
- **Stages threading and lays the foundation for pain point #4.**

### Phase 3 — Search (1 weekend) ✅
- DSL: lexer + AST + parser + evaluator. Compiles user input to FTS5 MATCH + auxiliary SQL conditions.
- FTS5 populated from `messages` ⨝ `recipients` at the end of every sync (subject + sender + recipients searchable immediately).
- `BodyIndexer` background sweep walks `.emlx` files and fills body content into FTS progressively. Pauses during sync.
- Search bar + interpreted-query strip + results list. ⌘F focuses.
- **Closes pain point #2.**

### Phase 4 — Contacts + compose handoff (1 evening – ish) ✅
- `ContactsService` (lazy `CNContactStore` permission on first reply).
- `contact_prefs` table (preferred address + blocked addresses per contact). Schema v2.
- `mailto:` driver with `subject` / `body` / `cc` / `in-reply-to` / `references` (RFC 6068).
- Reply-confirmation sheet with address picker, "always reply to X" / "hide Y from suggestions".
- Reply / Reply All / Forward in reader (⌘R / ⌘⇧R / ⌘⌥F).
- Schema v3 added partway through to mirror Apple's `labels` table (Gmail label-mailboxes were appearing empty).
- **Closes pain point #3.** Pain point #4 mostly closed; remaining items in Phase 5.

### Phase 5 — Polish (ongoing) 🚧
Already shipped (per IMPLEMENTATION.md):
- "All Mailboxes" virtual view with global unread count + Dock-tile badge, auto-selected on launch.
- HTML rendering via locked-down `WKWebView`; per-message "Load remote images" opt-in.
- App icon (multi-size `AppIcon.icns`).
- Mark as Read / Mark as Unread via AppleScript (osascript subprocess, targeted, fire-and-forget so Mail.app doesn't lock up).
- "Open in Mail.app" via `message://` URL scheme — handles "body not yet downloaded" cases.
- Reply toolbar moved to top of each message.
- Body-text loss bug fixed (incremental FTS update; Schema v5 reset to recover existing data).
- Search excludes drafts/trash/junk consistently (canonical + Gmail-label filter).
- DSL aliases: `during:`, `content:`/`text:` for body, `hasattachment`/`isunread`/etc as no-colon shortcuts.
- Boolean `OR` / `NOT` now compose across **all** predicate types (text, date, flag, scope). Previously the Evaluator routed text predicates through one FTS5 expression and date/flag/scope predicates through a separate `AND` chain, so e.g. `(during:2025 OR during:2023)` silently became `during:2025 AND during:2023` (empty). Now compiled to one SQL boolean expression with FTS subqueries; pure-text subtrees still fuse into a single `messages_fts MATCH` for efficiency.
- Bulk Mark Read / Unread failures now surface as a modal alert (`bulkActionError`) instead of masquerading as inline body-load errors in the reader.
- Internal refactor: `MailModel` (1145 → 753 LOC) and `IndexDB` (1170 → 1014 LOC) split. New: `UI/ReadStatusController.swift`, `Core/Index/IndexModels.swift`, `Core/Index/IndexDB+ContactPrefs.swift`, `Core/Logging.swift` (centralised `os.Logger`). `EnvelopeReadOnly` merged into `MailStore/EnvelopeIndexReader.swift`. `MailScripter` AppleScript-builder helpers extracted (`bucketByMailbox`, `buildAccountScopedBlock`, `buildCrossAccountFallback`).
- Second internal refactor pass: `MailModel` (760 → 675 LOC) further split. New `UI/SyncCoordinator.swift` (file watcher, body-indexer task lifecycle, sync coalescing, `skipSyncsUntil` window, `runIncrementalSync`, post-sync missing-body prefetch) and `UI/BodyFetchPoller.swift` (on-demand `.emlx` poll loop after AppleScript IMAP fetch). New `MailboxKind` enum replaces `Mailbox.kind: String`; one `MailboxKind.viewScope(forSelectedKind:allMailboxesScope:)` helper consolidates the 3× duplicated drafts/trash/junk predicate. Bulk Mark-Read writes batch through `IndexDB.setIsReadBatch` (one transaction, single throw); `countAllUnreadExcludingDrafts` failure now keeps the prior count instead of zeroing the badge; `openFromSearch` surfaces errors via `threadsError`; new `Log.db` os.Logger category for previously-silent DB paths. Shared `UI/Components/{BulkActionHeader, ListSelectionGesture}.swift` dedupe the threads-list / search-results headers and the plain/⌘/⇧ click resolver. `UI/DateFormats.swift` (`Date.listFormat()`) unifies row date formatting. `MailAppOpener.openMessage` calls now route through `MailModel.openInMailApp(_:)`.
- **Writeback / Gmail OAuth integration removed.** A "writeback router" with a Gmail API + IMAP backend was prototyped in response to Tahoe's broken AppleScript junk-mailbox handler. The Gmail OAuth flow shipped (PKCE loopback) and worked, but the maintenance surface (per-fork OAuth client registration, Keychain storage, refresh-token lifecycle, IMAP follow-up) wasn't worth it for one button. Move-to-Junk is gone from the UI, MCP, and AppleScript layers; Delete + Mark Read still go through `MailScripter` directly (those continue to work on Tahoe). `WRITEBACK_PLAN.md` deleted.
- **FTS5 column-filter AND fix.** `(from:x OR to:x) subject:y` used to compile to `(… OR …) {subject}: y*` which FTS5 rejects with a syntax error (implicit-AND grammar doesn't allow a parenthesised subexpression on either side of a column filter). `Evaluator.compileAND` now joins fused text branches with explicit `AND`, so the query parses and returns results.
- **Draft autosaves filtered + index pruning.** Gmail keeps stale draft autosaves in `[Gmail]/All Mail` with `messages.type = 5`, no Drafts label. `EnvelopeIndexReader.fetchAllMessages` skips them; new `IndexDB.pruneMessagesNotIn` runs after the upsert pass and drops any FMail row no longer present in Apple's index. Together: previously-ghosted draft duplicates clear on the next sync, and any future Apple-side deletion propagates without manual rebuild.
- **External attachment fill.** Mail.app stores Gmail attachment bytes out-of-line at `Attachments/<rowid>/<partIdx>/<filename>` and leaves `X-Apple-Content-Length` placeholders in the `.partial.emlx`. `BodyLoader.fillExternalAttachments` enumerates that directory after MIME parsing and pairs the on-disk files into the parsed attachment list — primary match by filename (with RFC 2231 `filename*0=…; filename*1=…` continuations decoded in `MIMEParser`), fallback by part-index order. Inline-bodied attachments are left untouched.
- **Optimistic DB delete on bulk-delete actions.** `ReadStatusController.applyOptimisticRemoval` now also calls `IndexDB.deleteMessagesByRowid` (one transaction across `messages`, `messages_fts`, `recipients`, `message_labels`, `message_links`). MCP- and UI-driven deletes are reflected in the DB and every view immediately; the next sync reconciles if the underlying AppleScript dispatch fails (the indexer's prune step only drops rowids that are actually gone from Apple's index).
- **MCP `get_attachment` tool.** Returns one attachment's bytes (base64-encoded post-MIME-decode) by message rowid + 0-based attachment index, with a configurable size cap (10 MB default). Lets MCP clients read PDFs and other binary attachments instead of seeing only `{name, content_type, byte_count}`. Failure modes (unknown rowid, index out of range, body not on disk) surface as structured JSON-RPC errors with actionable messages.

Remaining targets:
- Saved searches, keyboard shortcuts (`J`/`K`/`N`), quote folding, Quick Look on attachments.
- True incremental sync (currently full re-mirror per FSEvent; works but wasteful).
- Body indexer that picks up new mail discovered by FSEvents.
- Settings pane for address overrides.
- Schema-fingerprint test against live Envelope Index (DSL coverage shipped — see §10).
- Sandbox attempt.
- AppleScript compose path (for "send from this account" precision).
- iCloud alias unification (`@me.com` ≡ `@icloud.com` ≡ `@mac.com`).
- Natural-language fallback (§6.3).
- `cid:` inline image resolution.

**Stop conditions** (any of these → declare done, resist scope creep):
- You've used FMail as your daily reader for a month and the original four pain points are gone.
- You catch yourself wanting to add a feature Mail.app already does. Don't.
- A phase grows past one weekend → cut scope, don't extend the weekend.

### v2 candidates (not v1)

Only if v1 proves itself for 6+ months:

- Direct Gmail API client for the main Gmail account (sync independence from Mail.app). Previously promoted to an active writeback plan after macOS Tahoe broke `junk mailbox of <account>` AppleScript resolution; that plan (PKCE OAuth + `users.messages.modify` per-account router) shipped, was used briefly, and was removed — the maintenance surface (per-fork OAuth client, Keychain, refresh-token lifecycle, IMAP follow-up) didn't justify one button. Move-to-Junk is now simply not a feature. Re-entry would need a broader read-side independence rationale, not just writebacks.
- IMAP IDLE for iCloud (same reason).
- iOS companion viewer — see §14 for the strategy.

## 13. Open questions — resolved

| Question | Decision | Notes |
|---|---|---|
| Sandbox or not? | **Non-sandboxed** for v1. | FSEventStream + sandbox interaction unproven; deferred to Phase 5. |
| `GRDB.swift` vs raw `SQLite3` C API? | **Raw `SQLite3`.** | Zero new deps; verbose but small enough. |
| Single window or document-style? | **Single window**, three-pane. | Standard mail-client shape. |
| What to do about `[Gmail]/All Mail`? | **Hidden by default; eye toggle reveals.** | Matches `MailboxFilter`. |
| How to handle iCloud aliases? | **Not yet handled.** | Treat as separate identities currently. Phase 5 cleanup. |
| Bundled `.emlx` parsing vs reuse Apple's? | **Hand-rolled.** | No public Apple API. ~250 LoC across the Emlx/ files. |

---

**Bottom line**: FMail is a viewer over Apple Mail's local data with a *correct* unread count, a *real* search, *sane* recipient-address handling, and a *legible* thread view. Compose and send stay in Mail.app. Total v1 budget: ~5 weekends spread over a couple of months.

---

## 14. iOS companion — deferred, designed-for

iOS sandboxes prevent any third-party app from reading Mail.app's local data, so the Mac trick doesn't transfer. But a small iOS companion is still feasible by treating the **Mac as the indexer** and iOS as a reader of the synced index. Three shapes considered; one chosen.

### 14.1 Options considered

**A. iCloud Drive file sync (chosen).** Mac periodically copies `index.sqlite` (and a small `bodies/` dir of cached plain-text bodies) to `~/Library/Mobile Documents/com~apple~CloudDocs/FMail/`. iOS app opens the SQLite file read-only via `NSFileCoordinator`. Reply on iOS uses `mailto:` URLs into iOS Mail.app. **Pros**: trivially simple, no CloudKit schema, uses what we already build. **Cons**: read-only on iOS (preferences/saved-searches set on iOS would be lost — see 14.4); iOS only sees what the Mac has indexed, so freshness is bounded by Mac uptime + sync interval.

**B. CloudKit-backed shared store.** Same idea but records in a CloudKit private DB. **Pros**: bidirectional writes, partial fetches, conflict resolution. **Cons**: real schema-versioning work, more failure modes, more code. Defer unless we discover we *need* iOS-side writes.

**C. Standalone iOS client with own Gmail API + IMAP.** Independent of Mac. **Pros**: iOS works without Mac. **Cons**: full mail-client engineering — OAuth refresh, sync, push (APNs proxy), offline cache, rate limits, account UI. This is exactly the scope creep §3 forbids.

### 14.2 Chosen: A (iCloud Drive sync)

**Mac side**:
- New "Companion sync" pane in settings, off by default.
- When enabled, after each successful incremental index pass, the Mac:
  - Writes a fresh copy of `index.sqlite` to `~/.../CloudDocs/FMail/index.sqlite.tmp`, then atomic-renames over `index.sqlite`.
  - Writes plain-text bodies for messages within a configurable retention window (default: last 12 months, last 5 years for flagged) into `bodies/<message-id>.txt`.
  - Writes a small `manifest.json` with schema version + last-updated timestamp.
- Coordinator: `NSFileCoordinator` to play nice with iCloud Drive.
- Throttle: at most once every N minutes; skip if no changes.

**iOS side**:
- SwiftUI app, iOS 17+.
- Reads `index.sqlite` from iCloud Drive (read-only). Same query DSL parser, same FTS5 search, same thread grouping logic — all reused via a Swift package (see implementation plan).
- For reply / new mail / forward: build `mailto:` URL with `subject=`, `body=`, `cc=`, `in-reply-to=` (the last one isn't standard but iOS Mail honours it for threading in many setups; if not, the user still gets the right To/Subject/quoted-body).
- Show a "stale by Xh" badge if `manifest.json` timestamp is older than a threshold, so the user knows freshness is bounded.

### 14.3 What gets shared as code

A Swift Package, e.g. `FMailCore`, that contains:
- `.emlx` parser
- Query DSL parser/evaluator (the search grammar)
- Thread grouping by `Message-ID` / `In-Reply-To` / `References`
- SQLite schema definition + read helpers
- Contact-resolution helpers (read-only on iOS, since Apple Contacts framework also exists on iOS)

Mac- and iOS-specific code (UI, file watching, AppleScript, iCloud Drive sync) sits in the respective app targets.

### 14.4 Read-only constraint, and what to do about it

Companion-sync v1 is **read-only on iOS**. That means:
- Preferred-address overrides, saved searches, and "marked read" actions cannot originate on iOS.
- "Mark read" on iOS would also fail to propagate to Mail.app anyway (we don't write into Apple's store on Mac either).

If this turns out to matter, the upgrade path is option B (CloudKit) — but only after evidence that the limitation hurts in practice.

### 14.5 Phasing

Treated as a separate, optional phase **after** Mac v1 has proved itself for 1+ month:

- **iOS-Phase 1 (1 weekend)**: Mac-side iCloud Drive writer (gated behind a settings toggle).
- **iOS-Phase 2 (1 weekend)**: iOS app skeleton, opens the synced sqlite, lists mailboxes + messages.
- **iOS-Phase 3 (1 weekend)**: search + thread view (reusing `FMailCore`).
- **iOS-Phase 4 (1 evening)**: `mailto:` reply handoff to iOS Mail.

If Mac v1 isn't hitting daily-use bar, do not start the iOS phases.

---

## 15. MCP server (Phase 5 polish)

When FMail is running, an opt-in HTTP/JSON-RPC server on `127.0.0.1:8765` exposes the index to MCP clients (Claude Code, etc.). The point is to leverage what FMail already builds — schema-versioned SQLite, FTS5, the DSL, threading, contact prefs — so an LLM can triage email without parsing `.emlx` itself or pulling the whole index into context. See [MCP_PLAN.md](MCP_PLAN.md) for the full design.

**Eight tools, all read-only.** The MCP surface is deliberately non-destructive — Mail state changes happen via FMail's UI (or Mail.app directly), never through MCP. Makes the connector safe to expose over a public tunnel; worst-case an attacker who got past the bearer token can read mail, not delete or mark it.

| Tool | Purpose |
|---|---|
| `search_emails` | DSL-driven search; description embeds the full §6.2 grammar. Per-row fields: `account_email` (which mail account), `rfc_message_id` (cross-system reference), `body_on_disk` (whether body fetch will hit an IMAP round-trip). Optional `include_attachment_metadata` adds `attachments` per row (gated — costs one body load per result). `sort` controls ordering: `newest_first` (default), `oldest_first`, `relevance` (currently falls back to newest_first). |
| `list_threads` | Thread summaries (mailbox-scoped or All Mailboxes). |
| `list_accounts` | Introspection — returns `[{uuid, display_name, email_address}]`. Tells callers which `account:` values are valid filters. |
| `get_thread` | All messages in a thread, with `body_format` (plain / clean / raw), `max_body_chars` per message, `max_total_chars` across the thread, and `direction` (oldest_first / newest_first). `body_format: clean` strips quoted reply chains, signatures, and known tracking-URL wrappers (Mimecast, Outlook safelinks, Google AMP) — typically shrinks long Savills-style threads 5–10×. `max_body_chars=0` returns headers + attachments only. `max_total_chars` truncates the tail of whatever direction is in effect; response surfaces `omitted_message_count`. Per-message fields: `account_email`, `in_reply_to_rowid` (parent message rowid via Mail.app's `message_links`, when known), `rfc_message_id`, `body_on_disk`. |
| `get_email` | One message by rowid; same shape as a `get_thread` row. Accepts `body_format`. |
| `get_attachment` | One attachment's bytes by rowid + 0-based index. Two modes: when `save_to_path` is supplied, the server writes the decoded bytes to disk and returns metadata + `saved_path` (no payload-size cap); otherwise returns `data_base64` (default 10 MB cap, base64 inflates ~33%). Resolves Mail.app's external `Attachments/<rowid>/<partIdx>/<filename>` store transparently (see §5.1). |
| `get_attachments_for_rowids` | Bulk variant — fans out across `rowids[]`, writes every attachment to `save_dir/<rowid>/<filename>`. Returns `{saved: [...], errors: [...]}` so a single missing-on-disk body doesn't fail the batch. Designed for "pull every invoice attachment from these 12 messages" workflows. |
| `find_unanswered_threads` | Threads where the user sent the latest message and hasn't heard back. |

Previously-shipped write tools (`mark_read`, `delete_messages`, `move_to_junk`, `diagnose_junk_mailboxes`) have all been removed. Mark-read functionality still works through FMail's UI; delete/junk are out of scope per §12 Phase 5.

DSL features pulled in from real-world MCP usage (see CLAUDE-MCP-FEEDBACK section in [MCP_PLAN.md](MCP_PLAN.md) if/when written up):

- **`after:` is inclusive of the period start** for every granularity — `after:2024` is `>= 2024-01-01`, matching Gmail's behaviour. (Previously `after:2024` meant `>= 2025-01-01`, which surprised every user and LLM that came in expecting Gmail semantics.)
- **`thread:<id>` field operator** — narrows to one conversation. Combine with `body:` to grep within a thread (`thread:1234 body:"550k"`).
- **Address / domain matching** for `from:` / `to:` / `cc:` / `attachment:` values: FMail tokenises the value on non-alphanumerics so `from:savills.com` ANDs `[savills, com]` against the sender column — hits any `@savills.com` sender even though FTS5 indexed the address as separate tokens at `@` and `.` boundaries.

Locked decisions: hand-rolled JSON-RPC + minimal HTTP framing on `Network.framework` (no SDK dep); off by default with an explicit privacy banner; loopback only (`requiredInterfaceType = .loopback`); a single bundled DSL string for `search_emails` rather than a structured-params second tool. No SSE/streaming progress; not needed once every tool is bounded and read-only.

**Bearer-token auth (opt-in).** `MCPSettings.authToken` (32-byte random, base64url-encoded, persisted in `UserDefaults`). When non-empty, every `POST /mcp` must include `Authorization: Bearer <token>` or it's rejected at HTTP 401 before the dispatcher runs. Constant-time compare. `GET /mcp` (server-info probe) stays unauthenticated for `curl` sanity checks. When the token is empty, current behaviour is unchanged (loopback-only, no auth) — friction-free for local Claude Code on the same Mac. The token is the precondition for the Cloudflare tunnel toggle below: the UI refuses to open the tunnel until a token is set.

**Cloudflare tunnel toggle.** A `TunnelCoordinator` (MainActor `@Observable`) spawns `cloudflared tunnel --url http://127.0.0.1:<port> run <name>` as a child `Process`, watches stderr for `Registered tunnel connection`, and transitions through `.starting → .running(url:) → .stopping → .off`. The public URL is `MCPSettings.tunnelPublicURL` (typed in by the user — cloudflared doesn't print it for named tunnels). Pre-flight refuses with a clear message if `cloudflared` isn't installed, the user isn't logged in (`~/.cloudflared/cert.pem` missing), the MCP server isn't running, the auth token is empty, or tunnel name / public URL fields are empty. State is **not** persisted across launches — every session starts with the tunnel off, since opening it is an active security decision and "I forgot the tunnel was open" is the failure mode the visible banner exists to prevent. Subprocess cleanup on `applicationWillTerminate`. Quick tunnels (`*.trycloudflare.com`) are not exposed in the UI — the log parser keeps the URL-extraction helper for dev/test use only.

**MCP OAuth 2.1 / RFC 7636 for remote clients.** Claude.ai's "Custom Connector" flow (which Cowork rides on) expects the remote MCP server to implement OAuth — the connector form has no static-bearer field. FMail's server adds the minimum surface to satisfy it:

- `GET /.well-known/oauth-authorization-server` — RFC 8414 metadata pointing at `/authorize`, `/token`, `/register`; advertises `S256` PKCE only.
- `POST /register` — RFC 7591 dynamic client registration; issues a random `client_id`, empty `client_secret` (public client).
- `GET /authorize` — renders an HTML approval page. Gated by an explicit **approval window** that the user opens from Settings ("Open approval window (5 min)"). While the window is closed, the page tells the user to open it in FMail first. While open, the page shows the requesting `client_id` / `redirect_uri` / `scope` with Approve / Deny buttons.
- `POST /authorize/approve` — generates an authorization code (10-min TTL, one-time use), stores the PKCE challenge + redirect_uri + client_id, redirects the browser to `redirect_uri?code=…&state=…`. Closes the approval window immediately so one window grants exactly one code.
- `POST /authorize/deny` — redirects with `?error=access_denied` per RFC 6749 §4.1.2.1.
- `POST /token` — exchanges the auth code for a session token after verifying PKCE (`base64url(SHA256(verifier)) == challenge`), redirect_uri match, and client_id match. Issues a fresh 32-byte session token, persists `(token → {client_id, issued_at, label})` to `UserDefaults` so the connector survives FMail restarts.
- `POST /mcp` bearer check accepts the static `MCPSettings.authToken` OR any active session token in `OAuthStore.shared.sessions`.

Settings → MCP gains an "OAuth Pairing" section with the approval-window toggle (live countdown), an active-sessions list, and per-session revoke + revoke-all buttons. Revoking a session is immediate; the next request from that client gets a 401.

The approval window is the only thing standing between the public URL and an unsolicited grant. The user opens it intentionally before kicking off the connector flow in Cowork; it closes itself after one approval or 5 minutes. Combined with PKCE, a successful grant requires (a) the user explicitly opening the window, (b) the user explicitly clicking Approve while seeing the redirect URI, and (c) the client knowing the pre-generated PKCE verifier — so a phishing approval from a third party can't yield a usable token even mid-window.

Standalone daemon mode (so FMail doesn't have to be open) is **not** v1 — see MCP_PLAN.md "Stopping condition" for when to pivot to a `FMailCore` Swift package + LaunchAgent.
