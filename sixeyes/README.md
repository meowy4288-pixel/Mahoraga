# Six Eyes

**Permission-based screen access layer for AI assistants.**

Default state is **total blindness** — the AI sees nothing. The user explicitly
grants access to named windows. Only those windows are ever captured.

The name comes from Jujutsu Kaisen's *Six Eyes*: the ability to see only what
matters, with perfect precision, and nothing else.

---

## Why

AI coding assistants that see your screen are powerful — but they currently see
everything. Every tab, every chat, every open document, your terminal history,
your email. This is an unacceptable privacy model.

Six Eyes inverts the default: **opt-in per window.** You decide what the AI can
see, one window at a time. Nothing else is ever captured.

---

## How it works

```
sixeyes free firefox     # AI can now see Firefox windows
sixeyes free terminal    # ...and the terminal
sixeyes status           # show what's permitted
sixeyes capture          # capture only those windows -> stdout (PNG)
sixeyes lock terminal    # revoke terminal access
sixeyes lock --all       # revoke everything — AI is blind again
```

### Permission model

1. **Default: deny.** No windows are visible. `sixeyes capture` returns nothing.
2. **Grant by name.** `sixeyes free <name>` adds a permission. Names are
   case-insensitive substrings matched against window titles. `free firefox`
   matches "Mozilla Firefox", "Firefox Developer Edition", "Firefox — Reddit",
   etc.
3. **Explicit revoke.** `sixeyes lock <name>` removes a permission. `--all`
   clears every permission at once.
4. **State persists** in `~/.local/state/sixeyes/permissions.json`.
   Permissions survive reboots. Lock what you no longer need.

### Capture rules

- Only windows whose titles match a **currently freed** name are captured.
- If no windows are freed, `capture` outputs **nothing** (empty stdout).
- If a window is freed but no matching window is currently open, it is skipped.
- Captures are **never written to disk.** They exist in memory only:
  composited into a PNG and streamed to stdout. What you do with the bytes
  (send to an API, pipe to a file, discard) is up to you.
- Multiple matching windows are combined into a single vertical strip with
  10 px black padding between them.

---

## Requirements

### Runtime

| Layer | Dependency | Fedora package |
|-------|-----------|----------------|
| Python runtime | Python 3.8+ | `python3` |
| Image processing | Pillow | `python3-pillow` |

### Per display server

| Server | Required | Package(s) |
|--------|----------|------------|
| **X11** | `xdotool` + `ImageMagick` | `xdotool` `ImageMagick` |
| **Hyprland** | `hyprctl` + `grim` | (part of Hyprland) `grim` |
| **Sway** | `swaymsg` + `grim` | `sway` `grim` |
| Other Wayland | **unsupported** | —|

> **Why not GNOME/KDE Wayland?** Wayland's security model prevents screen
> capture tools from reading individual window buffers. Only the compositor
> has access. Tools like `grim` capture the compositor's *rendered output*
> (a pixel region of the screen, including overlapping windows). X11's
> `import -window` bypasses this by asking the X server directly for a
> specific window's contents. Supporting GNOME/KDE would require the
> xdg-desktop-portal screencast D-Bus API, which is heavyweight and
> async. For now, use X11 or a wlroots-based compositor (Hyprland, Sway).

### Recommended

```
sudo dnf install python3-pillow xdotool ImageMagick grim
```

---

## Installation

```bash
# From the Mahoraga repo:
chmod +x sixeyes/sixeyes
ln -s "$PWD/sixeyes/sixeyes" ~/.local/bin/sixeyes

# Verify:
sixeyes --help
```

---

## Usage

### Free a window

```bash
sixeyes free youtube
```

Makes any currently open window **whose title contains "youtube"**
(case-insensitive) visible to future captures. The permission is saved
until you `lock` it.

### Lock a window

```bash
sixeyes lock youtube       # revoke just "youtube"
sixeyes lock --all         # revoke everything
```

### Check status

```bash
$ sixeyes status
freed windows (2):
  firefox  ->  2 window(s) visible
  terminal  ->  no matching window open
```

### Capture

```bash
sixeyes capture > /dev/null            # silently check if anything matches
sixeyes capture | base64 -w0           # base64-encoded PNG for API payloads
sixeyes capture | wc -c                # check image size (0 = nothing captured)
```

