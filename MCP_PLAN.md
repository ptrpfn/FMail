# FMail MCP server — implementation plan

Status: **plan validated against the codebase; ready to implement.** Pick this up by working through the phases below. Validation pass added the "Reality corrections" section (after Locked decisions) — read it before touching code.

> **⚠️ Current behaviour differs from this plan in a few places (menu-bar build).** The MCP server is
> now **on by default** (an explicit toggle-off persists), and lives behind the menu's **MCP/Tunnel**
> submenu rather than a Settings pane — MCP toggle, Open tunnel, and Open approval window are all menu
> items; Settings only holds the set-once values (auth token, port, tunnel name/URL, cloudflared path).
> The MCP surface is **eight read-only tools** — the write tools described below (`mark_read`,
> `delete_messages`, `move_to_junk`, `diagnose_junk_mailboxes`) were **removed**; Mail state changes
> go through Mail.app. OAuth discovery metadata is **host-aware**: a loopback request advertises
> `http://127.0.0.1:<port>` as the resource/issuer (so a local client's RFC 8707 resource check
> matches), while tunnel requests use the configured public URL — the bearer check is independent of
> the advertised issuer. Local Claude Code authenticates with the **static token in an `Authorization`
> header** (no OAuth). See [README.md](README.md) for the current setup steps. The protocol/transport/
> tool design below is otherwise accurate.

Goal: when FMail.app is running, expose an MCP server on `127.0.0.1:8765` so Claude Code (or any MCP-compatible LLM client) can query the FMail index and mark messages read. The point is to leverage the existing index/threading/DSL so the LLM can triage email without loading everything into context. Standalone daemon (LaunchAgent) is **not** in scope for v1; we accept the lifecycle constraint that FMail must be open. See `FMailSpec.md` §10/§12 for the wider context.

## Use cases this is meant to enable

These are the LLM-side flows we want to make easy. The MCP server only exposes data + a single write — the LLM does the reasoning.

- **Triage:** "what's actually important in my last 7 days of unread?"
- **Find:** "the email Anna sent about the school trip last March."
- **Open-loop detection:** "what threads have I sent into and not heard back on?"
- **Wrong-address audit:** "any threads where I might've replied to Kyoko's AppStore alias?"
- **Thread summary:** "give me the gist of this 40-message chain."
- **Periodic digest:** weekly "here's what you missed / need to act on."
- **Mark-read-without-reading:** LLM proposes "these 12 are newsletters, mark read" → user OKs → `mark_read` call.

Move-to-trash and move-to-spam **shipped** as a follow-up after the core 6 tools — see the "delete_messages / move_to_junk" section below. Archive is still deferred.

---

## Locked decisions

