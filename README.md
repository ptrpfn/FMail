<p align="center">
  <img src="FMail.png" alt="FMail icon" width="128" height="128">
</p>

<h1 align="center">FMail</h1>

<p align="center">
  A small, opinionated macOS email <strong>viewer</strong> that fixes four specific Apple Mail pain points.<br>
  Compose / send stay in Mail.app — FMail does not try to be a full mail client.
</p>

---

## Why

Concrete pain points with Apple Mail that FMail solves:

1. **Drifting unread counts.** The badge and the actual unread set disagree.
2. **Weak search.** No real boolean operators, awkward date syntax, no good way to scope by topic + time + person at once.
3. **Wrong recipient address.** Mail.app picks at random when a contact has multiple addresses (e.g. a real address and an App-Store-only address).
4. **Illegible threads.** Hard to see what's actually new in a long reply chain.

Surveyed alternatives (Mimestream, MailMate, Spark, Canary, Airmail, …) are either Gmail-only, subscription churn, cloud-routed (privacy), or have the same bugs — and most get abandoned within a year. So: build something tiny and personal.

## How it works

FMail reads Apple Mail's `~/Library/Mail/V*/` store **read-only**, mirrors the metadata into its own SQLite + FTS5 index, and renders a faster UI on top. Reply / forward open Mail.app's compose window via `mailto:` URLs — no SMTP, no sync layer, no cloud. Apple Mail keeps doing the actual mail-server talking; FMail just gives you a better way to read and find what's already there.

## Highlights

