# Mahoraga

**Ephemeral tooling for AI coding agents.** Two standalone components
that together give you a fully isolated, auto-wiping agent session with
transparent API key rotation.

```
Mahoraga/
├── purifier/                          ← Ephemeral sandbox (tmpfs/overlay)
├── mahoraga's wheel(apidocker)/        ← API key rotation proxy
├── sixeyes/                           ← Permission-based screen access
└── README.md                          ← This file
```

---

## Components

### [purifier](./purifier) — Ephemeral sandbox

Mounts a tmpfs sandbox, binds your project read-only, lays an overlayfs
on top for writes. Agent runs inside the sandbox. On `purifier end` you
see a diff, approve, and changes are promoted to the real project. A
systemd user timer auto-wipes after 30 minutes (configurable).

```
purifier init /path/to/project     # start session
purifier exec "aider --model ..."  # run agent in sandbox
purifier end                       # diff → approve → promote → wipe
```

### [mahoraga's wheel(apidocker)](./mahoraga's%20wheel(apidocker)/) — API key proxy

Lightweight Docker container that sits between your agent and your LLM
provider. Manages multiple API keys, tracks per-key credit consumption
in memory, rotates automatically when a key drops below the threshold.

```
docker run -d -p 8080:8080 -v ~/.api-keys:/keys:ro api-proxy
# Point agent at http://localhost:8080
```

Keys are stored as simple `.key` files in a host directory. The proxy
never writes to disk. Kill the container and all credit state is gone.

### [sixeyes](./sixeyes) — Permission-based screen access

Default state is **total blindness** — the AI sees nothing. User explicitly
grants access to named windows only. Captures are held in memory, never
written to disk, and output as raw PNG ready to POST to any vision API.

```
sixeyes free youtube       # grant AI access to YouTube windows
sixeyes lock youtube       # revoke access
sixeyes status             # show permitted windows
sixeyes capture            # capture permitted windows → stdout (PNG)
```

Supports X11, Hyprland, and Sway. Pairs with Mahoraga's Wheel for key
management.

---

## Typical workflow

```bash
# Terminal 1 — start the key proxy
docker run --rm --name api-proxy \
  -p 8080:8080 \
  -v ~/.api-keys:/keys:ro \
  api-proxy

# Terminal 2 — start a purifier session with the proxy
purifier init --timeout 2h ~/my-project
purifier exec "aider --model deepseek-chat --api-base http://localhost:8080"

# ... agent works. All API calls go through the proxy.
# All file reads/writes stay inside the tmpfs sandbox.

# When done:
purifier end               # review diff, promote changes
docker stop api-proxy      # kill proxy, credit state disappears
```

**Nothing persists.** The sandbox, the proxy, and the screen captures all
exist in memory only. When the session ends, everything goes with it.

---

## Design principles

- **Ephemeral by default** — no state survives the session
- **Minimal dependencies** — tmpfs, overlayfs, systemd, Docker
- **Agent-agnostic** — works with aider, opencode, Claude Code, any
  OpenAI-compatible tool
- **Keys never log** — `.key` files are read-only mounted, never appear
  in proxy output or container logs
- **Thread-safe** — concurrent requests don't corrupt credit tracking

---

## Quick start

```bash
# Install purifier
cd purifier
bash install.sh
sudo modprobe overlay

# Build the proxy
cd "mahoraga's wheel(apidocker)"
docker build -t api-proxy .

# Drop in your keys
mkdir -p ~/.api-keys
# ... create .key files ...
chmod 700 ~/.api-keys
chmod 600 ~/.api-keys/*.key
```
