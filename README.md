<p align="center">
  <img src="FMail.png" alt="FMail icon" width="128" height="128">
</p>

<h1 align="center">FMail</h1>

<p align="center">
  A tiny macOS <strong>menu-bar</strong> companion for Apple Mail: correct unread counts and a
  real search query language, one click away — reading and replying stay in Mail.app.
</p>

---

## What it is

FMail lives entirely in the **menu bar**. There is no main window and no Dock icon. Click the
envelope icon and a dropdown gives you:

- Your **unread** messages (or **search results** when you type in the search box), split into a
  **Priority Messages** and an **Other Messages** block ([see below](#priority-vs-other-messages)) —
  each newest-first with **Today / Yesterday / date** separators, and each row carrying an unread dot
  and a checkbox.
- Per-block **Mark all Priority/Other Messages as read** / **as unread** commands — or tick a few rows
  and they collapse to **Mark N as read** / **Mark N as unread** acting on just the ticks. Whichever
  command would change nothing is disabled: in the default unread-only list "as unread" greys out until
  a search surfaces already-read mail. "Mark all" acts on *every* matching message in the block, not
  only the rows currently visible.
- A per-email **submenu** (click the title or the `›`): **Open in Mail**, **Reply**, **Reply All**,
  **Forward**, then the full **subject**, the From / To / Date details, and a **📎 Has attachments**
  line for messages with a real file attachment (inline signature images don't count).
- An **MCP/Tunnel** submenu for the optional local MCP server and Cloudflare tunnel.
- **Settings…** — a **Connection** tab (MCP / token / tunnel) and a **Priority Messages** tab — and
  **Quit**.

The menu-bar icon carries the global unread count as a badge.

FMail reads Apple Mail's `~/Library/Mail/V*/` store **read-only**, mirrors the metadata into its own
SQLite + FTS5 index, and surfaces it. It deliberately does **not** render message bodies itself —
"Open in Mail" hands off to Mail.app, which is faster and more reliable at fetching and displaying a
message than re-rendering it would be. Reply / Reply All / Forward drive Mail.app's own AppleScript
commands, so Mail opens its familiar compose window with the original properly quoted. Nothing is
sent by FMail; no SMTP, no sync layer, no cloud.

> **Two UIs, two branches.** This (`master`) is the minimal menu-bar build. The earlier full
> three-pane window app — sidebar, thread reader, in-app HTML rendering, per-contact preferred-address
> handling — lives on the [`window-UI`](../../tree/window-UI) branch. Both read the same index.

## Priority vs. Other messages

The unread list — and every search result — is split into two blocks so the replies you're waiting on
don't drown under newsletters, receipts and notifications:

- **Priority Messages** — unread mail from senders you care about.
- **Other Messages** — everything else.

Within each block, rows are newest-first under **Today / Yesterday / "5 Jun 26" / "Older than a week"**
date separators.

A sender counts as **priority** when it is **either**:

1. **Someone you've emailed** — derived automatically from your sent mail (anyone you put in To / Cc /
   Bcc). The reasoning: if you wrote to them, you probably want to see the response. This auto-list is
   maintained for you; you can't remove its entries.
2. **On your supplemental list** — addresses or patterns you add by hand, for senders you only ever
   *receive* from (a landlord's no-reply address, a service you never write back to, …).

You manage the supplemental list under **Settings → Priority Messages**, which shows the auto-list
greyed-out (non-removable) beneath your own editable entries. A supplemental entry can be a **full
address** (exact match), a **bare word or domain** like `savills` or `ubs.com` (matches any address
containing it), or an explicit **wildcard pattern** using `*` / `?` (e.g. `*@savills.com`). Add several
at once separated by `;`, or pick from a **dropdown of the 20 most recent senders you've received
from**.

Each block carries its own **Mark all … as read / as unread** commands (acting on every matching
message, not just the visible rows); per-row checkboxes still let you mark an arbitrary selection.

## Why

Concrete Apple Mail pain points FMail targets:

1. **Drifting unread counts.** The badge and the actual unread set disagree. FMail computes the count
   from Apple's Envelope Index and shows the real unread list in the dropdown, refreshed every time
   you open it.
2. **Weak search.** No real boolean operators, awkward dates, no way to scope by topic + time +
   person at once. FMail's search box takes a structured query language (below).
3. **Real replies buried under noise.** A busy unread list mixes the reply you're waiting on with
   newsletters and receipts. FMail splits unread (and search results) into **Priority** and **Other**
   blocks — priority = anyone you've emailed, plus a hand-edited allow-list — so the mail you actually
   care about surfaces first ([details](#priority-vs-other-messages)).

Surveyed alternatives (Mimestream, MailMate, Spark, Canary, Airmail, …) are either Gmail-only,
subscription churn, cloud-routed (privacy), or carry the same bugs — and most get abandoned within a
year. So: build something tiny and personal.

## How it works

FMail runs as an `LSUIElement` accessory. On launch it mirrors Apple's Envelope Index into
`~/Library/Application Support/FMail/index.sqlite` (full index on first run; incremental afterwards,
driven by an `FSEventStream` on the mail store plus a periodic safety-net sync). Opening the menu also
runs a **fast read/unread reconcile** — it reads just the `read` flags from Apple's Envelope Index and
updates the changed rows, so marking something read/unread in Mail.app shows up the next time you open
the menu instead of waiting for a full sync.

## Search syntax

The search box takes a structured query. Adjacent terms are AND-ed; everything composes freely with
`AND` / `OR` / `NOT`, parens, and quoted phrases. Type a query and the email list becomes the results —
still split into **Priority** and **Other** blocks (up to 15 rows each); clear it and the list returns
to unread.

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
| `from:` | sender (address or display name); domain-style works | `from:alice`, `from:vendor.com` |
| `to:` | "To:" recipient; domain-style works | `to:me`, `to:vendor.com` |
| `cc:` | "Cc:" recipient | `cc:bob` |
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

Values for `from:` / `to:` / `cc:` / `attachment:` are split on non-alphanumeric characters, so
`from:vendor.com` ANDs the tokens `vendor` and `com` against the sender column and matches any
`@vendor.com` address. (FTS5's tokeniser breaks email addresses at `@` and `.`, so a single-token
search would miss them.)

**No-colon shortcuts** also work as bare words: `hasattachment` (or `hasattachments`), `isunread`,
`isread`, `isflagged` (or `isstarred`).

### Date forms

| Form | Examples | Granularity |
|---|---|---|
| ISO | `2024-03-15`, `2024-03`, `2024` | day / month / year |
| Single word | `today`, `yesterday`, `tomorrow` | day |
| Compact relative ("N units ago") | `7d`, `2w`, `3m`, `1y` | day |
| Multi-word relative *(must be quoted)* | `"last week"`, `"last month"`, `"last year"`, `"last 30 days"`, `"this week"`, `"this month"`, `"this year"` | day |
| Month names | `march`, `march 2024` | month |

### Date-bound semantics

`before:` is exclusive of the period start; `after:` (and its alias `since:`) is inclusive of the
period start; `during:` / `on:` matches the whole period at the precision you typed:

| Query | Means |
|---|---|
| `before:2026` | `< 2026-01-01` |
| `before:2026-03` | `< 2026-03-01` |
| `after:2024` | `>= 2024-01-01` (Gmail-style — inclusive) |
| `after:2024-03` | `>= 2024-03-01` |
| `during:2025` | all of 2025 |
| `during:2025-03` | all of March 2025 |

### Examples

```text
from:alice subject:invoice                       # all-fields AND (implicit)
"exact phrase" -draft                            # phrase + NOT (-)
from:alice ("school trip" OR "ski trip")         # quoted phrases inside OR
(from:alice OR from:bob) is:unread               # OR mixes text with flags
account:gmail.com (subject:invoice OR subject:receipt) after:2024
in:sent has:attachment after:"last 30 days"      # multi-word date needs quotes
since:march from:alice                           # `since:` is `after:` alias; month name
```

## Requirements

- macOS 14 (Sonoma) or later.
- Apple Mail set up with your accounts (FMail reads its on-disk data; it never talks to mail servers).
- **Full Disk Access** granted to FMail (to read `~/Library/Mail/`). Until it's granted, the dropdown
  shows a "Grant Full Disk Access…" item that opens the right System Settings pane. Grant it, then
  quit (envelope → Quit FMail) and relaunch.
- **Automation permission** to control Mail.app — required for Mark as Read / Unread and for
  Reply / Forward (which drive Mail.app via AppleScript). macOS prompts the first time. If declined,
  enable it under **System Settings → Privacy & Security → Automation → FMail → Mail**.

## Build

Requires Xcode 15+ and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project FMail.xcodeproj -scheme FMail -configuration Debug build
```

The `.xcodeproj` and `Info.plist` are generated from `project.yml` and not checked in. Run the app
once and look for the **envelope icon in the menu bar** (no window, no Dock icon).

---

## MCP server

FMail ships an optional **read-only** MCP (Model Context Protocol) server that exposes the index to
LLM clients (Claude Code, claude.ai connectors). It listens on `127.0.0.1:8765` and speaks JSON-RPC
over HTTP/POST. It is **on by default** in this build (an explicit toggle-off persists); turn it off
or on from the menu under **MCP/Tunnel → MCP**.

### What's exposed

Eight tools, all non-destructive — Mail state changes happen through Mail.app, never through MCP.
Read-only by design so it's safe to expose over a tunnel.

| Tool | Purpose |
|---|---|
| `search_emails` | The DSL above. Returns `account_email` / `rfc_message_id` / `body_on_disk` per row. Optional `include_attachment_metadata`, `sort`. |
| `list_threads` | Thread summaries (mailbox-scoped or All Mailboxes). |
| `list_accounts` | Which accounts FMail has indexed — the valid `account:` filter values. |
| `get_thread` | All messages in a thread. `body_format: "clean"` strips quoted chains/signatures/tracking-URL wrappers; `max_total_chars` budgets the whole thread. |
| `get_email` | One message by rowid. Same `body_format`. |
| `get_attachment` | One attachment by rowid + index. `save_to_path` writes to disk (no size cap); otherwise returns base64 (10 MB cap). |
| `get_attachments_for_rowids` | Bulk variant — writes every attachment of every supplied rowid to `save_dir/<rowid>/<filename>`. |
| `find_unanswered_threads` | Threads where you sent the latest message and haven't heard back. |

### Authentication model

- **Loopback, no token:** if no auth token is set and no tunnel is configured, the server serves
  unauthenticated on `127.0.0.1` only.
- **Static bearer token:** set a token (Settings → Connection → Auth token → Generate) and every request must carry
  `Authorization: Bearer <token>`. This is the credential the local Claude Code route uses.
- **OAuth session tokens:** issued to remote clients (claude.ai connectors) via the approval flow.
- **Fail-closed:** if a tunnel is configured but no token / session exists, the server refuses every
  request rather than expose your mail unauthenticated.

> **Why a token is needed even locally once a tunnel exists:** `cloudflared` runs on your Mac, so
> tunnel traffic also arrives on `127.0.0.1`. The server can't tell a genuine local client from a
> remote one by address — so once a tunnel is configured, the token gates *all* requests, local
> included.

---

## Step-by-step: local Claude Code (token auth, no OAuth)

This connects Claude Code on the same Mac to FMail over loopback, authenticated by the static token.

1. **Turn the MCP server on** (it's on by default). In the menu: **MCP/Tunnel → MCP** should be
   ticked. Optionally change the port in **Settings → Connection → MCP → Port** (default `8765`).
2. **Generate an auth token.** **Settings → Connection → Auth token → Generate**, then **Copy**. (You can also read
   it from `defaults read com.felixmatschke.FMail mcp.auth.token`.)
3. **Add the server to Claude Code** with the token in an `Authorization` header. In your
   `~/.claude.json`, under the relevant project's `mcpServers`:

   ```jsonc
   "fmail": {
     "type": "http",
     "url": "http://127.0.0.1:8765/mcp",
     "headers": { "Authorization": "Bearer <PASTE_TOKEN_HERE>" }
   }
   ```

   The header is what makes this work without OAuth: the first request is already authenticated, so
   the server returns `200` and the client never enters the OAuth discovery flow.
4. **Restart Claude Code** (or reconnect via `/mcp`). The `mcp__fmail__*` tools appear.

**Verifying / troubleshooting.** Watch FMail's access log:

```bash
log stream --predicate 'subsystem == "com.felixmatschke.FMail" && category == "mcp"' --info
```

A successful call logs `→ POST /mcp status=200 auth=yes`. If you see `status=401`, the token in the
header doesn't match the one in FMail Settings. (The server also advertises host-appropriate OAuth
discovery metadata — a loopback request gets `resource: http://127.0.0.1:8765/mcp` — so even the
discovery path matches the URL you connected to rather than the tunnel's public URL.)

---

## Step-by-step: Cloudflare tunnel (remote access, e.g. claude.ai connectors)

This exposes the loopback MCP endpoint at a public hostname through a named Cloudflare tunnel. FMail
spawns `cloudflared` as a child process and tears it down when you close the tunnel or quit.

### A. One-time Cloudflare setup (web + CLI)

1. **Have a domain on Cloudflare.** In the Cloudflare dashboard, add your site and point your
   registrar's nameservers at the ones Cloudflare gives you. Wait until the zone shows **Active**.
2. **Install cloudflared:** `brew install cloudflared`.
3. **Log in** (opens the Cloudflare web UI to authorize a zone, writes `~/.cloudflared/cert.pem`):

   ```bash
   cloudflared tunnel login
   ```

4. **Create a named tunnel** (writes a credentials file `~/.cloudflared/<UUID>.json`):

   ```bash
   cloudflared tunnel create fmail
   ```

5. **Route a hostname to the tunnel** (creates a `CNAME` to `<UUID>.cfargotunnel.com` — you'll see it
   appear under **DNS** in the Cloudflare dashboard):

   ```bash
   cloudflared tunnel route dns fmail fmail.your-domain.com
   ```

### B. Configure FMail

6. **Settings → Connection → Auth token → Generate** (required — the tunnel refuses to open without it).
7. **Settings → Connection → Tunnel:**
   - **Tunnel name** = `fmail` (the name from step 4)
   - **Public URL** = `https://fmail.your-domain.com` (the hostname from step 5)
   - **cloudflared path** — only if `cloudflared` isn't on the default `PATH`.

### C. Open the tunnel

8. In the menu: **MCP/Tunnel → Open tunnel**. This also switches MCP on if it wasn't, waits for it,
   then starts `cloudflared`. When it's live the parent item shows a checkmark and reads
   **"MCP/Tunnel — Tunnel live"**. Switching MCP off, or clicking Open tunnel again, tears it down.
   FMail writes a temporary ingress config mapping `fmail.your-domain.com → http://127.0.0.1:<port>`
   and runs `cloudflared tunnel run fmail`.

> The tunnel never starts on its own — only when you click. Opening a public ingress to your mail is
> an active security decision, surfaced by the menu's checkmark + title.

### D. Pair a claude.ai connector (OAuth)

claude.ai's "Custom Connector" flow uses OAuth, not a static token:

9. **MCP/Tunnel → Open approval window** (opens a 5-minute window).
10. In claude.ai → add a custom connector → URL `https://fmail.your-domain.com/mcp`.
11. claude.ai opens FMail's `/authorize` page in your browser — click **Approve** while the window is
    open. The issued session token is persisted, so the connector survives FMail restarts. To revoke a
    paired connector later, use **Settings → Connection → Paired sessions → Revoke all paired sessions**.

### Who can connect over the tunnel

Only clients holding a valid token can connect — **not just any application that finds the URL.**
Every request over the tunnel must present a bearer token; requests without one are rejected with
HTTP 401, and if a tunnel is configured with no token *and* no session the server **fails closed** and
refuses everything. There are exactly two kinds of valid token:

- your **static token** — a secret that lives only in your own client config (e.g. local Claude
  Code). It is never handed to claude.ai or anyone else.
- an **OAuth session token** — issued *only* to a client that completed the approval flow.

A new or unknown application **cannot authorize itself** by reaching the public URL. To obtain a
session token it must, all at once: (1) arrive while you have **deliberately opened the approval
window** (time-limited; grants exactly one code, then closes), (2) be **approved by you** clicking
Approve in your browser while seeing its `redirect_uri`, and (3) prove possession of the **PKCE
verifier** it generated — so an intercepted code or a drive-by approval can't yield a usable token.
In short: a third-party app can't get in on its own; it needs either your static token or an approval
you actively grant during the window.

Caveat — these are **bearer** tokens: whoever holds a valid one can use it until it expires (OAuth
sessions last 30 days) or you revoke it. To cut off OAuth-paired clients immediately, use
**Settings → Connection → Paired sessions → Revoke all paired sessions** — revocation is instant, and the next
request from a revoked client gets a 401 and must re-authorize. To rotate the static token, generate a
new one in **Settings → Connection → Auth token** (update your client configs to match). Treat the static token like
a password, and keep the tunnel closed when you're not using it.

### Threat model (worth being honest about)

- **Loopback only, no token:** anything on your Mac that can reach `127.0.0.1:8765` can read your
  mail — same surface as anything else running as your user.
- **Loopback + token:** as above, but only clients with the token. Still local.
- **Tunnel + token / OAuth session:** your index is reachable from the public internet; the token /
  session is the only gate. Close the tunnel when you're not using it — the menu makes its state
  obvious.

## Design docs

- [`FMailSpec.md`](FMailSpec.md) — original design intent (window-UI era): pain points, architecture, phased plan.
- [`IMPLEMENTATION.md`](IMPLEMENTATION.md) — what shipped, deviations, file inventory.
- [`MCP_PLAN.md`](MCP_PLAN.md) — MCP server design (loopback HTTP/JSON-RPC for LLM clients).

These three describe the full window-UI build; see each file's header note for what changed in the
menu-bar build.

## License

Copyright (C) 2026 Felix Matschke

FMail is free software: you can redistribute it and/or modify it under the terms of the GNU General
Public License as published by the Free Software Foundation, either version 3 of the License, or (at
your option) any later version. See [`LICENSE`](LICENSE) for the full text.

> Note: GPL-3.0 is incompatible with Apple's App Store distribution. Direct download / sideload only.
