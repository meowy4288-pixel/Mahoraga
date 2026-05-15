# Mei Mei

**Vision model integration for Six Eyes capture output.**

Mei Mei takes the raw PNG that `sixeyes capture` produces, base64-encodes it,
and sends it to any OpenAI-compatible vision API. The model's text response
is printed to stdout.

By default it routes through **Mahoraga's Wheel** proxy at `localhost:8080`,
but you can point it at any compatible endpoint.

The name comes from Jujutsu Kaisen's Mei Mei — a sorcerer who uses crows as
her eyes. She sees through them, and you see through her.

---

## Pipeline (end to end)

```
┌──────────┐    raw PNG     ┌──────────┐    base64 JSON POST    ┌──────────────┐
│ sixeyes  │ ────stdout──→  │  mei mei  │ ────localhost:8080──→  │    wheel     │
│ capture  │                │           │                        │ (api proxy)  │
└──────────┘                │           │                        └──────┬───────┘
                            │           │                               │
                            └──────────┘                     ┌──────────▼────────┐
                                                             │   cloud provider  │
                                                             │ (OpenAI, etc.)    │
                                                             └───────────────────┘
```

### Step by step

1. **Six Eyes capture** → captures only the user-permitted windows, stitches
   them into a single PNG, writes raw bytes to stdout.

2. **Pipe** → `|` sends those bytes to Mei Mei's stdin.

3. **Mei Mei** reads the raw PNG from stdin, base64-encodes it, wraps it in an
   OpenAI-compatible chat completions payload (text + image), and POSTs to the
   configured API endpoint.

4. **Mahoraga's Wheel** (at `localhost:8080`) receives the request, attaches
   the configured API key and routes it to the cloud provider.

5. **Cloud vision model** (GPT-4o, Claude 3.5 Sonnet, Gemini, etc.) processes
   the image + text prompt and returns a response.

6. **Response** travels back through the chain and Mei Mei prints the
   model's text to stdout.

All of this happens **entirely in memory**. Nothing touches disk except the
config file and the Six Eyes permission state.

---

## Files

### `meimei/meimei` (executable)

The main script. A single Python file with no pip dependencies — it uses
only Python's standard library:

| Module | Used for |
|--------|----------|
| `sys.stdin.buffer` | Reading raw PNG bytes from the pipe |
| `base64` | Encoding image bytes for JSON transport |
| `json` | Building and parsing API payloads |
| `urllib.request` | HTTP POST to the vision API |
| `argparse` | CLI argument parsing |
| `tomllib` (stdlib 3.11+) | Parsing `~/.config/meimei/config.toml` |
| `pathlib` | Config file path resolution |

Fallback: if `tomllib` is not available (Python < 3.11), it tries `tomli`
before giving up.

### `meimei/README.md` (this file)

Documentation.

### `~/.config/meimei/config.toml` (created by the user)

Configuration file. Not shipped in the repo — the user creates it based on
the reference config in this README.

---

## Requirements

### Runtime

| Dependency | Reason | Fedora package |
|-----------|--------|----------------|
| Python 3.11+ | `tomllib` in stdlib (3.8+ with extra `tomli` pkg) | `python3` |
| Network access | `localhost:8080` or your configured API endpoint | — |

No pip packages. No Pillow. No requests. All stdlib.

### Optional (for the full pipeline)

| Tool | Purpose | Fedora package |
|------|---------|----------------|
| `sixeyes` | Screen capture with permission control | `sixeyes/` in this repo |
| Mahoraga's Wheel | API key proxy | `mahoraga's wheel(apidocker)/` in this repo |
| Docker | Running the Wheel proxy | `docker` or `moby-engine` |

---

## Installation

```bash
# From the Mahoraga repo root:
ln -s "$PWD/meimei/meimei" ~/.local/bin/meimei

# Verify:
meimei --help

# Create config directory:
mkdir -p ~/.config/meimei

# Create the config file (see next section):
#   $EDITOR ~/.config/meimei/config.toml
```

---

## Configuration

### `~/.config/meimei/config.toml`

Every field and what it does:

```toml
# ── Provider ──────────────────────────────────────────────────────────────
[provider]

# API base URL for an OpenAI-compatible chat completions endpoint.
# Default: http://localhost:8080/v1  (Mahoraga's Wheel proxy)
#
# Other examples:
#   https://api.openai.com/v1          # OpenAI directly
#   https://api.anthropic.com          # NOT compatible (different format)
#   http://localhost:11434/v1          # Ollama local (if it supports vision)
#   https://api.deepseek.com/v1        # DeepSeek (no vision yet)
api_base = "http://localhost:8080/v1"