| Question | Decision |
|---|---|
| Transport | **HTTP on `127.0.0.1:8765`** (Streamable HTTP / SSE). Stdio doesn't fit — it inverts the lifecycle. |
| Network stack | **Apple `Network.framework`** (`NWListener` over TCP). No external HTTP-server dep. |
| MCP framework | **Hand-roll JSON-RPC 2.0** + the MCP handshake. ~300 LOC total. No SDK dependency. |
| Concurrency | `MCPServer` is its own `actor`. Per-request `Task` awaits existing actors (`IndexDB`, `BodyLoader`, `ReadStatusController`). No new locking primitives. |
| Auth | **None.** Bind to `127.0.0.1` only. Local-trust. Optional bearer token deferred. |
| MCP output schema | **Separate DTO types** in `FMail/MCP/MCPModels.swift`. Don't expose `MessageHeader` / `ThreadSummary` directly so the MCP contract stays stable across internal refactors. |
| Discovery / setup | Settings sheet with **"Copy Claude Code config"** button. User pastes the snippet into `~/.claude/settings.json`. |
| Default state | **Off by default.** MCP server reads every email — explicit opt-in only. Loud privacy banner in settings. |
| Default port | `8765`. Configurable. |
| Sync on connect | **No.** Don't trigger incremental sync when an MCP client connects. The FSEvents-driven index is good enough; LLM may occasionally see stale state. Document this. |
| Body-index freshness | **Accepted limitation.** `search_emails` matches FTS body content as it gets indexed; if a recent message hasn't been body-indexed yet, the LLM won't find it via body text. Document; don't paper over. |
| Search interface | **Single DSL string** (`search_emails(query: String, …)`). The LLM learns the grammar from the tool description (paste `FMailSpec.md` §6.2 in). No `search_emails_simple(from:, to:, …)` second tool in v1. |
| Write surface | **Only `mark_read`** in v1. Routes through existing `ReadStatusController` pipeline. |
| Long `mark_read` runs | **Document the bound; no SSE in v1.** AppleScript dispatch is synchronous and can take 5–30 s for big batches across multiple Gmail accounts. Tool description tells the LLM to keep batches ≤ ~50. SSE/streaming progress would dodge client timeouts but adds a parser, a writer, and a per-tool decision — defer until usage demands it. |
| Move/delete reliability on Tahoe | **Server-direct writeback backend** — see [WRITEBACK_PLAN.md](WRITEBACK_PLAN.md). Tahoe broke Mail.app's AppleScript handler for mailbox-resolution; the fix is to route move/delete through Gmail API for Gmail accounts and IMAP for the rest. AppleScript stays as fallback for **mark_read and delete** (those still work via AppleScript). **For move_to_junk, AppleScript is removed entirely** — too broken on Tahoe to be a useful fallback; calls hard-fail with a clear "authorize Gmail or configure IMAP" message instead of timing out forever. |
| Snippets in `search_emails` | **Omit in v1.** The LLM can call `get_email` for body context. FTS5 `snippet()` is an optional A4 polish. |

---

## Reality corrections from validation

Validation pass against the actual code surfaced six deltas the original draft of this document got wrong. They become preflight work folded into Phase A2:

1. **`MessageHeader` is leaner than the DTOs need.** `IndexDB.search()` (`IndexDB.swift:506`) returns `[MessageHeader]` with `rowId, mailboxRowId, subject, senderAddress, senderDisplay, dateSent, dateReceived, isRead, isFlagged, rfcMessageId, imapUID` — no `mailbox_path`, no `thread_id`, no `has_attachment`. The MCP `EmailRef` DTO needs these, so a side-fetch `enrichForMCP(rowids:) -> [Int: (mailboxPath, threadId, hasAttachment)]` is required.

2. **`is_outgoing` is NOT a stored column.** The original plan claimed it was populated by the indexer. Reality: it's computed at query-time via `outgoingFlagExpr` (`IndexDB.swift:970`) — `LOWER(m.sender_address) IN (SELECT LOWER(email_address) FROM accounts WHERE email_address IS NOT NULL)`. `find_unanswered_threads` SQL must use the same expression.

3. **`loadMessage(rowid:)` does not exist.** Both `get_email` and `mark_read` need it. Add as a single-row SELECT mirroring the column list of `search()`.

4. **`BodyLoader.loadBody(messageRowId:mailbox:)` requires a `Mailbox`, not just a rowid.** So `get_email` and `get_thread` body fetches need `IndexDB.loadMailbox(rowid:)` first. (Alternative: hop to `@MainActor` and use `model.mailboxes` — uglier.)

5. **`recipients` table lacks a read helper.** Schema is `(message_rowid, kind, position, address, display)` with `kind 0=to, 1=cc, 2=bcc, 3=from`. `get_email`'s `to`/`cc` fields need `loadRecipients(messageRowId:)`.

6. **`ReadStatusController.setReadStatus(messages:isRead:)` is fire-and-forget** (`ReadStatusController.swift:23`). The MCP `mark_read` handler needs to await the AppleScript dispatch result so it can return `{applied, errors}`. Add a `setReadStatus(rowids: [Int], isRead: Bool) async -> (applied: Int, error: String?)` variant that resolves rowids → `MessageHeader` via `IndexDB.loadMessage` and runs the same pipeline but awaits the `MailScripter.Result` instead of dispatching detached.

These are folded into the phasing below.

Other reality checks that came back **fine** as the plan described them: actor model on `IndexDB` and `BodyLoader`; `MailModel.boot()` plug-in point at line 154 right after `syncCoordinator` is created; `xcodegen` auto-discovers any `.swift` under `FMail/`; no existing Settings scene in `FMailApp.swift`; footer location in `AppShell.swift`; `MailScripter.setReadStatusBatch` returns a structured `Result`. None of those need changes.

