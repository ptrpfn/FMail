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
| `from:` | sender (address or display name) | `from:kyoko` |
| `to:` | "To:" recipient | `to:me` |
| `cc:` | "Cc:" recipient | `cc:anna` |
| `subject:` *(or `subj:`)* | subject only | `subject:invoice` |
| `body:` *(or `content:`, `text:`)* | body content only | `body:meeting` |
| `attachment:` *(or `filename:`)* | attachment filename | `attachment:invoice.pdf` |
| `account:` | scope to one account (email, or UUID prefix) | `account:gmail.com` |
| `in:` | scope to mailbox kind: `inbox`, `sent`, `drafts`, `trash`, `junk`, `archive`, `all` | `in:sent` |
| `is:read` / `is:unread` / `is:flagged` *(or `is:starred`)* / `is:unflagged` *(or `is:unstarred`)* | flag scope | `is:unread` |
| `has:attachment` *(or `has:attachments`, `has:att`)* | attachment scope | `has:attachment` |
| `before:DATE` | strictly before start of period | `before:2026-03` |
| `after:DATE` *(or `since:DATE`)* | from a date onwards (see semantics below) | `after:2024` |
| `on:DATE` / `during:DATE` | the entire period (year / month / day) | `during:2025` |

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

`before:` is exclusive of the period; `after:` for partial dates is **after the period** (Gmail-style); `during:` / `on:` matches the whole period at the precision you typed:

| Query | Means |
|---|---|
| `before:2026` | `< 2026-01-01` |
| `before:2026-03` | `< 2026-03-01` |
| `after:2024` | `>= 2025-01-01` (after all of 2024) |
| `after:2024-03` | `>= 2024-04-01` (after March 2024) |
| `after:2024-03-15` | `>= 2024-03-15` (inclusive — full date) |
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

## Gmail OAuth setup (optional)

macOS Tahoe broke Mail.app's AppleScript bridge for several mailbox-resolution operations — Move to Junk and similar can silently no-op or hang. FMail can bypass this by talking to the Gmail REST API directly for accounts that authorize it; AppleScript stays as a fallback for accounts that don't. See [`WRITEBACK_PLAN.md`](WRITEBACK_PLAN.md) for the architecture.

The OAuth client is per-fork — Google's terms expect each redistribution to register its own. Five-minute one-time setup:

1. Go to [console.cloud.google.com](https://console.cloud.google.com/) → create or pick a project.
2. **APIs & Services → Library** → enable **Gmail API**.
3. **APIs & Services → OAuth consent screen** → User Type: External. Add yourself as a Test User. Scopes: `https://www.googleapis.com/auth/gmail.modify`.
4. **APIs & Services → Credentials** → Create Credentials → OAuth Client ID → Application type: **Desktop app**. Copy the **Client ID** (looks like `REDACTED_GOOGLE_OAUTH_CLIENT_ID`).
5. Paste the Client ID into `FMail/Writeback/Gmail/GmailOAuthConfig.swift`:
   ```swift
   static let clientID = "YOUR-CLIENT-ID.apps.googleusercontent.com"
   ```
6. Rebuild. Settings → "Gmail accounts" now lists each detected Gmail address with an "Authorize…" button.

PKCE (RFC 7636) handles auth-code interception, so committing the Client ID to a public fork is fine — that's the modern best practice for installed apps. There is no client secret to keep out of the binary. Each fork's OAuth project is independently rate-limited, so misuse of your fork's Client ID is your problem, not upstream's.

If you skip this step, FMail still works — Gmail accounts just fall back to AppleScript for writebacks (with the Tahoe-flakiness caveats above).

## Design docs

- [`FMailSpec.md`](FMailSpec.md) — design intent: pain points, architecture, phased plan.
- [`IMPLEMENTATION.md`](IMPLEMENTATION.md) — what actually shipped, deviations from the spec, file inventory, Phase 5 backlog.
- [`MCP_PLAN.md`](MCP_PLAN.md) — MCP server design (loopback HTTP/JSON-RPC for LLM clients).
- [`WRITEBACK_PLAN.md`](WRITEBACK_PLAN.md) — server-direct write path (Gmail API + IMAP) replacing the AppleScript move/delete bottleneck.

## License

Copyright (C) 2026 Felix Matschke

FMail is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. See [`LICENSE`](LICENSE) for the full text.

> Note: GPL-3.0 is incompatible with Apple's App Store distribution. Direct download / sideload only.