# Vision model identifier.
# Default: gpt-4o
#
# Common vision models:
#   gpt-4o            # OpenAI, strong vision
#   gpt-4o-mini       # OpenAI, cheaper vision
#   gpt-4-turbo       # OpenAI, older vision
#   claude-3-5-sonnet-20241022  # Anthropic (needs Anthropic endpoint)
#   gemini-1.5-pro    # Google (needs Google endpoint)
#   llava:13b         # Ollama local model
model = "gpt-4o"

# API key for authentication.
# Can be empty if the endpoint doesn't require one (e.g. localhost proxy).
# Mahoraga's Wheel handles its own keys, so leave this empty when using
# the proxy at localhost:8080.
api_key = ""


# ── Defaults ──────────────────────────────────────────────────────────────
[defaults]

# Maximum number of tokens in the model response.
# Higher = longer responses, more credits consumed.
# Default: 1024
max_tokens = 1024

# Sampling temperature (0.0 to 2.0).
# Lower = more deterministic, higher = more creative.
# Default: 0.7
temperature = 0.7
```

### Full working example (Mahoraga stack)

```toml
[provider]
api_base = "http://localhost:8080/v1"
model = "gpt-4o"
api_key = ""

[defaults]
max_tokens = 1024
temperature = 0.7
```

### Full working example (direct to OpenAI)

```toml
[provider]
api_base = "https://api.openai.com/v1"
model = "gpt-4o"
api_key = "sk-proj-..."

[defaults]
max_tokens = 2048
temperature = 0.3
```

---

## Usage

### Basic: pipe from Six Eyes

```bash
sixeyes capture | meimei "what is happening on screen"
```

1. `sixeyes capture` outputs raw PNG bytes to stdout.
2. `|` pipes them to `meimei`.
3. `meimei` reads the PNG, encodes it, sends it with the question.

### Using an image file (testing)

```bash
# Without Six Eyes — directly passing a file
meimei -f screenshot.png "describe this ui"

# Same thing, longer form
cat screenshot.png | meimei "describe"
```

### Override model per-command

```bash
# Use a cheaper model for quick questions
sixeyes capture | meimei -m gpt-4o-mini "what color is the button?"

# Use a local model
sixeyes capture | meimei -b http://localhost:11434/v1 -m llava:13b "explain this"
```

### Override everything per-command

```bash
sixeyes capture | meimei \
  -b https://api.openai.com/v1 \
  -m gpt-4o \
  -k sk-proj-... \
  -t 0.0 \
  -n 512 \
  "exactly what text do you see?"
```

### Debug: show the payload without sending

```bash
sixeyes capture | meimei --dry-run "what is this"

# Output (truncated):
# {
#   "model": "gpt-4o",
#   "messages": [
#     {
#       "role": "user",
#       "content": [
#         {"type": "text", "text": "what is this"},
#         {"type": "image_url", "image_url": {
#           "url": "data:image/png;base64,iVBOR...",
#           "detail": "auto"
#         }}
#       ]
#     }
#   ],
#   "max_tokens": 1024,
#   "temperature": 0.7
# }
```

### Use a different config file

```bash
meimei -c ~/project/special-config.toml -f image.png "analyze"
```

### Real-world: game assistant

```bash
sixeyes capture | meimei "what should I do next in this game? \
  list my inventory, health, and nearby enemies. \
  suggest the optimal next action."
```

### Real-world: UI debugging

```bash
sixeyes capture | meimei -t 0.0 -n 2048 \
  "examine this UI for accessibility issues. \
   list every problem you find with its location \
   and the recommended fix."
```

---

## Config file location and priority

Mei Mei loads configuration in this order (last value wins):

1. **Built-in defaults** (used if no config file exists):
   - `api_base` → `http://localhost:8080/v1`
   - `model` → `gpt-4o`
   - `api_key` → `""`
   - `max_tokens` → `1024`
   - `temperature` → `0.7`

2. **Config file** at `~/.config/meimei/config.toml` overrides any
   matching defaults.

3. **CLI flags** (`-m`, `-b`, `-k`, `-t`, `-n`) override both the
   config file and defaults.

This means:
- You can run with **zero configuration** if you're using the default
  Mahoraga stack (just start the Wheel proxy on 8080).
- You can set permanent overrides in the config file.
- You can do one-off overrides with CLI flags without editing the config.

---

## Error messages

### "error: no image data received"

**What happened:** stdin was empty and no `--file` was specified.

**Fix:** Pipe from `sixeyes capture`, or use `-f image.png`:
```
sixeyes capture | meimei "describe"
meimei -f screenshot.png "describe"
```