---

## Tool surface (8 tools)

The original 6 plus `delete_messages` and `move_to_junk`, added after Phase A4 to mirror the Mark Read / Mark Unread bulk-action UI in the LLM surface. Both routes through the same `ReadStatusController` pipeline: optimistic UI removal + AppleScript dispatch + sync-skip window. Same time-bound caveat as `mark_read` — keep batches ≤ ~50.



Single source of truth: `FMail/MCP/MCPTools.swift`. JSON shapes below are illustrative — finalize when implementing.

### `search_emails`

```jsonc
// Input
{
  "query": "from:anna after:2024-01 school",   // FMail DSL — see FMailSpec.md §6.2
  "limit": 50,                                  // 1–500, default 50
  "since": "2025-01-01",                        // optional ISO date, ANDed with query
  "until": "2025-12-31"                         // optional ISO date, ANDed with query
}
// Output
{
  "results": [
    {
      "rowid": 12345,
      "subject": "School trip update",
      "sender_display": "Anna",
      "sender_address": "anna@example.com",
      "date_received": "2025-03-14T10:23:00Z",
      "mailbox_path": "INBOX",
      "snippet": "first ~200 chars of body text…",
      "is_read": false,
      "is_flagged": false,
      "has_attachment": true,
      "thread_id": 9876
    }
  ]
}
```

Reuses: `QueryParser` + `Evaluator` + `IndexDB.search`. Tool description in the schema **must include the DSL grammar** so the LLM uses it correctly.

### `list_threads`

```jsonc
// Input
{
  "scope": "all_mailboxes" | { "mailbox_rowid": 7 },
  "since": "2025-04-01",       // optional
  "until": "2025-05-09",       // optional
  "unread_only": false,        // optional, default false
  "limit": 100                 // 1–600, default 100
}
// Output
{
  "threads": [
    {
      "thread_id": 9876,
      "latest_subject": "School trip update",
      "latest_sender_display": "Anna",
      "latest_date_received": "2025-03-14T10:23:00Z",
      "message_count": 4,
      "unread_count": 1,
      "flagged_count": 0,
      "mailbox_path": "INBOX"
    }
  ]
}
```

Reuses: `loadAllThreadSummaries` / `loadThreadSummaries`. May need a thin overload that accepts `since` / `until` / `unread_only` filters; current API is `(mailboxRowId, limit)` only — add filtering on top, or do a Swift-side filter on the result for v1 (acceptable at limit ≤ 600).

### `get_thread`

```jsonc
// Input
{
  "thread_id": 9876,
  "include_bodies": true,        // default true
  "max_body_chars": 8000         // default 8000 per message; truncates with "[…truncated]"
}
// Output
{
  "messages": [ /* array of EmailFull */ ]
}
```

Reuses: `loadThreadMessages` (with `MailboxKind.viewScope(forSelectedKind: nil, allMailboxesScope: false)` → `.excludeDrafts` as default), then `BodyLoader.loadBody` per message.

### `get_email`

```jsonc
// Input
{ "rowid": 12345, "max_body_chars": 8000 }
// Output (EmailFull)
{
  "rowid": 12345,
  "thread_id": 9876,
  "mailbox_path": "INBOX",
  "subject": "…",
  "sender_display": "Anna",
  "sender_address": "anna@example.com",
  "to": ["me@me.com"],          // parsed from headers
  "cc": [],
  "date_sent": "…",
  "date_received": "…",
  "is_read": false,
  "is_flagged": false,
  "rfc_message_id": "<…>",
  "plain_text_body": "…",       // truncated per max_body_chars
  "html_body_present": true,    // boolean only; we don't ship HTML to the LLM
  "attachments": [
    { "name": "trip.pdf", "content_type": "application/pdf", "byte_count": 124000 }
  ]
}
```

### `find_unanswered_threads`

