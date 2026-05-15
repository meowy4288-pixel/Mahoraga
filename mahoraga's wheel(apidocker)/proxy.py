#!/usr/bin/env python3
"""
API Key Proxy — automatic key rotation based on credit thresholds.

Runs as a standalone Docker container. Keys stored as .key files in
/keys/ directory. Agent points at http://localhost:PORT/ and the proxy
handles rotation transparently.
"""

import os, sys, json, time, threading, socket, signal
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

# ── Configuration ──────────────────────────────────────────────────────
PORT = int(os.environ.get("PROXY_PORT", "8080"))
THRESHOLD = int(os.environ.get("CREDIT_THRESHOLD", "300"))
KEYS_DIR = Path(os.environ.get("KEYS_DIR", "/keys"))
RELOAD_INTERVAL = int(os.environ.get("RELOAD_INTERVAL", "30"))
REQUEST_TIMEOUT = int(os.environ.get("REQUEST_TIMEOUT", "120"))

PROVIDER_BASE = {
    "deepseek": "https://api.deepseek.com/v1",
    "openai":   "https://api.openai.com/v1",
}


# ── Key file parsing ───────────────────────────────────────────────────
def parse_key_file(path: Path):
    """Read one .key file, return dict or None if invalid."""
    try:
        text = path.read_text("utf-8").strip()
    except (OSError, UnicodeDecodeError):
        return None
    info = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        info[k.strip()] = v.strip()
    if not all(k in info for k in ("name", "key", "provider")):
        return None
    starting = int(info.pop("starting_credits", 10000))
    info["starting"] = starting
    info["remaining"] = starting
    return info


def load_keys_from_disk():
    """Return dict of name -> key_info from all .key files."""
    out = {}
    if not KEYS_DIR.is_dir():
        return out
    for f in sorted(KEYS_DIR.glob("*.key")):
        info = parse_key_file(f)
        if info:
            out[info["name"]] = info
    return out


# ── Credit tracker (thread-safe) ───────────────────────────────────────
class CreditTracker:
    def __init__(self):
        self._keys: dict[str, dict] = {}
        self._lock = threading.Lock()
        self._last_reload = 0.0

    def _reload(self):
        now = time.monotonic()
        if now - self._last_reload < RELOAD_INTERVAL:
            return
        self._last_reload = now
        disk = load_keys_from_disk()
        with self._lock:
            old = {k: v["remaining"] for k, v in self._keys.items()}
            self._keys = disk
            for name, info in self._keys.items():
                info["remaining"] = old.get(name, info["starting"])

    def count(self) -> int:
        self._reload()
        with self._lock:
            return len(self._keys)

    def select(self):
        """Return the key with the highest remaining credits above threshold."""
        self._reload()
        best = None
        with self._lock:
            for info in self._keys.values():
                if info["remaining"] > THRESHOLD:
                    if best is None or info["remaining"] > best["remaining"]:
                        best = info
        return best

    def deduct(self, name: str, tokens: int):
        with self._lock:
            if name in self._keys:
                self._keys[name]["remaining"] = max(0, self._keys[name]["remaining"] - tokens)

    def all_exhausted(self) -> bool:
        self._reload()
        with self._lock:
            return bool(self._keys) and all(
                info["remaining"] <= THRESHOLD for info in self._keys.values()
            )

    def status(self) -> list[dict]:
        self._reload()
        with self._lock:
            return [
                {
                    "name": info["name"],
                    "provider": info.get("provider"),
                    "remaining": info["remaining"],
                    "starting": info["starting"],
                    "exhausted": info["remaining"] <= THRESHOLD,
                }
                for info in self._keys.values()
            ]


TRACKER = CreditTracker()