Output is raw PNG bytes on stdout. If no permissions match any open window,
stdout is empty (0 bytes). Errors go to stderr.

### Integration with a vision API

```bash
#!/usr/bin/env bash
# Capture permitted windows and send to an OpenAI-compatible API
IMAGE=$(sixeyes capture | base64 -w0)
[ -z "$IMAGE" ] && echo "Nothing to see" && exit 0

curl -s https://api.openai.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d '{
    "model": "gpt-4o",
    "messages": [
      {
        "role": "user",
        "content": [
          {"type": "text", "text": "What do you see in these windows?"},
          {"type": "image_url", "image_url": {"url": "data:image/png;base64,'"$IMAGE"'"}}
        ]
      }
    ]
  }'
```

### Integration with Mahoraga's Wheel

Route through the API key proxy at `localhost:8080`:

```bash
IMAGE=$(sixeyes capture | base64 -w0)
curl -s http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $(cat ~/.api-keys/your-key.key | grep key= | cut -d= -f2)" \
  -d '{
    "model": "deepseek-chat",
    "messages": [
      {
        "role": "user",
        "content": [
          {"type": "text", "text": "What do you see?"},
          {"type": "image_url", "image_url": {"url": "data:image/png;base64,'"$IMAGE"'"}}
        ]
      }
    ]
  }'
```

---

## Security model

| Concern | How Six Eyes handles it |
|---------|------------------------|
| **Default state** | Blind — no permissions, no captures |
| **Grant model** | Explicit opt-in per window name |
| **Capture scope** | Only windows matching freed names |
| **Disk writes** | Only the permission state file; **captures never touch disk** |
| **Clipboard** | Not accessed |
| **Filesystem** | Not accessed (beyond the state file) |
| **Window list** | Queried from the display server at capture time; never stored |
| **State file location** | `~/.local/state/sixeyes/permissions.json` (XDG complaint) |

### Wayland caveat

On Hyprland and Sway, captures use `grim -g <geometry>` which captures a
**screen region**, not an individual window buffer. If another window
overlaps the permitted window, the overlapping content will be included in
the capture. This is a Wayland protocol limitation. On X11, `import -window`
captures the exact window buffer regardless of overlap.

---

## Architecture

```
sixeyes/sixeyes          # standalone Python executable (no pip install needed)
sixeyes/README.md        # this file
```

No daemon, no background process. Every command is an on-demand invocation
of `sixeyes`. The permission state file is the only persistent state.

### Command dispatch

```
main()
 ├─ free <name>       → add to permissions.json
 ├─ lock <name|--all> → remove from permissions.json
 ├─ status            → read permissions.json, query visible windows
 └─ capture
      ├─ detect display server
      ├─ load permissions
      ├─ match windows by name
      ├─ capture matched windows
      ├─ combine into single PNG
      └─ write PNG bytes to stdout
```

### Display server detection

1. If `WAYLAND_DISPLAY` is set:
   - `HYPRLAND_INSTANCE_SIGNATURE` → Hyprland path
   - `swaymsg` responds → Sway path
   - Otherwise → unsupported Wayland fallback
2. If `DISPLAY` is set → X11 path
3. Otherwise → error

---

## Limitations

- **GNOME/KDE Wayland are unsupported** (see rationale in Requirements above)
- Window matching is by **title substring only** — does not match by window
  class, PID, or X11 `WM_CLASS`
- On Wayland (Hyprland/Sway), overlapping windows may appear in captures
- Only one compositor can be active at a time — no cross-server captures
- No video streaming, only single-frame capture
- `import` (ImageMagick) captures window buffers including off-screen
  content; `grim` captures only the visible on-screen region

---

## Comparison

| Feature | Six Eyes | Full-screen tools (scrot, grim) | Screen-sharing portals |
|---------|----------|-------------------------------|----------------------|
| Per-window permission | ✅ Explicit opt-in | ❌ Captures everything | ❌ Portal-wide |
| Default deny | ✅ Yes | ❌ No | ❌ No |
| No disk writes | ✅ Yes | ❌ Writes files | ✅ Usually |
| No background process | ✅ Yes | ✅ Yes | ❌ Portal daemon |
| Wayland support | ⚠️ Partial | ✅ Yes | ✅ Yes |
| X11 support | ✅ Yes | ✅ Yes | ✅ Yes |

---

## License

Same as the Mahoraga project.