### "error: connection failed: Connection refused"

**What happened:** Could not connect to `api_base`.

**Common causes:**
- Mahoraga's Wheel container is not running.
- Wrong port or host in config.
- Service crashed.

**Fixes:**
```
# Check if the proxy is running:
docker ps | grep api-proxy

# If not, start it:
cd "mahoraga's wheel(apidocker)"
docker run -d --name api-proxy -p 8080:8080 -v ~/.api-keys:/keys:ro api-proxy

# Check if the API base is correct:
meimei --dry-run "test"  # shows the URL in the model field
```

### "error: connection failed: Name or service not known"

**What happened:** DNS resolution failed for the hostname in `api_base`.

**Fix:** Check for typos in the config file:
```toml
# WRONG:
api_base = "https;//api.openai.com/v1"

# RIGHT:
api_base = "https://api.openai.com/v1"
```

### "error: API returned HTTP 401"

**What happened:** Authentication failed. The API rejected the key.

**Fixes:**
- If using Mahoraga's Wheel: check your `.key` files in `~/.api-keys/`
  for the correct provider key.
- If using a direct endpoint: check `api_key` in config or pass with `-k`.
- The key might be expired or lack vision model access.

### "error: API returned HTTP 400"

**What happened:** Bad request. Usually an invalid model name or image
format issue.

**Fixes:**
```
# Check that the model supports vision:
meimei -m gpt-3.5-turbo -f test.png --dry-run "test"
# → Some models don't support image inputs. Use gpt-4o or similar.

# Check that the image is a valid PNG:
file test.png        # should say "PNG image data"
```

### "error: API returned HTTP 404"

**What happened:** The endpoint URL doesn't exist.

**Fix:** Make sure `api_base` ends with `/v1` (not `/v1/chat/completions`
and not just the base domain):
```toml
# WRONG:
api_base = "http://localhost:8080"
api_base = "http://localhost:8080/chat/completions"

# RIGHT:
api_base = "http://localhost:8080/v1"
```

### "error: unexpected API response format"

**What happened:** The API returned valid JSON but it didn't have the
expected structure (missing `choices[0].message.content`).

**Fixes:**
- You might be hitting a non-chat endpoint. Check `api_base`.
- The model might have returned a tool call or refusal instead of
  a content message. Check the full response with `--dry-run` and
  examine the API's raw output.
- Some providers use slightly different response formats. You may
  need an adapter.

### "error: failed to parse ~/.config/meimei/config.toml"

**What happened:** The TOML file has syntax errors.

**Fixes:**
```bash
# Check the file for typos:
cat ~/.config/meimei/config.toml

# Common mistakes:
#   - Using = instead of : for inline tables (but we use [section])
#   - Unquoted strings with special characters
#   - Trailing commas in arrays
```

---

## Troubleshooting

### "I get no output / blank response"

**Possible cause:** No windows are freed in Six Eyes, so `capture` returns
empty stdout, which means no image data reaches Mei Mei.

**Check:**
```bash
sixeyes status
# If "no windows freed", run:
sixeyes free firefox
sixeyes capture | wc -c
# Should be > 0
```

### "The model says it can't see the image" (e.g. "I'm a text model")

**Cause:** The model doesn't support vision inputs.

**Fix:** Use a vision-capable model:
```toml
# gpt-4o is the safest bet
model = "gpt-4o"
```

### "Curl works but Mei Mei doesn't" (or vice versa)

**Test with a direct curl command:**
```bash
# Convert a test image to base64 first:
B64=$(cat /tmp/test.png | base64 -w0)

curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"gpt-4o\",
    \"messages\": [{
      \"role\": \"user\",
      \"content\": [
        {\"type\": \"text\", \"text\": \"describe this\"},
        {\"type\": \"image_url\", \"image_url\": {
          \"url\": \"data:image/png;base64,$B64\",
          \"detail\": \"auto\"
        }}
      ]
    }]
  }"
```

If curl works, the issue is in Mei Mei. If curl also fails, the issue is
in the proxy or API key.

### "Image is too large"

Some vision APIs have image size limits (e.g., 20MB, or 10K
pixels). Six Eyes captures can be large if many windows are freed.

**Fixes:**
- Free fewer windows per capture.
- Use `--dry-run` to check the base64 size:
  ```
  sixeyes capture | meimei --dry-run | grep -c data:image
  ```
- Some APIs automatically downsample. If not, you may need to resize
  before sending (see the `detail: "auto"` field in the payload).

### "I'm using a proxy but getting SSL errors"