- **Search DSL** — `from:kyoko after:2024-03 (invoice OR receipt) -draft has:attachment "exact phrase"`. Field operators, boolean operators (`AND` / `OR` / `NOT`) that compose freely across text, dates, and flags, and several flavours of relative date. Full grammar in [Search syntax](#search-syntax) below.
- **Per-contact preferred address** — never mis-send to a contact's secondary address again.
- **Threads via union-find** on `Message-ID` / `In-Reply-To` / `References`.
- **"All Mailboxes" view** across every account, with drafts / trash / junk filtered out. Auto-selected on launch. Dock badge shows the global unread count.
- **Mail.app's threading still works** — replies set proper `In-Reply-To` and `References` headers via RFC 6068 mailto parameters.
- **HTML emails render natively** in a locked-down WKWebView. Strict Content-Security-Policy blocks all network — no read-tracking pixels, no remote-image leaks.
- **Per-message "Load remote images" button** for newsletters with graphs etc. Opt-in only, ephemeral (resets when you re-open the email).
- **"Open in Mail.app" button** for messages whose body Mail.app hasn't downloaded yet (uses the `message://` URL scheme).
- **Mark as Read / Mark as Unread** via Mail.app (AppleScript) — Mail.app still gets the change so it propagates to the IMAP server.
- **Zero network connections by default.** No outbound traffic, no telemetry. The only network FMail ever makes is when you explicitly click "Load remote images" on a specific message.
- **Apple's Gmail label model handled** — `[Gmail]/All Mail` is the canonical store, INBOX/Sent/Important are labels; FMail mirrors the labels table and shows them correctly.
- **Optional read-only MCP server** for local LLM clients (Claude Code, claude.ai connectors) — search, read threads, fetch attachments to disk. Off by default. Bearer-token auth + opt-in Cloudflare-tunnel toggle for remote clients. See [MCP server](#mcp-server) below.

## Search syntax

The search bar takes a structured query. Adjacent terms are AND-ed; everything composes freely with `AND` / `OR` / `NOT`, parens, and quoted phrases.

### Operators

| | |
|---|---|
| `AND` | implicit between adjacent terms; can be written explicitly |
| `OR` | disjunction. Composes across text, date, flag and scope predicates. |
| `NOT` *or* `-` *prefix* | negation. `NOT` keyword before a term, or `-` glued to it. |
| `( ... )` | grouping |
| `"exact phrase"` | verbatim match. Without quotes, terms match by **prefix** — so `subject:v` finds `vermont`. |

### Field operators

| Operator (and aliases) | Matches | Example |
|---|---|---|
| `from:` | sender (address or display name); domain-style works | `from:kyoko`, `from:savills.com` |
| `to:` | "To:" recipient; domain-style works | `to:me`, `to:savills.com` |
| `cc:` | "Cc:" recipient | `cc:anna` |
| `subject:` *(or `subj:`)* | subject only | `subject:invoice` |
| `body:` *(or `content:`, `text:`)* | body content only | `body:meeting` |
| `attachment:` *(or `filename:`)* | attachment filename | `attachment:invoice.pdf` |
| `thread:<id>` | scope to one conversation — useful with `body:` to grep within a thread | `thread:1234 body:"550k"` |
| `account:` | scope to one account (email, or UUID prefix) | `account:gmail.com` |
| `in:` | scope to mailbox kind: `inbox`, `sent`, `drafts`, `trash`, `junk`, `archive`, `all` | `in:sent` |
| `is:read` / `is:unread` / `is:flagged` *(or `is:starred`)* / `is:unflagged` *(or `is:unstarred`)* | flag scope | `is:unread` |
| `has:attachment` *(or `has:attachments`, `has:att`)* | attachment scope | `has:attachment` |
| `before:DATE` | strictly before start of period | `before:2026-03` |
| `after:DATE` *(or `since:DATE`)* | from start of the period onwards — inclusive | `after:2024` |
| `on:DATE` / `during:DATE` | the entire period (year / month / day) | `during:2025` |

Values for `from:` / `to:` / `cc:` / `attachment:` are split on non-alphanumeric characters, so `from:savills.com` ANDs the tokens `savills` and `com` against the sender column and matches any `@savills.com` address. (FTS5's tokeniser breaks email addresses at `@` and `.`, so a single-token search would miss them.)

**No-colon shortcuts** also work as bare words: `hasattachment` (or `hasattachments`), `isunread`, `isread`, `isflagged` (or `isstarred`).

### Date forms

| Form | Examples | Granularity |
|---|---|---|
| ISO | `2024-03-15`, `2024-03`, `2024` | day / month / year |
| Single word | `today`, `yesterday`, `tomorrow` | day |
| Compact relative ("N units ago") | `7d`, `2w`, `3m`, `1y` | day |
| Multi-word relative *(must be quoted)* | `"last week"`, `"last month"`, `"last year"`, `"last 30 days"`, `"this week"`, `"this month"`, `"this year"` | day |
| Month names | `march`, `march 2024` | month |

### Date-bound semantics

`before:` is exclusive of the period start; `after:` (and its alias `since:`) is inclusive of the period start; `during:` / `on:` matches the whole period at the precision you typed:

| Query | Means |
|---|---|
| `before:2026` | `< 2026-01-01` |
| `before:2026-03` | `< 2026-03-01` |
| `after:2024` | `>= 2024-01-01` (Gmail-style — inclusive) |
| `after:2024-03` | `>= 2024-03-01` |
| `after:2024-03-15` | `>= 2024-03-15` |
| `during:2025` | all of 2025 |
| `during:2025-03` | all of March 2025 |
| `during:2025-03-15` | that one day |

### Examples

```text
kyoko school trip                                # bag-of-words anywhere
from:kyoko subject:invoice                       # all-fields AND (implicit)
"exact phrase" -draft                            # phrase + NOT (-)
from:anna ("school trip" OR "ski trip")          # quoted phrases inside OR
(from:kyoko OR from:meiko) is:unread             # OR mixes text with flags
(during:2025 OR during:2023) from:promo          # OR mixes date ranges
account:gmail.com (subject:invoice OR subject:receipt) after:2024
in:sent has:attachment after:"last 30 days"      # multi-word date needs quotes
-(during:2024 from:promo)                        # NOT around a group
since:march from:anna                            # `since:` is `after:` alias; month name
```

The search bar shows an **"Interpreted as"** strip below the input — a canonical reconstruction of what the parser made of your query. If a query returns nothing unexpected, this is the first place to look.

## Status

Daily-driver capable. Phases 0–4 shipped — all four pain points closed. Phase 5 (polish) is ongoing. See [`IMPLEMENTATION.md`](IMPLEMENTATION.md) for per-phase status, file inventory, and the polish backlog.

## Requirements

- macOS 14 (Sonoma) or later.
- Apple Mail set up with your accounts (FMail reads its on-disk data; it doesn't talk to mail servers itself).
- **Full Disk Access** granted to FMail (so it can read `~/Library/Mail/`). The app prompts on first launch.
- **Contacts permission** (optional) — used to suggest the right address per contact when replying. Lazy-prompted the first time you reply.
- **Automation permission** to control Mail.app (optional) — required for "Mark as Read" / "Mark as Unread", which drive Mail.app via AppleScript. macOS prompts the first time you click one of those buttons. If you decline or dismiss the prompt, you'll need to enable it manually under **System Settings → Privacy & Security → Automation → FMail → Mail**. (FMail surfaces a one-click button to open that pane when it detects the permission has been denied.)

## Build

Requires Xcode 15+ and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project FMail.xcodeproj -scheme FMail -configuration Debug build
```

The `.xcodeproj` is generated from `project.yml` and not checked in.

## MCP server

FMail ships an optional **read-only** MCP (Model Context Protocol) server that exposes the index to local LLM clients. Off by default; enable in Settings → MCP. When enabled, it listens on `127.0.0.1:8765` and accepts JSON-RPC over HTTP/POST.

### What's exposed

Eight tools, all non-destructive — Mail state changes happen through FMail's UI or Mail.app directly, never through MCP. Read-only by design so it's safe to expose over a tunnel.

| Tool | Purpose |
|---|---|
| `search_emails` | The DSL above. Returns `account_email` / `rfc_message_id` / `body_on_disk` per row. Optional `include_attachment_metadata: true` adds attachment metadata per row (gated — costs one body load per result). Optional `sort: newest_first | oldest_first | relevance`. |
| `list_threads` | Thread summaries (mailbox-scoped or All Mailboxes). |
| `list_accounts` | Introspection — which accounts FMail has indexed; tells you which `account:` filter values are valid. |
| `get_thread` | All messages in a thread. `body_format: "clean"` strips quoted reply chains, signatures, and known tracking-URL wrappers (Mimecast, Outlook safelinks, etc.) — typically shrinks long threads 5–10×. `max_total_chars` budgets the whole thread; `direction` toggles oldest/newest first. |
| `get_email` | One message by rowid. Accepts the same `body_format`. |
| `get_attachment` | One attachment's bytes by rowid + 0-based index. With `save_to_path` the server writes the decoded file to disk and returns metadata + `saved_path` (no payload-size cap — the right path for any non-trivial PDF). Without it, returns `data_base64` (default 10 MB cap). |
| `get_attachments_for_rowids` | Bulk variant — writes every attachment of every supplied rowid to `save_dir/<rowid>/<filename>`. |
| `find_unanswered_threads` | Threads where you sent the latest message and haven't heard back. |

### Setting it up (local Claude Code)

Settings → MCP server → toggle on. Then in Settings → "Set up your MCP client" → **Copy local Claude Code config** writes the right JSON snippet to your clipboard. Paste it into `~/.claude/settings.json` under `mcpServers`. Restart Claude Code; the `mcp__fmail__*` tools appear.

### Bearer-token auth

By default the server is loopback-only (`requiredInterfaceType = .loopback`), which is fine for local use. If you want to expose it more widely (see tunnel below), generate a token from Settings → "Auth Token" → **Generate token**. Once a token is set, every request must include `Authorization: Bearer <token>` or it's rejected with HTTP 401. The "Copy" buttons in Settings bake the header into the JSON snippet for you.

### Cloudflare tunnel (for remote clients like claude.ai connectors)

FMail can spawn a `cloudflared` child process and route a public hostname through to its loopback MCP endpoint. Settings → MCP → "Cloudflare Tunnel".

One-time setup in Terminal:

```bash
brew install cloudflared
cloudflared tunnel login
cloudflared tunnel create fmail
cloudflared tunnel route dns fmail fmail.your-domain.com
```

Then in FMail Settings:

1. **Auth Token** → Generate (required before the tunnel can be opened).
2. **Cloudflare Tunnel** → Tunnel name = `fmail`, Public URL = `https://fmail.your-domain.com`.
3. Click **Open tunnel**. A red banner appears at the top of the FMail window and a red dot in the footer; status flips to "Running".

To pair with claude.ai's "Custom Connector" flow (which requires OAuth, not a static token):

4. **OAuth Pairing** → Click **Open approval window (5 min)**.
5. In claude.ai / Cowork → add custom connector → paste `https://fmail.your-domain.com/mcp`.
6. claude.ai will open FMail's `/authorize` page in your browser; click **Approve**. The OAuth-issued session token is persisted to UserDefaults, so the connector survives FMail restarts. Revoke any time from Settings → "Active sessions".

The tunnel state itself is **not** persisted across launches — you have to click "Open tunnel" each time. This is deliberate: opening a public-internet ingress to your mail is an active security decision; the visible banner exists so "I forgot the tunnel was open" can't quietly happen.

### Threat model (worth being honest about)

- **Loopback-only mode, no token**: anything on your Mac that can connect to `127.0.0.1:8765` can read your mail. Same threat surface as anything else running as your user.
- **Loopback + token**: as above, but only clients with the token can read. Still local.
- **Tunnel + token**: your mail index is reachable from the public internet. The token is the only thing gating it. Keep the tunnel closed when you're not actively using it; the banner makes this hard to forget.
- **OAuth session tokens** (claude.ai connector flow): persist across restarts. Revoke from Settings if a client is compromised.

## Design docs

- [`FMailSpec.md`](FMailSpec.md) — design intent: pain points, architecture, phased plan.
- [`IMPLEMENTATION.md`](IMPLEMENTATION.md) — what actually shipped, deviations from the spec, file inventory, Phase 5 backlog.
- [`MCP_PLAN.md`](MCP_PLAN.md) — MCP server design (loopback HTTP/JSON-RPC for LLM clients).

## License

Copyright (C) 2026 Felix Matschke

FMail is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. See [`LICENSE`](LICENSE) for the full text.

> Note: GPL-3.0 is incompatible with Apple's App Store distribution. Direct download / sideload only.
