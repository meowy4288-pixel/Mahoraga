# Mahoraga's Wheel — API Key Proxy

**An ephemeral API key rotation proxy for AI coding agents.**
Sits between your agent and your LLM provider(s). Manages multiple keys,
tracks per-key credit consumption locally, and rotates transparently when
a key hits the configurable threshold.

Part of the [Mahoraga](../README.md) ecosystem — designed to pair with the
purifier sandbox so that **keys, tokens, and agent output all die together**
when the session ends.

---

## Why this exists

AI coding agents (aider, opencode, Claude Code, etc.) burn through API
tokens fast. A single key can hit rate limits or run out of credits mid-
session. This proxy gives you:

- **Multi-key rotation** — spread load across several keys automatically
- **Credit tracking** — no provider API calls; just local math on token
  counts returned in responses
- **Transparent to the agent** — drop-in OpenAI-compatible endpoint at
  `http://localhost:8080`
- **Zero persistence** — no database, no state files. Kill the container
  and everything is gone. Designed to pair with [purifier](../purifier)
  for truly ephemeral agent sessions

---

## Architecture

```
                    ┌─────────────────────────────────┐
                    │         Agent (aider, etc.)      │
                    │  POST /v1/chat/completions ──────┤
                    └──────────┬──────────────────────┘
                               │ http://localhost:8080
                               ▼
                    ┌─────────────────────────────────┐
                    │   Mahoraga's Wheel (container)   │
                    │                                  │
                    │  ┌──────────┐   ┌──────────┐    │
                    │  │ Key      │   │ Credit   │    │
                    │  │ Selector │──▶│ Tracker  │    │
                    │  │ (highest │   │ (in-mem  │    │
                    │  │  >300)   │   │  dict)   │    │
                    │  └────┬─────┘   └──────────┘    │
                    │       │                          │
                    │  ┌────▼─────┐                    │
                    │  │ Forward  │                    │
                    │  │ (urllib) │                    │
                    │  └────┬─────┘                    │
                    └───────┼─────────────────────────┘
                            │
                    ┌───────▼──────────┐
                    │  Provider API    │
                    │  (DeepSeek,      │
                    │   OpenAI, etc.)  │
                    └──────────────────┘
```

### How it works step by step

1. **Startup** — container boots, scans `/keys/` for `.key` files, loads
   each into an in-memory dict with its `starting_credits` as balance.
   Zero state files. Nothing written to disk.

2. **Request arrives** — agent sends `POST /v1/chat/completions` with
   the usual OpenAI-format JSON body.

3. **Key selection** — the proxy iterates all loaded keys and picks the
   one with the **highest** `remaining` credits that is still **above**
   `CREDIT_THRESHOLD` (default 300). This ensures:
   - Most-loaded key gets used first
   - No key is drained to zero before rotation
   - Silent rotation — the agent never knows a swap happened

4. **Forwarding** — the request body is forwarded verbatim to the
   provider's API endpoint. The only header changed is `Authorization`
   (set to the selected key). All other headers pass through.

5. **Token counting** — after the provider responds:
   - **Non-streaming**: reads `usage.total_tokens` from the response JSON.
     If missing, falls back to `len(body) // 3` (rough character estimate).
   - **Streaming**: buffers the SSE stream, forwarding chunks in real-time
     to the agent. After the stream ends, extracts `usage` from the final
     data chunk (the one just before `data: [DONE]`). If absent, falls back
     to the same character estimate.

6. **Credit deduction** — `total_tokens` is subtracted from the key's
   in-memory `remaining` balance. All operations are thread-safe (protected
   by a `threading.Lock`).

7. **Exhaustion** — on the **next** request, if that key is now ≤300, the
   selector picks the next-best key. If **all** keys are ≤300, the proxy
   returns **HTTP 507** with per-key status so you know which need
   replenishment.

---

## Key files — the only thing you touch

Keys live in a directory on the **host** (e.g. `~/.api-keys/`), bind-
mounted into the container at `/keys`. This directory is the **only**
persistent surface you interact with.

### Format (`anything-you-want.key`)

```
# Lines starting with # are comments
name=production-deepseek
key=sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
provider=deepseek
starting_credits=10000000

# Optional: override the API base URL for custom providers
# base_url=https://custom.api.com/v1
```

Each file = one key. Add as many as you want. The proxy rescans the
directory every 30 seconds (configurable via `RELOAD_INTERVAL`), so you
can drop new keys in or remove exhausted ones without restarting.

### ⚠️ Security — remember to lock/hide the folder

The key files contain **raw API keys**. Treat them like passwords:

```bash
chmod 700 ~/.api-keys          # directory: only you can enter
chmod 600 ~/.api-keys/*.key     # files: only you can read
```

The proxy only needs **read** access, so mount with `:ro`:

```bash
docker run -v ~/.api-keys:/keys:ro ...
```

