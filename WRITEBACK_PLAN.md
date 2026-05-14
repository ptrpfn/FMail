# FMail writeback — server-direct plan

Status: **planned, not started.** Replaces the AppleScript-only write path for mark-read / move-to-junk / delete with a server-direct backend (Gmail REST API for Gmail accounts; IMAP for the rest). AppleScript stays as a fallback for accounts without credentials.

## Why this exists

Tahoe broke Mail.app's AppleScript handler for mailbox-resolution properties — confirmed via [Tahoe AppleScript Timeouts (Michael Tsai, Sept 2025)](https://mjtsai.com/blog/2025/09/17/tahoe-applescript-timeouts/). Observed symptoms in FMail:

- `junk mailbox of <account>` errors for **every account** in `diagnose_junk_mailboxes` output (verified May 2026 on this user's setup).
- `move msg to <Spam mailbox>` over Gmail IMAP intermittently hangs Mail.app's AppleEvent queue for minutes; subsequent osascript invocations queue behind it and also hang.
- Even read-only diagnostics (`diagnose_junk_mailboxes`) time out when Mail.app's queue is wedged.
- Restarting Mail.app and re-running doesn't recover reliably.

This isn't fixable at the AppleScript layer — Automator, Shortcuts, and JXA all hit the same AppleEvent queue. MailKit extensions are the wrong shape (UI extensions, no move-message API). The only reliable path is to bypass Mail.app and talk to mail servers directly.

Reads stay unchanged — Mail.app keeps syncing, FMail keeps mirroring its on-disk store. Only writes change: they go to the server first, and the next Mail.app sync round-trip reconciles its local state.

## Goal

Replace `MailScripter`'s move/delete path with a routing layer that picks per account:

- **Gmail account → Gmail REST API.** Sub-second moves. Stable message IDs. No rowid reassignment surprises. Modern OAuth.
- **iCloud account → IMAP** using an app-specific password (iCloud doesn't support OAuth for IMAP).
- **Other IMAP accounts** (digitalhandstand, brakeless.net, etc.) → IMAP using a username/password (or OAuth where supported).
- **No credentials configured for an account → AppleScript fallback.** Same code path as today, accepted to be flaky on Tahoe, surfaced to the user as "configure server credentials for reliable writes."

`mark_read` is a separate question — AppleScript's `set read status of msg to true` is local and fast, generally still works on Tahoe. Phase B0 keeps it as-is and only changes move/delete. Phase B3 may unify if there's a reason.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  Caller (ReadStatusController, MCP handler)                         │
│  picks an operation: mark-read / move-to-junk / delete              │
└────────────────────────┬────────────────────────────────────────────┘
                         │
┌────────────────────────┴────────────────────────────────────────────┐
│  WritebackRouter                                                    │
│  for each message: lookup account; pick service by config           │
└────┬────────────────────┬──────────────────────┬───────────────────┘
     │                    │                      │
┌────┴─────────┐  ┌───────┴────────┐  ┌──────────┴──────────┐
│ GmailAPI     │  │ IMAP           │  │ AppleScript         │
│ service      │  │ service        │  │ service (existing)  │
│ HTTPS+OAuth2 │  │ TLS+LOGIN+UID  │  │ via MailScripter    │
└──────────────┘  └────────────────┘  └─────────────────────┘
     │                    │                      │
     │                    │                      ▼
     │                    │              Mail.app (AppleScript)
     ▼                    ▼                      │
   Gmail servers      iCloud / IMAP server       │
        \                  /                     │
         \                /                      │
          ▼              ▼                       ▼
                  After write:
                  - update FMail index optimistically
                  - schedule index reconciliation
                  - (Mail.app catches up on its own next sync)
```

### Types

```swift
/// What every writeback service implements. Inputs are server-identifiable;
/// the router resolves apple_rowid → server identity before calling.
protocol WritebackService: Sendable {
    func setReadStatus(_ messages: [MessageRef], isRead: Bool) async throws -> WritebackResult
    func moveToJunk(_ messages: [MessageRef]) async throws -> WritebackResult
    func delete(_ messages: [MessageRef]) async throws -> WritebackResult
}

/// Server-identifiable message reference. The IMAP UID is per-mailbox-folder;
/// the Gmail msg ID is global per account. The RFC Message-ID is a last-
/// resort fallback for IMAP servers without UIDPLUS.
struct MessageRef: Sendable {
    let accountID: String         // FMail's account UUID
    let gmailMessageId: String?   // for Gmail API
    let imapUID: Int?             // for IMAP (per source folder)
    let imapFolderPath: [String]? // source folder, IMAP-style
    let rfcMessageId: String?     // fallback for both
    let appleRowId: Int           // for AppleScript fallback + index updates
}

struct WritebackResult: Sendable {
    let applied: Int
    let perMessage: [Int: WritebackOutcome]  // apple_rowid → outcome
}

enum WritebackOutcome: Sendable {
    case ok
    case notFound
    case failed(String)
}
```

### Per-account configuration

A new SQLite table (or `index_metadata` entries — TBD) records which service to use per account:

```
account_writeback (
    account_uuid TEXT PRIMARY KEY,
    service TEXT NOT NULL,        -- 'gmail_api', 'imap', 'applescript'
    keychain_label TEXT,          -- pointer to Keychain entry holding creds
    settings_json TEXT NOT NULL DEFAULT '{}'
)
```

The router queries this per write. Default is `'applescript'` so existing behaviour is preserved until the user explicitly configures something else.

### Credentials & Keychain

All secrets in macOS Keychain under a per-service label:
- Gmail: `com.felixmatschke.FMail.gmail.<email>` storing refresh token + (cached) access token + expiry.
- IMAP: `com.felixmatschke.FMail.imap.<email>` storing app-specific password / OAuth refresh token.

FMail never logs or persists secrets outside Keychain. No iCloud-Drive sync of credentials.

### OAuth flow (Gmail only)

Standard Google OAuth 2.0 for native apps **with PKCE** (RFC 8252). PKCE matters because the FMail repo is public on GitHub — PKCE protects against authorization-code interception without requiring a client secret in the binary, so we don't have to worry about secret leakage.

1. User clicks "Authorize Gmail account" in Settings.
2. FMail generates a random `code_verifier` (43-128 chars) and its SHA-256 hash `code_challenge`.
3. FMail opens the default browser to `https://accounts.google.com/o/oauth2/v2/auth` with scope `https://www.googleapis.com/auth/gmail.modify`, redirect to `http://127.0.0.1:<random_port>/auth-callback`, and `code_challenge=<value>&code_challenge_method=S256`.
4. FMail temporarily binds a loopback `NWListener` on that port to catch the redirect.
5. User consents → browser hits the callback with `?code=…`.
6. FMail exchanges code + `code_verifier` for refresh + access tokens via `https://oauth2.googleapis.com/token`.
7. Tokens land in Keychain.
8. Subsequent API calls use the cached access token; refresh on 401 via the refresh token.

**Credential handling for the public repo:**
- **Client ID is committed to source.** It's a public identifier — same security posture as a User-Agent string. Google sends it in every browser address bar during auth anyway.
- **Client secret is NOT committed.** Loaded from a gitignored `FMail/Compose/OAuth.local.swift` (or compile-time Xcode build setting). README has a "Setting up Gmail OAuth for your own build" walkthrough for anyone forking. With PKCE it's not load-bearing for security — this is hygiene, not necessity.
- **Forks register their own Google Cloud OAuth client.** Same pattern Thunderbird, Mimestream, MailMate, etc. use. Console: console.cloud.google.com → "Desktop app" client type. Free, ~5 minutes one-time setup.

**Scope decision:** `gmail.modify` (read + label changes + trash + delete; does NOT include send). Could narrow to `gmail.labels` but the modify scope is bundled with what we need. `gmail.metadata` / `gmail.readonly` are too narrow (can't change labels). `mail.google.com` is too broad (includes IMAP/SMTP send). `gmail.modify` is the right middle ground.

### Gmail API endpoints used

| Operation | Endpoint | Body |
|---|---|---|
| Mark read | `POST users/me/messages/{id}/modify` | `removeLabelIds: ["UNREAD"]` |
| Mark unread | `POST users/me/messages/{id}/modify` | `addLabelIds: ["UNREAD"]` |
| Move to spam | `POST users/me/messages/{id}/modify` | `addLabelIds: ["SPAM"]`, `removeLabelIds: ["INBOX"]` |
| Move to trash | `POST users/me/messages/{id}/trash` | (empty) |
| Permanent delete | `POST users/me/messages/{id}` (DELETE) | (only if user opts in; trash is the default) |
| Batch | `POST batch/gmail/v1` | multipart with sub-requests |

Use batch endpoint for >5 messages. Cap at 50 per batch (Google's hard limit is 100).

### IMAP

For iCloud + other accounts. Plain RFC 3501 IMAP over TLS (port 993). Operations:

1. CAPABILITY — detect MOVE, UIDPLUS, IDLE, LOGIN, AUTH=PLAIN, AUTH=XOAUTH2.
2. LOGIN (or AUTHENTICATE) with credentials from Keychain.
3. SELECT source folder (e.g. `[Gmail]/All Mail` or `INBOX`).
4. `UID STORE <uid> +FLAGS (\Seen)` — mark read.
5. `UID MOVE <uid> <destination>` if MOVE supported, else `UID COPY` + `UID STORE +FLAGS (\Deleted)` + `UID EXPUNGE`.
6. LOGOUT.

iCloud quirks:
- Spam folder name is `Junk`.
- Trash folder name is `Deleted Messages`.
- App-specific passwords required (iCloud doesn't allow regular Apple ID password for IMAP since 2021).
- Server: `imap.mail.me.com`.

Decision: **hand-roll** the minimal IMAP client we need (~500-700 LOC). Avoids dependency. Use `NWConnection` for TLS. Re-use FMail's existing `Network.framework` familiarity from the MCP server. Cap to operations we need; don't try to be a general IMAP library. Defer message-fetch via IMAP — Mail.app still does that.

Alternative considered: SwiftNIO IMAP (Apple's library) — too low-level + adds NIO dep. MailCore2 — Objective-C, mature, but bigger surface than we need.

### Post-write index reconciliation

After a successful server-direct write, FMail's index is stale until Mail.app polls the server (1-15 min) and re-syncs. To close that gap:

1. **Optimistic FMail-index update**: directly mutate `messages.mailbox_rowid` (or related) to reflect the write. This is similar to today's optimistic UI flip but persisted to DB. Symmetric to `IndexDB.setIsReadBatch`.
   - For move-to-junk: change the target's mailbox_rowid to the local Junk/Spam mailbox row.
   - For delete: change mailbox_rowid to Trash, OR mark as deleted via a new column.
   - For mark-read: existing `setIsReadBatch` already handles this.
2. **Mail.app reconciliation**: schedule a Mail.app refresh via AppleScript `check for new mail for account X` (one of the few AppleScript verbs that's reliable on Tahoe — it just kicks the sync). This pulls the new state into Mail.app's local store within seconds.
3. **FMail re-sync**: existing `runIncrementalSync` picks up Mail.app's local-store changes on the next FSEvents fire.

Net effect: FMail's UI + MCP queries see the new state immediately (step 1). Mail.app's local store catches up within ~10s (step 2). FMail's index re-syncs from Mail.app's local store (step 3) and the optimistic state is confirmed.

**Edge case**: if the server write fails AFTER the optimistic FMail update, the index is wrong. Either re-sync on failure to revert, or surface to user. Treat as Phase B3 polish.

### MCP impact

The MCP tools' shapes stay the same. Internally they route through `WritebackRouter`. Tool descriptions are updated to drop the Gmail rowid-reassignment warning (server-direct writes don't trigger Mail.app's rowid reassignment).

**Setup is user-driven, not LLM-driven.** No new MCP tool for OAuth — the LLM shouldn't be authorizing accounts on the user's behalf. The user clicks through OAuth in Settings.

### UI impact

New "Server access" pane in Settings:

| Account | Status | Action |
|---|---|---|
| felix.matschke@gmail.com | Not authorized | [Authorize…] |
| brakelessproduction@gmail.com | Authorized 5 days ago | [Re-authorize] [Revoke] |
| iCloud (felix@me.com) | App-specific password set | [Update password] [Remove] |
| support@digitalhandstand.com | Not configured | [Set up IMAP…] |
| BT (felix.matschke@btinternet.com) | Not configured | [Set up IMAP…] |

For each row, a status indicator: green check (working), yellow warning (token expired, needs re-auth), red x (last call failed).

Tools menu adds: "Test writeback for selected account…" → runs a no-op (e.g., set/unset a label on a designated test message) and reports latency. Surfaces auth issues before the user discovers them via a real Junk move.

## Phasing

### Phase B0 — preflight (1 evening)
- Add `account_writeback` table (Schema vN).
- Add `WritebackService` protocol + the three implementations as empty stubs.
- Wire `WritebackRouter` into `ReadStatusController.deleteMessages(rowids:)` / `moveToJunk(rowids:)`. With no accounts configured, every call routes to AppleScript → behaviour unchanged.
- Tests: router picks the right service per account config; default is AppleScript.

### Phase B1 — Gmail API (1 weekend)
- Keychain helpers (read/write/delete entries).
- OAuth 2.0 loopback flow (`NWListener` on random port + browser handoff + token exchange).
- Refresh-token persistence + automatic refresh on 401.
- `GmailAPIWritebackService` — 3 operations via `users.messages.modify` / `trash`.
- Settings UI: per-Gmail-account "Authorize" button.
- Post-write index update for the affected rowids (mailbox change for move; flag set for read).
- Schedule Mail.app `check for new mail` AppleScript after each server write.
- Tests: OAuth callback handler; token refresh; service mock that asserts the right endpoint + body.

**Done when:** authorizing the user's primary Gmail account makes `move_to_junk` reliable (no timeouts, no rowid surprises) on Temu emails. Verified via `search_emails {query: "from:temu in:Spam"}`.

### Phase B2 — IMAP (1 weekend)
- Minimal IMAP client (TLS, LOGIN, SELECT, UID STORE, UID MOVE / COPY+EXPUNGE, LOGOUT). One source file, ~500-700 LOC.
- App-specific-password storage in Keychain for iCloud.
- `IMAPWritebackService` mapping our three operations to STORE / MOVE.
- Settings UI: per-IMAP-account "Set up" → username + password fields, "Test connection" button.
- iCloud preset (server = `imap.mail.me.com`, junk = `Junk`, trash = `Deleted Messages`).
- Tests: parser unit tests for IMAP responses; service mock; live integration test against iCloud (gated on app-specific password).

**Done when:** iCloud writeback works without going through AppleScript.

### Phase B3 — polish (1 evening)
- Reconciliation on server-write failure (revert optimistic DB change; surface to user via `bulkActionError`).
- `mark_read` routed through the same path (vs. keeping AppleScript) — measured decision after B1+B2 land.
- "Test writeback" Tools menu item.
- Status indicators in Settings (green / yellow / red per account).
- Docs: update MCP tool descriptions to drop the rowid-reassignment warning (server-direct doesn't reassign).
- IMPLEMENTATION.md entry.

## Out of scope (deferred)

- **General IMAP polish**: IDLE notifications, server-side search, server-side threading. We just need writebacks.
- **Compose / send via Gmail API or IMAP**: still goes through Mail.app via `mailto:`. The compose UX in Mail.app is good; we don't need to reinvent SMTP.
- **Multi-device credential sync**: every device authorizes separately. No iCloud-Drive sync of secrets.
- **Provider-specific operations** beyond move/junk/delete (snooze, archive, label management). One-off requests can use the existing AppleScript path.
- **Token leak audit**: assume Keychain is sufficient. Don't build separate audit/rotation tooling.
- **Background refresh of expired tokens before they fail**: handle reactively on 401.

## Open decisions

1. **Default delete behaviour for Gmail.** `messages.trash` (reversible) vs `messages.delete` (permanent). Mail.app's UI Delete = trash. **Recommendation: trash.** Add a separate `permanently_delete_messages` tool later if useful.

2. **What to do when Gmail OAuth refresh token revoked.** Surface a clear error in `bulkActionError`, mark the account as needing re-auth in Settings, fall back to AppleScript for that operation. **Recommendation: yes.**

3. **`mark_read` routing.** Keep AppleScript (B0 status quo), or route through server like move/delete (B3). AppleScript mark-read is fast and generally works on Tahoe. **Recommendation: defer to B3 measurement.**

4. **IMAP library: hand-roll vs adopt SwiftNIO IMAP.** Hand-roll keeps deps zero (matches FMail's existing posture). SwiftNIO IMAP is more correct but adds NIO + ImapKit modules. **Recommendation: hand-roll the minimal subset we need.**

5. **Settings UI placement.** Same window as MCP server settings (one Settings scene with multiple sections)? Or separate "Accounts" window? **Recommendation: same window, separate section.**

6. **Account email → service mapping.** Detect Gmail by domain (`*.gmail.com`, `googlemail.com`, plus Google Workspace's custom domains)? Or rely on user to pick the right service in Settings? **Recommendation: detect by domain, override in Settings.** Workspace domains can't be auto-detected; user picks `gmail_api` manually for those.

7. **Where does the Gmail OAuth client ID live?** **Resolved.** Commit the client ID to source (it's a public identifier, sent in every browser address bar during auth). Keep the client secret in a gitignored `OAuth.local.swift` for hygiene — PKCE makes the secret non-load-bearing for security per [RFC 8252](https://datatracker.ietf.org/doc/html/rfc8252). README documents how forkers register their own Google Cloud OAuth client (~5 min one-time setup, free).

8. **Behavior when user has FMail open on multiple Macs.** Each Mac authorizes independently with its own refresh token. Server-direct writes on Mac 1 propagate via the mail server to Mac 2's Mail.app. **No special handling needed.**

## Tests

- **Unit (no network):** OAuth callback URL parser; token refresh logic with mocked HTTP; `WritebackRouter` selection per account config; IMAP response parser; Gmail batch request construction.
- **Integration with mocked services:** `WritebackService` stubs return canned results; router-level tests exercise the per-message routing decisions.
- **Live (opt-in, gated):** end-to-end tests against a throwaway Gmail account and a throwaway iCloud account. Gated by env vars so CI doesn't run them by default.

## Cross-references

- See [MCP_PLAN.md](MCP_PLAN.md) for the MCP tool surface that this work backs.
- See [FMailSpec.md](FMailSpec.md) §12 v2 candidates — this is the concrete proposal for those candidates.
