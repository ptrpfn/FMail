# FMail MCP server — implementation plan

Status: **planned, not started.** Pick this up by working through the phases below.

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

Move-to-trash / move-to-spam / archive are **not** in v1 — they need new `MailScripter` AppleScript surface that doesn't exist yet.

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

---

## Tool surface (6 tools)

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

**New SQL needed.** Sketch: for each thread that has at least one outgoing message from `our_address` (or any account address) after `since`, the latest message in the thread is outgoing AND its `date_sent` is older than today. `m.is_outgoing` is already populated by the indexer. Add as a method on `IndexDB`. Tests for this go in Phase A4.

### `mark_read`

```jsonc
// Input
{ "rowids": [12345, 12346, 12347], "is_read": true }
// Output
{ "applied": 3, "errors": [] }   // errors[] populated if any rowid fails AppleScript dispatch
```

Routes through `ReadStatusController.setReadStatus(messages:isRead:)`. The controller currently takes `[MessageHeader]`, not `[Int]`. Pick one:

- **Option α (preferred):** Add `setReadStatus(rowids: [Int], isRead: Bool)` that resolves rowids → `MessageHeader` via `IndexDB` first, then calls existing path. Self-contained.
- Option β: refactor `ReadStatusController` to take rowids natively. Bigger blast radius.

Failures still surface via the existing `bulkActionError` plumbing in FMail's UI; the MCP response also reports them so the LLM knows.

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

1. `MCPSettings.swift` — `@AppStorage("mcp_enabled")` Bool, `@AppStorage("mcp_port")` Int (default 8765).
2. `MCPTransport.swift` — JSON-RPC 2.0 framing over HTTP. Hand-write the minimal HTTP server: parse request line + Content-Length + body, write `200 OK` + JSON. ~150 LOC.
3. `MCPServer.swift` — actor wrapping `NWListener`. `start(port:)` / `stop()`. Empty tool registry. Handles `initialize` / `initialized` / `tools/list` (returns []) / `tools/call` (returns method-not-found).
4. Wire start/stop into `MailModel.boot()` gated on `MCPSettings.enabled` and `loadState == .ready`. Reactive on settings change (observe via Combine or `@AppStorage` notification).
5. **Done when:** with toggle on, `curl -X POST localhost:8765/mcp -d '{"jsonrpc":"2.0","id":1,"method":"initialize",…}'` returns server info; Claude Code MCP client connects and lists zero tools.

### A2 — Read tools (1 evening)

6. `MCPModels.swift` — define `EmailRef`, `EmailFull`, `ThreadRef`, `AttachmentRef` as Sendable Codable structs.
7. `MCPHandlers.swift` — implement `search_emails`, `list_threads`, `get_thread`, `get_email`. Each is one async function:
   - Validate input (throw `invalid_params` on bad shape).
   - Await `IndexDB.search` / `loadAllThreadSummaries` / `loadThreadMessages` / `BodyLoader.loadBody`.
   - Map internal types → DTOs.
8. Body truncation: `String.prefix(maxBodyChars)` with a `"\n[…truncated, full message has X chars…]"` sentinel when truncated.
9. `MCPTools.swift` — register the four tools with their JSON Schemas. **The `search_emails` tool description must include the DSL grammar table from `FMailSpec.md` §6.2.**
10. **Done when:** in Claude Code, "find emails from Anna last March" returns sensible results.

### A3 — `find_unanswered_threads` + `mark_read` + Settings UI (1 evening)

11. `IndexDB.findUnansweredThreads(since:ourAddresses:limit:)` — new method. Pure SQL — no FTS. Sketch:
    ```sql
    -- For each thread, find its latest message and the latest outgoing message.
    -- Filter to threads where the latest message is outgoing from one of our addresses,
    -- it was sent after :since, and there's no later incoming reply.
    ```
    Test with a small fixture DB (in-memory) before wiring in.
12. `MCPHandlers.swift` — `find_unanswered_threads` handler.
13. `ReadStatusController.swift` — add `setReadStatus(rowids: [Int], isRead: Bool)` overload that resolves rowids via `IndexDB`, then forwards to existing `setReadStatus(messages:isRead:)`. Result returned to MCP layer.
14. `mark_read` handler.
15. `Settings/SettingsView.swift` — toggle + port + status + privacy banner + "Copy Claude Code config" button. The snippet to copy:
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
16. Add `Settings…` command (`⌘,`) in `FMailApp.swift` `CommandMenu` (alongside the Tools menu).
17. **Done when:** flipping the toggle on/off cleanly starts/stops the listener; Claude Code can mark messages read and the change appears in FMail's UI immediately (optimistic flip via existing pipeline).

### A4 — Tests + footer status + docs (1 evening)

18. `FMailTests/MCPTests.swift`:
    - DTO encode/decode round-trip for each of the 5 DTO types.
    - JSON-RPC envelope edge cases (missing `id`, batch requests if we choose to support, malformed JSON).
    - `findUnansweredThreads` against a fixture DB with hand-built rows (use an in-memory `IndexDB` if feasible; if not, document why and skip).
    - Integration test: bind on random port, full handshake + one call to each of the 6 tools, assert response shape.
19. `AppShell.swift` — small status pill in the footer: "MCP :8765" badge when `mcpServer?.isRunning == true`. Hidden otherwise.
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
- The existing `setReadStatus(messages:isRead:)` is already async + idempotent + handles AppleScript failures. Don't reinvent. Just resolve rowids → `MessageHeader` via `IndexDB.loadMessage(rowid:)` (add this if it doesn't exist) and forward.
- The MCP response for `mark_read` should wait for the AppleScript dispatch to complete. The existing pipeline runs AppleScript on a `Task.detached` — for MCP, we want to await it. May need a new variant of `setReadStatus` that returns a result instead of fire-and-forget.

### 5. DSL exposure
- Description goes in `tools/list` output. Paste the full DSL grammar from `FMailSpec.md` §6.2 into the `description` field of `search_emails`'s tool definition. The LLM reads it once and uses it.
- Don't auto-translate natural language → DSL on the server side. The LLM does that.

### 6. Body content for the LLM
- Always send `plain_text_body` (from `MessageBody.displayText` — already HTML-stripped). Never send `html` directly; LLMs don't need it and it bloats context.
- Set `html_body_present: true` if the message had an HTML part, so the LLM knows it's a marketing email vs. plain text.

### 7. Settings persistence
- `@AppStorage("mcp_enabled")` and `@AppStorage("mcp_port")` are enough. UserDefaults is fine — nothing sensitive.
- React to changes: SwiftUI `@AppStorage` triggers view updates; for `MCPServer` lifecycle, observe the underlying `UserDefaults.didChangeNotification` or check on view-update (settings view is the only place that mutates these).

### 8. Stop conditions for v1
- Keep this scoped. Don't add `move_to_trash`, `propose_reply`, `summarize_thread`, etc. The whole point is that the LLM does the reasoning.
- If during use you find yourself wanting always-on without keeping FMail open → **stop and pivot to Option B** (`FMailCore` Swift package + LaunchAgent). Don't bolt daemon-mode onto FMail.app.

---

## Out of scope (deferred)

- **Standalone daemon (Option B).** `FMailCore` Swift-package extraction. Re-evaluate after 2 weeks of daily use.
- **Move/trash/spam tools.** Need new `MailScripter` AppleScript surface.
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