```jsonc
// Input
{
  "since": "2025-04-01",
  "our_address": "felix@me.com",   // optional; if absent, any account address
  "limit": 50
}
// Output
{
  "threads": [
    {
      "thread_id": 9876,
      "latest_outgoing": { /* EmailRef shape */ },
      "days_silent": 12,
      "recipient_addresses": ["someone@example.com"]
    }
  ]
}
```

**New SQL needed.** Sketch: for each thread that has at least one outgoing message from `our_address` (or any account address) after `since`, the latest message in the thread is outgoing AND its `date_received` is older than today. **`is_outgoing` is computed, not stored**: use the existing `outgoingFlagExpr` pattern (`LOWER(m.sender_address) IN (SELECT LOWER(email_address) FROM accounts WHERE email_address IS NOT NULL)`). When `our_address` is supplied, restrict to that one address; otherwise match any account email. Add as a method on `IndexDB`. Tests for this go in Phase A4 against an in-memory fixture DB.

### `mark_read`

```jsonc
// Input
{ "rowids": [12345, 12346, 12347], "is_read": true }
// Output
{ "applied": 3, "errors": [] }   // errors[] populated if any rowid fails AppleScript dispatch
```

Routes through `ReadStatusController` but needs a new awaitable variant. The existing `setReadStatus(messages:isRead:)` is fire-and-forget — it `Task { ... }`s and returns. For MCP we want to await the `MailScripter.Result` and report it back.