Never commit the keys folder, never paste a key into a chat, never
leave it world-readable. When the session ends, consider rotating
any keys that were used.

---

## API reference

### `POST /v1/chat/completions`

OpenAI-compatible chat completion. Accepts the standard request body.
The `stream` parameter is supported and forwarded transparently.

**Request** (same as OpenAI SDK):
```json
{
  "model": "deepseek-chat",
  "messages": [{"role": "user", "content": "Hello"}],
  "stream": false
}
```

**Response** (passthrough from provider, with added `_proxy` metadata):
```json
{
  "id": "...",
  "choices": [...],
  "usage": {"prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30},
  "_proxy": {
    "key": "production-deepseek",
    "provider": "deepseek",
    "credits_remaining": 999970
  }
}
```

**Streaming response** — forwarded as SSE, same wire format as the
provider sends. The `_proxy` metadata is **not** injected into the
stream (it would break client SSE parsers). Check `GET /keys/status`
to monitor credit consumption in real-time.

### `GET /health`

```json
{"status": "ok", "keys_loaded": 3}
```

### `GET /keys/status`

```json
{
  "keys": [
    {
      "name": "production-deepseek",
      "provider": "deepseek",
      "remaining": 999970,
      "starting": 10000000,
      "exhausted": false
    }
  ]
}
```

### `GET /reload`

Force-rescans the keys directory immediately (bypasses the 30s interval).

```json
{"status": "reloaded", "keys_loaded": 3}
```

---

## Error scenarios

| HTTP | Condition | What the agent sees |
|------|-----------|---------------------|
| 503 | No `.key` files found in `/keys` | `{"error": "no_keys"}` |
| 507 | All keys have remaining ≤ threshold | `{"error": "all_keys_exhausted", "keys": [...]}` |
| 502 | Provider DNS / connection failure | `{"error": "provider_unreachable"}` |
| 4xx | Provider returned an HTTP error | Forwarded verbatim from provider |
| 400 | Bad request body (invalid JSON) | `{"error": "bad request: ..."}` |

---

## Environment reference

| Variable | Default | Description |
|---|---|---|
| `PROXY_PORT` | `8080` | Port the proxy listens on inside the container |
| `CREDIT_THRESHOLD` | `300` | Rotate off a key when remaining ≤ this value |
| `KEYS_DIR` | `/keys` | Container path for `.key` files |
| `RELOAD_INTERVAL` | `30` | Seconds between rescans of the keys directory |
| `REQUEST_TIMEOUT` | `120` | Seconds before timing out a provider request |

---

## Integration with purifier

The proxy is designed to run alongside [purifier](../purifier) for fully
ephemeral AI coding sessions:

```bash
# Terminal 1: start the proxy
docker run --rm --name api-proxy \
  -p 8080:8080 \
  -v ~/.api-keys:/keys:ro \
  localhost/api-proxy

# Terminal 2: start a purifier session
purifier init --timeout 2h ~/my-project
purifier exec "aider --api-base http://localhost:8080"

# When done:
purifier end                    # approve/promote changes
docker stop api-proxy           # kills proxy + all in-memory credit state
```

Nothing persists. No key traces in the agent's context. No leftover
state on disk.

---

## Building

```bash
docker build -t api-proxy .
docker images api-proxy
# → ~51 MB (python:3.12-alpine base)
```

## Running

```bash
docker run -d \
  --name api-proxy \
  -p 8080:8080 \
  -v ~/.api-keys:/keys:ro \
  api-proxy
```

For Docker on Fedora with SELinux, add `:Z` to the volume mount:

```bash
  -v ~/.api-keys:/keys:ro,Z
```

---

## Multi-key strategy example

```
~/.api-keys/
├── deepseek-urgent.key    # starting_credits=1000000  → used first
├── deepseek-standard.key  # starting_credits=500000   → used second
└── deepseek-spare.key     # starting_credits=100000   → used last
```

The proxy always picks the richest key above threshold. When
`deepseek-urgent` drops to ≤300, it swaps to `deepseek-standard`
mid-session without the agent noticing. When all three are drained,
the proxy returns 507 and you get a log line saying which keys need
reloading.

---

## How is this different from a VPN / gateway / API gateway?

| Approach | Persistence | Key rotation | Credit tracking | Agent isolation |
|---|---|---|---|---|
| **Mahoraga's Wheel** | None (in-memory only) | Auto, credit-based | Local token counting | Full (container) |
| VPN / gateway | Network-level only | Manual | None | None |
| API gateway (Kong, etc.) | Database-backed | Requires plugin | External metering | Partial |
| Direct provider SDK | In code | Must implement yourself | Via provider API | None |

Mahoraga's Wheel is deliberately **minimal**: no database, no config
files, no provider API polling, no persistent state. It exists only
for the duration of the container, tracks everything in memory, and
leaves nothing behind.