**If the proxy is on localhost:** Disable SSL verification is not
needed because urllib trusts localhost by default.

**If you're using a self-signed certificate:** Python's urllib will
reject it. Either:
- Use a proper certificate, or
- Use `http://` instead of `https://` for local services, or
- Wrap the request in a custom SSL context (not supported by default
  in Mei Mei — use a different tool or bypass urllib's check).

### "The proxy is running but still Connection refused"

**Check:**
```bash
# Is the proxy really running?
docker ps | grep api-proxy

# Is it listening on the right interface?
docker logs api-proxy --tail 20

# Can you reach it directly?
curl -v http://localhost:8080/v1/models

# Is SELinux blocking it?
sudo ausearch -m avc -ts recent
# → You may need to adjust container port mapping
```

### "Config file not being read"

**Verify:**
```bash
# Check the path:
ls -la ~/.config/meimei/config.toml

# Test with explicit path:
meimei -c ~/.config/meimei/config.toml -f test.png --dry-run

# Enable verbose introspection:
# Mei Mei doesn't have a --verbose flag, but you can check
# which config is loaded by sniffing the --dry-run output:
meimei -f test.png --dry-run
# → The "model" field shows which model is active
```

---

## Command reference

```
meimei [options] [prompt]
```

| Argument | Description | Default |
|----------|-------------|---------|
| `prompt` | Question about the image | "Describe this image in detail." |

| Option | Description | Default |
|--------|-------------|---------|
| `-f, --file FILE` | Read image from file instead of stdin | stdin |
| `-c, --config CONFIG` | Config file path | `~/.config/meimei/config.toml` |
| `-m, --model MODEL` | Model override | from config |
| `-b, --api-base URL` | API base URL override | from config |
| `-k, --api-key KEY` | API key override | from config |
| `-t, --temperature FLOAT` | Temperature override | from config |
| `-n, --max-tokens INT` | Max tokens override | from config |
| `--dry-run` | Print JSON payload, don't send | off |

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success (response printed or dry-run) |
| 1 | Error (see stderr for details) |

Output is always on stdout. Errors are always on stderr. This means you
can pipe Mei Mei's output without error messages leaking through:

```bash
sixeyes capture | meimei "describe" | grep -i "important"
# stderr errors won't pipe into grep
```

---

## Use with Mahoraga's Wheel (recommended setup)

```bash
# 1. Make sure the proxy is running:
docker ps | grep api-proxy

# 2. If not, start it (requires built image):
cd "mahoraga's wheel(apidocker)"
docker run -d --name api-proxy \
  -p 8080:8080 \
  -v ~/.api-keys:/keys:ro \
  api-proxy

# 3. Leave api_key empty in Meimei's config:
#    [provider]
#    api_base = "http://localhost:8080/v1"
#    model = "gpt-4o"
#    api_key = ""

# 4. Free a window in Six Eyes:
sixeyes free firefox

# 5. Capture and analyze in one command:
sixeyes capture | meimei "what is on this page? summarize the content"
```

---

## Use without Six Eyes

Mei Mei works with any PNG source:

```bash
# From a screenshot tool:
grim -g "0,0 1920x1080" - | meimei "describe"

# From a file:
meimei -f screenshot.png "explain this diagram"

# From an image URL (download first):
curl -s https://example.com/image.png | meimei "describe"
```

---

## Limitations

- **Single image per request.** Mei Mei sends exactly one image per API
  call. It does not support multiple images in a single request.
- **No streaming.** The entire response is read before printing. No
  streaming/SSE support.
- **No retry logic.** If the API fails, Mei Mei fails. No automatic
  retries.
- **No image resizing.** The raw PNG is sent as-is. Some APIs may reject
  very large images.
- **OpenAI-compatible endpoints only.** Anthropic, Gemini, and other
  non-OpenAI-format APIs won't work without an adapter.
- **No video.** Single frames only.

---

## Comparison

| Feature | Mei Mei | Raw curl | OpenAI Python SDK |
|---------|---------|----------|-------------------|
| Zero pip installs | ✅ All stdlib | ✅ curl built-in | ❌ pip install |
| Reads stdin | ✅ Native | ⚠️ Requires wrapper | ❌ |
| Config file | ✅ TOML | ❌ Manual headers | ⚠️ env vars |
| Mahoraga proxy ready | ✅ Default | ⚠️ Manual URL | ⚠️ Manual config |
| Error messages | ✅ Helpful | ❌ Raw HTTP | ✅ |
| Streaming | ❌ | ✅ curl -N | ✅ |
| Multi-image | ❌ | ✅ | ✅ |
| Retry logic | ❌ | ❌ | ✅ |