**Adopted approach (Option α):** Add `setReadStatus(rowids: [Int], isRead: Bool) async -> (applied: Int, error: String?)`:
1. Resolve rowids → `MessageHeader`s via `IndexDB.loadMessage` (skipping any that don't resolve).
2. Run the existing optimistic-flip pipeline on the resolved headers.
3. **Await** `MailScripter.setReadStatusBatch` instead of `Task.detached`.
4. Return `(applied: matchedCount, error: errorMessage)`. The existing `bulkActionError` plumbing still fires for UI consistency.

Tool description tells the LLM: keep batches ≤ ~50; bigger batches risk client timeouts because `osascript` linearly scans Mail.app's per-mailbox messages.

### `delete_messages` and `move_to_junk`

```jsonc
// Both share the same shape:
// Input
{ "rowids": [12345, 12346] }
// Output (MarkReadResult shape — `applied: matched count`, `error: optional string`)
{ "applied": 2, "error": null }
```

Routes through `ReadStatusController.deleteMessages(rowids:) async` / `moveToJunk(rowids:) async`, which use the same optimistic-removal + awaitable-AppleScript pipeline as `mark_read`. The optimistic flip removes rows from `messagesInSelectedThread` / `searchResults`, decrements thread `messageCount`/`unreadCount` (dropping threads that go to zero), decrements per-mailbox totals + the global badge. We do NOT update the DB — the next FSEvent-driven sync re-mirrors Apple's Envelope Index and reconciles naturally.

AppleScript actions:
- Delete: `delete msg` — Mail.app moves to the Trash mailbox of the relevant account, matching the Delete key in the UI. Single statement; works reliably across iCloud and Gmail.
- Junk: a **3-step block**, generated by `MailScripter.moveToJunkAction(accountVar:)`:
  1. `set junk mail status of msg to true` — always succeeds, fast, local; also helps train Gmail's spam filter.
  2. Resolve target mailbox: try `junk mailbox of <accountVar>` first; if `missing value`, fall back to walking `mailboxes of <accountVar>` for names matching `Spam` / `Junk` / `Spam mail` / `Bulk Mail` / `[Gmail]/Spam`.
  3. `set mailbox of msg to tgtMbox` — the actual move.

  The fallback exists because `junk mailbox of <account>` returns `missing value` for some Gmail setups (observed in practice — symptom is silent no-op). The action's `<accountVar>` differs between the account-scoped block (`theAccount`) and the cross-account fallback (`anAccount`); `MailScripter.runActionBatch` accepts two action strings to handle this. `MailScripter.makeLookupBlock` was updated to indent every line of a multi-line action, not just the first.

Same time-bound caveat as `mark_read`. **Move from `[Gmail]/All Mail` is a server-side IMAP MOVE — can take 10-60s** and may exceed an MCP client's HTTP timeout while still completing on Mail.app's side. The optimistic UI removal masks this in FMail; from the MCP perspective, a `move_to_junk` timeout is recoverable by re-checking via `search_emails` after ~30-60 seconds.

If junk persistently doesn't take effect, run **Tools → Diagnose Junk mailboxes…** in FMail — it reports what Mail.app exposes as `junk mailbox of <account>` for each configured account (and surfaces `missing value` cases), so we can tell whether the failure is "our script picked the wrong mailbox" vs "Mail.app reports no junk mailbox at all for this account".

Tests: `FMailTests/MailScripterTests.swift` covers the AppleScript text construction — pins the 4 invariants above (status set, junk-mailbox lookup, name-search fallback, set-mailbox), the correct account-variable per context, and that multi-line actions get indented properly inside `repeat with msg in matches`. These are pure string tests; they don't invoke Mail.app.

---

## Architecture

### MCP transport (hand-rolled)

MCP is JSON-RPC 2.0 over a transport. The Streamable HTTP transport is the v2024-11-05+ spec:

- Single endpoint: `POST /mcp`
- Each request is a JSON-RPC message; responses come back over the same connection (or via SSE for streaming).
- For our v1 we don't need streaming — handle each request synchronously and return the JSON-RPC response. (Add SSE later if we want progress notifications during long calls.)

Handshake to support:

1. `initialize` (client → server) — return server capabilities, protocol version, server info.
2. `initialized` notification (client → server) — no response.
3. `tools/list` — return the 6 tools with JSON-Schema input/output.
4. `tools/call` with `{name, arguments}` — dispatch to handler, return result.
5. (Optional) `ping` for keepalive.

JSON-RPC error codes: use standard codes (`-32600` invalid request, `-32601` method not found, `-32602` invalid params, `-32603` internal). Define an FMail-specific code for "index not ready" / "FDA missing" — `-32000`-and-down range is reserved for app-defined.

### Server lifecycle

```
MailModel
├── boot() …
│   └── if MCPSettings.enabled && loadState == .ready
│       └── self.mcpServer = MCPServer(port:); await mcpServer.start()
└── (settings change → restart server)
```

`MCPServer` is `@ObservationIgnored` on MailModel (analogous to `syncCoordinator` and `readStatus`). Stop on app termination via `applicationWillTerminate` — or rely on process exit (`NWListener` cleans up).

### Concurrency

```
NWListener (server port 8765)
  └── per-connection: NWConnection
        └── per-request: parse JSON-RPC → dispatch
              └── await IndexDB / BodyLoader / etc. (existing actors)
                    └── encode DTO → JSON-RPC response → write back
```

`MCPServer` itself is an actor. Its `dispatch(_ request:) async throws -> Response` is the entry point each connection's read-loop calls.

Multiple in-flight requests serialize on `IndexDB` (one connection, actor-isolated). Acceptable — each call is fast.

### Sendable

All DTOs in `MCPModels.swift` are `Sendable` value types. `MCPServer` is an actor → implicitly Sendable. Handler closures are `@Sendable`.

---

## File layout

```
FMail/MCP/
├── MCPServer.swift              actor; owns NWListener; accept loop; request → tool dispatch.
├── MCPTransport.swift           HTTP framing (request/response), JSON-RPC 2.0 envelope,
│                                 initialize/tools/list/tools/call dispatch table.
├── MCPTools.swift               Tool registry: name → (JSON-Schema, handler closure).
├── MCPModels.swift              Sendable Codable DTOs (EmailRef, EmailFull, ThreadRef,
│                                 UnansweredThread, AttachmentRef, …). The stable contract.
├── MCPHandlers.swift            One async func per tool. Reads from IndexDB / BodyLoader /
│                                 ReadStatusController; encodes DTOs.
└── MCPSettings.swift            @AppStorage-backed: enabled (Bool), port (Int).

FMail/UI/
├── MailModel.swift              + var mcpServer: MCPServer? (ObservationIgnored).
│                                 boot() starts it when settings.enabled.
├── AppShell.swift               + small footer pill: "MCP :8765" when running.
└── Settings/                    new directory
    └── SettingsView.swift       Tools menu → "Settings…" (or ⌘,):
                                  - MCP enabled toggle
                                  - Port field
                                  - Status (running / stopped / error)
                                  - "Copy Claude Code config" button
                                  - Privacy banner

FMailTests/
└── MCPTests.swift               DTO encode/decode round-trip; tool input validation
                                  (missing fields → invalid_params); findUnansweredThreads
                                  SQL against fixture data; integration test that binds on
                                  a random port and exercises the handshake + 1 of each tool.
```

---

## Phasing — ~4 evenings

### A1 — Skeleton + transport (1 evening)

1. `FMail/MCP/MCPSettings.swift` — singleton-ish wrapper around `UserDefaults.standard` for `mcp_enabled: Bool` (default false) and `mcp_port: Int` (default 8765). **NOT `@AppStorage`** — `MailModel` is `@Observable`, not a SwiftUI View; `@AppStorage` only works in views. The Settings *view* can use `@AppStorage` for two-way binding; the model side reads/writes raw UserDefaults and the view explicitly calls `model.applyMCPSettings()` on toggle change.
2. `FMail/MCP/MCPTransport.swift` — JSON-RPC 2.0 framing over HTTP/1.1. Read until `\r\n\r\n`, parse request line + `Content-Length`, read body, write `HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: N\r\nConnection: close\r\n\r\n<body>`. Single endpoint `POST /mcp`. ~150 LOC.
3. `FMail/MCP/MCPServer.swift` — actor wrapping `NWListener` bound to `NWEndpoint.Host("127.0.0.1")` only with `parameters.allowLocalEndpointReuse = true`. `start()` / `stop()`. Empty tool registry. Handles `initialize` / `notifications/initialized` (notification, no response) / `tools/list` (returns []) / `tools/call` (returns method-not-found). Surfaces `lastError: String?` for the eventual SettingsView.
4. Wire start/stop into `MailModel.boot()` after `syncCoordinator` is set (`MailModel.swift:154`). Add `@ObservationIgnored var mcpServer: MCPServer?`. Gate on `MCPSettings.shared.enabled && loadState == .ready`. Add a `func applyMCPSettings()` on MailModel that the SettingsView calls on toggle change.
5. **Done when:** with toggle on, `curl -X POST localhost:8765/mcp -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'` returns server info; Claude Code's MCP client connects and lists zero tools.

### A2 — IndexDB helpers + DTOs + 4 read tools (1 long evening)

6. **IndexDB additions** in a new `FMail/Core/Index/IndexDB+MCP.swift` extension to keep MCP plumbing isolated from the rest of the read API:
    - `loadMessage(rowid: Int) -> MessageHeader?` — single-row SELECT mirroring the column list in `search()` (`IndexDB.swift:506`).
    - `loadMailbox(rowid: Int) -> Mailbox?`.
    - `loadRecipients(messageRowId: Int) -> [(kind: Int, address: String, display: String?)]`.
    - `enrichForMCP(rowids: [Int]) -> [Int: (mailboxPath: String, threadId: Int, hasAttachment: Bool)]` — one SQL with `apple_rowid IN (...)` joining `mailboxes`. Honors the `effectiveThreadIdExpr` so unthreaded messages get a synthetic thread id.
7. `FMail/MCP/MCPModels.swift` — Sendable Codable DTOs: `EmailRef`, `EmailFull`, `ThreadRef`, `AttachmentRef`, `UnansweredThread`. ISO-8601 dates as strings.
8. `FMail/MCP/MCPHandlers.swift` (read half) — `search_emails`, `list_threads`, `get_thread`, `get_email`. Pattern per handler:
    - Validate input (throw `invalidParams` on bad shape).
    - Await `IndexDB.search` / `loadAllThreadSummaries` / `loadThreadMessages` / `BodyLoader.loadBody`.
    - For body fetch: `IndexDB.loadMailbox(rowid:)` → `BodyLoader.loadBody(messageRowId:mailbox:)`. Truncate plain text via `String.prefix(maxBodyChars)`.
    - Map internal types → DTOs. **Skip snippets in v1.**
9. `FMail/MCP/MCPTools.swift` — register 4 tools with JSON Schemas. **`search_emails` description includes the DSL grammar table from `FMailSpec.md` §6.2 verbatim** so the LLM can compose queries.
10. **Done when:** in Claude Code, `search_emails {query: "from:anna last 30 days school"}` returns sensible results; `get_thread {thread_id: …}` returns full bodies.

### A3 — `find_unanswered_threads` + `mark_read` + Settings UI (1 evening)

11. `IndexDB.findUnansweredThreads(since:ourAddress:limit:)` — pure SQL, no FTS. Uses the same `outgoingFlagExpr` pattern as `representativeSelectList`. Algorithm: for each thread containing at least one outgoing message after `:since`, find the latest message in the thread; emit if that message is outgoing AND no later incoming reply exists. Bind `our_address` (lowercased) when supplied; otherwise match against any account email.
12. `MCPHandlers.findUnansweredThreads` handler.
13. `ReadStatusController.setReadStatus(rowids: [Int], isRead: Bool) async -> (applied: Int, error: String?)` — resolves rowids via `IndexDB.loadMessage`, runs the existing `applyOptimisticThreadBulkRead` / `persistIsRead` path, then **awaits** `MailScripter.setReadStatusBatch` (no `Task.detached`). Maps the `Result` to `(applied, error)`. Existing `bulkActionError` still fires for UI consistency.
14. `MCPHandlers.markRead` handler.
15. `FMail/UI/Settings/SettingsView.swift` — toggle + port `TextField` + status (Running on :PORT / Stopped / Error: …) + privacy banner + "Copy Claude Code config" button:
    ```json
    {
      "mcpServers": {
        "fmail": {
          "type": "http",
          "url": "http://127.0.0.1:8765/mcp"
        }
      }
    }
    ```
    Toggle/port changes call `model.applyMCPSettings()` to start/stop the listener.
16. `FMailApp.swift` — add `Settings { SettingsView(model: model) }` scene (gives `⌘,` for free) and route the model in via `@FocusedValue` or accept a singleton hook. Tools menu can stay as-is.
17. **Done when:** flipping the toggle on/off cleanly starts/stops the listener; Claude Code can mark messages read and the change appears in FMail's UI immediately (optimistic flip via existing pipeline).

### A4 — Tests + footer status + docs (1 evening)

18. `FMailTests/MCPTests.swift`:
    - DTO encode/decode round-trip for each of the 5 DTO types.
    - JSON-RPC envelope edge cases (missing `id`, malformed JSON, unknown method).
    - `findUnansweredThreads` against an in-memory fixture (`IndexDB` opened on a temporary file path; in-memory `:memory:` doesn't survive actor hops but a tmp file works fine).
    - Integration test: bind on **port 0** (kernel picks free port), full handshake (`initialize` + `notifications/initialized` + `tools/list`) + one call per tool against the fixture DB.
19. `AppShell.swift` — small "MCP :8765" pill in `footerStatus` when `model.mcpServer?.isRunning == true`. Hidden otherwise.
20. Update `IMPLEMENTATION.md` — new Phase 5 entry describing the MCP server.
21. Add a one-paragraph blurb to `FMailSpec.md` (probably as a new §15 or as a note in §12 Phase 5).

---

## Implementation notes / gotchas

(Things that would be lost between sessions — read these before writing any code.)

### 1. JSON-RPC 2.0 + MCP handshake
- `initialize` request includes `protocolVersion`, `capabilities`, `clientInfo`. Server responds with the same shape from its side. We say `tools: { listChanged: false }` (we don't change tools at runtime).
- `initialized` is a **notification** (no `id`, no response).
- `tools/list` returns `{ tools: [{ name, description, inputSchema }] }` — `inputSchema` is JSON Schema.
- `tools/call` takes `{ name, arguments }` and returns `{ content: [{ type: "text", text: "<JSON-encoded result>" }], isError: false }`. The convention is to JSON-stringify the result and put it in a single text content block.

### 2. NWListener on Network.framework
- Bind to `NWEndpoint.Host("127.0.0.1")` explicitly — *not* `0.0.0.0` and *not* default. Default binds to all interfaces.
- Use `NWListener.State.failed` to surface bind errors (port in use → user-visible error in settings).
- `NWParameters.tcp` with `parameters.allowLocalEndpointReuse = true` for clean restart.

### 3. HTTP framing
- Read until `\r\n\r\n`, parse status line + headers, read `Content-Length` bytes for body. Don't bother with chunked encoding (clients won't send it for small JSON requests).
- Response: `HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: N\r\n\r\n<body>`.
- `Connection: close` is fine for v1 — one request per connection. Keep-alive can come later.

### 4. ReadStatusController integration
- `setReadStatus(messages:isRead:)` (`ReadStatusController.swift:23`) is fire-and-forget — wraps the work in `Task { @MainActor in ... }` and returns. The MCP `mark_read` handler can't reuse it directly: we need to await the AppleScript dispatch and get a result back.
- New `setReadStatus(rowids: [Int], isRead: Bool) async -> (applied: Int, error: String?)`: same optimistic-flip + DB persist + AppleScript dispatch as the existing pipeline, but **awaits** `MailScripter.setReadStatusBatch` directly (no `Task.detached`). The existing `bulkActionError` plumbing still fires for UI consistency.
- Document the bound to the LLM: keep batches ≤ ~50. Mail.app linearly scans per-mailbox messages by `whose id is N`; 100+ messages across multiple Gmail accounts can hit 30s+. The MCP transport is plain HTTP request/response — no SSE in v1 — so the call blocks until the AppleScript returns. If the LLM client times out, the work may still complete on Mail.app's side; the user can re-call to verify state.

### 5. DSL exposure
- Description goes in `tools/list` output. Paste the full DSL grammar from `FMailSpec.md` §6.2 into the `description` field of `search_emails`'s tool definition. The LLM reads it once and uses it.
- Don't auto-translate natural language → DSL on the server side. The LLM does that.

### 6. Body content for the LLM
- Always send `plain_text_body` (from `MessageBody.displayText` — already HTML-stripped). Never send `html` directly; LLMs don't need it and it bloats context.
- Set `html_body_present: true` if the message had an HTML part, so the LLM knows it's a marketing email vs. plain text.

### 7. Settings persistence
- Bare `UserDefaults.standard` for `mcp_enabled: Bool` and `mcp_port: Int`. UserDefaults is fine — nothing sensitive.
- React to changes the simple way: SettingsView is the only place that mutates these. On a toggle/port change, the view explicitly calls `model.applyMCPSettings()` which decides whether to start, stop, or restart the listener. We don't need to subscribe to `UserDefaults.didChangeNotification` from the model; that subscription has cross-actor headaches with `@Observable`. Direct call site is cheaper and clearer.
- `@AppStorage` *can* be used inside the SettingsView itself for two-way binding to the toggle/port controls — but the model side reads raw UserDefaults via `MCPSettings.shared`.

### 8. Stop conditions for v1
- Keep this scoped. Don't add `move_to_trash`, `propose_reply`, `summarize_thread`, etc. The whole point is that the LLM does the reasoning.
- If during use you find yourself wanting always-on without keeping FMail open → **stop and pivot to Option B** (`FMailCore` Swift package + LaunchAgent). Don't bolt daemon-mode onto FMail.app.

---

## Out of scope (deferred)

- **Standalone daemon (Option B).** `FMailCore` Swift-package extraction. Re-evaluate after 2 weeks of daily use.
- ~~**Move/trash/spam tools.**~~ Shipped as `delete_messages` and `move_to_junk` (see Tool surface). Archive still deferred.
- **Attachment bytes.** Endpoint to fetch attachment data. LLMs don't need bytes for triage.
- **Streaming tool responses (SSE).** Useful for long-running calls; none of our tools are slow enough yet.
- **Auth / bearer tokens.** Local-trust is fine for v1.
- **`search_emails_simple`** (structured params instead of DSL string). Add only if the DSL form proves error-prone.
- **iOS companion** (`FMailSpec.md` §14). Independent of this work.

## Stopping condition

If, after ~2 weeks of daily Claude-Code use:
- You're using only one or two tools → trim the surface, don't grow it.
- You wish FMail didn't have to be open → promote to Option B (LaunchAgent + `FMailCore`).
- You want move-to-trash → that's a separate `MailScripter` work-stream, not a bigger MCP surface.
