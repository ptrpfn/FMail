# FMail

A small, opinionated macOS email **viewer** that fixes four specific Apple Mail pain points. Compose / send stay in Mail.app — FMail does not try to be a full mail client.

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

- **Search DSL** — `from:kyoko after:2024-03 (invoice OR receipt) -draft has:attachment "exact phrase"`. Date forms include ISO, relative (`7d`, `last week`), month names, and a `during:` operator that auto-widens to the granularity you typed (`during:2026` = all of 2026).
- **Per-contact preferred address** — never mis-send to a contact's secondary address again.
- **Threads via union-find** on `Message-ID` / `In-Reply-To` / `References`.
- **"All Mailboxes" view** across every account, with drafts / trash / junk filtered out.
- **Mail.app's threading still works** — replies set proper `In-Reply-To` and `References` headers via RFC 6068 mailto parameters.
- **"Open in Mail.app" button** for messages whose body Mail.app hasn't downloaded yet (uses the `message://` URL scheme).
- **Zero network connections.** No outbound traffic, no telemetry.
- **Apple's Gmail label model handled** — `[Gmail]/All Mail` is the canonical store, INBOX/Sent/Important are labels; FMail mirrors the labels table and shows them correctly.

## Status

Daily-driver capable. Phases 0–4 shipped — all four pain points closed. Phase 5 (polish) is ongoing. See [`IMPLEMENTATION.md`](IMPLEMENTATION.md) for per-phase status, file inventory, and the polish backlog.

## Requirements

- macOS 14 (Sonoma) or later.
- Apple Mail set up with your accounts (FMail reads its on-disk data; it doesn't talk to mail servers itself).
- **Full Disk Access** granted to FMail (so it can read `~/Library/Mail/`). The app prompts on first launch.

## Build

Requires Xcode 15+ and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project FMail.xcodeproj -scheme FMail -configuration Debug build
```

The `.xcodeproj` is generated from `project.yml` and not checked in.

## Design docs

- [`FMailSpec.md`](FMailSpec.md) — design intent: pain points, architecture, phased plan.
- [`IMPLEMENTATION.md`](IMPLEMENTATION.md) — what actually shipped, deviations from the spec, file inventory, Phase 5 backlog.

## License

Copyright (C) 2026 Felix Matschke

FMail is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. See [`LICENSE`](LICENSE) for the full text.

> Note: GPL-3.0 is incompatible with Apple's App Store distribution. Direct download / sideload only.