# ── Utility helpers ────────────────────────────────────────────────────
def _estimate_tokens(text: str) -> int:
    """Rough token estimate: ~3 chars per token for JSON."""
    return max(1, len(text) // 3)


def _extract_usage(body: bytes, is_stream: bool) -> int:
    """Extract total_tokens from a provider response body."""
    if is_stream:
        text = body.decode("utf-8", errors="replace")
        last_data = None
        for line in text.splitlines():
            if line.startswith("data: ") and not line.startswith("data: [DONE]"):
                last_data = line[6:]
        if last_data:
            try:
                usage = json.loads(last_data).get("usage", {}) or {}
                return usage.get("total_tokens", 0) or 0
            except json.JSONDecodeError:
                pass
        return _estimate_tokens(text)
    else:
        try:
            data = json.loads(body)
            usage = data.get("usage", {}) or {}
            return usage.get("total_tokens", 0) or 0
        except json.JSONDecodeError:
            return _estimate_tokens(body.decode("utf-8", errors="replace"))


# ── HTTP handler ────────────────────────────────────────────────────────
class Handler(BaseHTTPRequestHandler):
    # Silence per-request log lines; we log in _proxy_chat instead.
    def log_message(self, fmt, *args):
        pass

    # ── GET endpoints ──────────────────────────────────────────────────
    def do_GET(self):
        if self.path == "/health":
            self._json({"status": "ok", "keys_loaded": TRACKER.count()})
        elif self.path == "/keys/status":
            self._json({"keys": TRACKER.status()})
        elif self.path == "/reload":
            self._reload_keys()
        else:
            self.send_error(404)

    def _reload_keys(self):
        TRACKER._last_reload = 0
        TRACKER._reload()
        self._json({"status": "reloaded", "keys_loaded": TRACKER.count()})

    # ── POST /v1/chat/completions ──────────────────────────────────────
    def do_POST(self):
        if self.path == "/v1/chat/completions":
            self._proxy_chat()
        else:
            self.send_error(404)

    def _proxy_chat(self):
        req_id = f"{self.client_address[0]}:{self.client_address[1]}"
        t0 = time.time()

        # ── read body ──────────────────────────────────────────────────
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            req_data = json.loads(body)
        except (json.JSONDecodeError, OSError) as e:
            self._json({"error": f"bad request: {e}"}, 400)
            return

        # ── select key ─────────────────────────────────────────────────
        key = TRACKER.select()
        if key is None:
            if TRACKER.all_exhausted():
                self._json(
                    {
                        "error": "all_keys_exhausted",
                        "message": f"All keys are below the {THRESHOLD}-credit threshold.",
                        "keys": TRACKER.status(),
                    },
                    507,
                )
            else:
                self._json(
                    {"error": "no_keys", "message": "No .key files found in keys directory."},
                    503,
                )
            elapsed = time.time() - t0
            sys.stderr.write(f"[proxy] {req_id} NO_KEY {elapsed:.2f}s\n")
            return

        key_name = key["name"]
        provider = key.get("provider", "openai")

        # ── resolve provider endpoint ───────────────────────────────────
        base = PROVIDER_BASE.get(provider) or key.get("base_url", "")
        if not base:
            self._json({"error": f"unknown provider '{provider}'"}, 400)
            return
        url = f"{base.rstrip('/')}/chat/completions"

        # ── forward headers ─────────────────────────────────────────────
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {key['key']}",
        }
        for h in ("User-Agent", "Accept"):
            if h in self.headers:
                headers[h] = self.headers[h]

        stream = req_data.get("stream", False)

        # ── proxy to provider ──────────────────────────────────────────
        tokens_used = 0
        try:
            if stream:
                tokens_used = self._proxy_stream(url, headers, body, key)
            else:
                tokens_used = self._proxy_block(url, headers, body, key)
        except HTTPError as e:
            resp_body = e.read().decode(errors="replace")
            self._json(
                {"error": f"provider_http_{e.code}", "detail": resp_body}, e.code
            )
            elapsed = time.time() - t0
            sys.stderr.write(
                f"[proxy] {req_id} {key_name} ERR={e.code} {elapsed:.2f}s\n"
            )
            return
        except URLError as e:
            self._json({"error": "provider_unreachable", "detail": str(e.reason)}, 502)
            elapsed = time.time() - t0
            sys.stderr.write(f"[proxy] {req_id} {key_name} UNREACHABLE {elapsed:.2f}s\n")
            return
        except OSError as e:
            self._json({"error": "connection_error", "detail": str(e)}, 502)
            return

        # ── deduct credits ─────────────────────────────────────────────
        TRACKER.deduct(key_name, tokens_used)
        remaining = max(0, key["remaining"] - tokens_used)

        elapsed = time.time() - t0
        sys.stderr.write(
            f"[proxy] {req_id} {key_name} tokens={tokens_used} "
            f"remaining={remaining} {elapsed:.2f}s\n"
        )

    # ── Non-streaming proxy ─────────────────────────────────────────────
    def _proxy_block(self, url, headers, body, key) -> int:
        req = Request(url, data=body, headers=headers)
        with urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
            resp_body = resp.read()

        tokens = _extract_usage(resp_body, is_stream=False)

        # Re-wrap with proxy metadata
        data = json.loads(resp_body)
        remaining = max(0, key["remaining"] - tokens)
        data["_proxy"] = {
            "key": key["name"],
            "provider": key.get("provider"),
            "credits_remaining": remaining,
        }

        self._json(data)
        return tokens

    # ── Streaming proxy ─────────────────────────────────────────────────
    def _proxy_stream(self, url, headers, body, key) -> int:
        req = Request(url, data=body, headers=headers)
        upstream = urlopen(req, timeout=REQUEST_TIMEOUT)

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        buf = b""
        last_data = None

        try:
            while True:
                chunk = upstream.read(4096)
                if not chunk:
                    break
                buf += chunk
                self.wfile.write(chunk)
                self.wfile.flush()

                # Track the last non-DONE data line for usage extraction
                text = chunk.decode("utf-8", errors="replace")
                for line in text.splitlines():
                    if line.startswith("data: ") and not line.startswith("data: [DONE]"):
                        last_data = line[6:]
        except BrokenPipeError:
            pass  # client disconnected

        tokens = _extract_usage(buf, is_stream=True)

        # If the provider didn't include usage in-stream, fall back
        # to extracting from last_data
        if not tokens and last_data:
            try:
                usage = json.loads(last_data).get("usage", {}) or {}
                tokens = usage.get("total_tokens", 0) or 0
            except json.JSONDecodeError:
                pass

        if not tokens:
            tokens = _estimate_tokens(buf.decode("utf-8", errors="replace"))

        return tokens

    # ── JSON response helper ───────────────────────────────────────────
    def _json(self, data, status=200):
        body = json.dumps(data, indent=2, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


# ── Threaded server (dual-stack IPv4/IPv6) ─────────────────────────────
class ThreadedServer(ThreadingMixIn, HTTPServer):
    allow_reuse_address = True
    daemon_threads = True

    def server_bind(self):
        """Bind to IPv6 with V6ONLY=0 for dual-stack, fall back to IPv4."""
        try:
            self.socket = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            self.server_address = (self.server_address[0], self.server_address[1], 0, 0)
        except (OSError, AttributeError):
            self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind(self.server_address)
        self.socket.listen(self.request_queue_size)


# ── Entry point ────────────────────────────────────────────────────────
def main():
    KEYS_DIR.mkdir(parents=True, exist_ok=True)

    server = ThreadedServer(("", PORT), Handler)
    print(f"API Key Proxy  http://0.0.0.0:{PORT}", flush=True)
    print(f"  keys dir     {KEYS_DIR}", flush=True)
    print(f"  threshold    {THRESHOLD} credits", flush=True)
    print(f"  keys loaded  {TRACKER.count()}", flush=True)
    print(f"  reload int   {RELOAD_INTERVAL}s", flush=True)
    print(f"  timeout      {REQUEST_TIMEOUT}s", flush=True)
    print("", flush=True)

    shutdown = threading.Event()

    def _sig(*_):
        shutdown.set()

    signal.signal(signal.SIGTERM, _sig)
    signal.signal(signal.SIGINT,  _sig)

    # Run server in background thread
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()

    # Block main thread until signal
    try:
        shutdown.wait()
    except KeyboardInterrupt:
        pass

    print("Shutdown.", flush=True)
    server.shutdown()


if __name__ == "__main__":
    main()
