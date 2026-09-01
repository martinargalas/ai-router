# Client setup

| Client | Endpoint | Model | Note |
|---|---|---|---|
| Continue — autocomplete | `/v1/completions` | `fast-local` | never `auto`; latency |
| Continue — chat, edit | `/v1/chat/completions` | `auto` | router decides |
| Aider | `/v1/chat/completions` | `auto` | only agentic client that works with local models |
| Claude Code | `/v1/messages` | `frontier-mid` | needs tool calling |
| MCP clients | `/mcp` | — | the gateway proxies and logs tool calls |

## Address

`http://localhost:4000` — the gateway binds to localhost only. If you want to
reach it from other machines, put a reverse proxy in front of it; nothing in
this stack requires one.

## Keys

Use a per-developer virtual key. Never use `LITELLM_MASTER_KEY` in a client —
it is full admin over the gateway.

## Measured constraints

- **Local models do not do tool calling reliably.** Given a tool definition the
  local model returns `stop_reason: end_turn` and plain text instead of
  `tool_use`. Clients built on native tool calling must route to cloud models.
- **Aider is the exception** — it applies text SEARCH/REPLACE blocks rather than
  calling tools, so local models work with it.
- **Autocomplete must not go through `auto`.** The classifier adds ~0.69 s.
