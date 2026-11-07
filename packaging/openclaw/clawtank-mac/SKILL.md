---
name: clawtank-mac
description: >
  See and drive this Mac through the ClawTank app's local Agent API:
  screenshots, clicks, typing, key shortcuts, opening apps, and virtual
  displays for a headless Mac mini or Mac Studio. Every action is audited, an
  on-screen badge with a Stop button shows while the agent is in control, and
  agent input pauses whenever a person uses the Mac. Use when the user asks to
  look at the screen, click or type somewhere, open an app, or automate a GUI
  app that shell and browser tools can't reach.
metadata:
  {
    "openclaw":
      {
        "emoji": "🦞",
        "homepage": "https://github.com/HMAKT99/ClawTank",
        "os": ["darwin"],
        "requires": { "bins": ["curl"], "env": ["CLAWTANK_AGENT_TOKEN"] },
        "primaryEnv": "CLAWTANK_AGENT_TOKEN",
      },
  }
---

# ClawTank: see and drive this Mac

[ClawTank](https://github.com/HMAKT99/ClawTank) is a free, open-source (Apache-2.0) RDP server for macOS. Its Agent API lets an agent running **on the same Mac** take screenshots and use the keyboard and mouse. The API listens on `127.0.0.1:3390` only; other machines can't reach it.

## Setup (once, done by the person)

1. Install ClawTank from [Releases](https://github.com/HMAKT99/ClawTank/releases) and finish its setup (Screen Recording and Accessibility).
2. **ClawTank → Settings → Agents**: turn on **Allow AI agents to control this Mac**, type a name (for example `OpenClaw`) and click **Create Token**.
3. Give the token to OpenClaw as `CLAWTANK_AGENT_TOKEN`, for example in `openclaw.json`:

   ```json5
   { skills: { entries: { "clawtank-mac": { apiKey: "ct_…" } } } }
   ```

Never print, log or repeat the token.

## Check it's working

```sh
U=${CLAWTANK_AGENT_URL:-http://127.0.0.1:3390}
A="Authorization: Bearer $CLAWTANK_AGENT_TOKEN"
curl -s "$U/v1/health"
curl -s -H "$A" "$U/v1/displays"
```

`/v1/health` returns `{"ok": true, …}` when ClawTank is running. If it can't connect, ask the person to open ClawTank and turn on Agents. If the port was changed, `CLAWTANK_AGENT_URL` holds the address.

## The loop: look, act, look again

1. **Look.** Take a screenshot and view the image:

   ```sh
   curl -s -H "$A" -D /tmp/clawtank-shot.txt "$U/v1/screenshot?max_width=1280&format=jpeg" -o /tmp/clawtank-shot.jpg
   grep -i '^x-clawtank' /tmp/clawtank-shot.txt
   ```

   Add `display=<id>` for a display other than the main one.

2. **Find coordinates.** Actions use **display-local points** (origin at the display's top-left). Convert a pixel in the screenshot with `point = pixel × X-ClawTank-Points-Per-Pixel` (from the headers). Without `max_width`, a screenshot is exactly one pixel per point.

3. **Act.** Send one action, or up to 50 in order:

   ```sh
   curl -s -H "$A" -H 'Content-Type: application/json' "$U/v1/input" \
     -d '{"actions": [{"type": "click", "x": 640, "y": 400}, {"type": "type", "text": "hello"}, {"type": "key", "key": "return"}]}'
   ```

4. **Look again** to confirm the result before the next step. Don't chain long sequences blind.

### Actions

```json
{"type": "move", "x": 100, "y": 200}
{"type": "click", "x": 100, "y": 200, "button": "left", "count": 1}
{"type": "drag", "from_x": 10, "from_y": 10, "to_x": 300, "to_y": 200}
{"type": "scroll", "dy": 5, "x": 400, "y": 300}
{"type": "key", "key": "cmd+space"}
{"type": "type", "text": "hello"}
```

- `button`: `left`, `right` or `middle`. `count: 2` double-clicks.
- `scroll`: `dy` > 0 scrolls down.
- `key`: a key or shortcut such as `return`, `escape`, `tab`, `cmd+space`, `cmd+shift+t`, `f5`.
- `type`: Unicode text, independent of the keyboard layout. Newlines press Return.
- Each action also takes an optional `"display"`.

### Other calls

| Request | Body | Returns |
|---|---|---|
| `GET /v1/state` | | Cursor, frontmost app and window title, `screen_locked` |
| `POST /v1/apps/open` | `{"name": "TextEdit"}` (name or bundle id) | `{"ok": true, "app": …}` |
| `POST /v1/virtual-displays` | `{"width": 1920, "height": 1080, "hidpi": false}` | `{"id": …}` |
| `DELETE /v1/virtual-displays/{id}` | | `{"ok": true}` |

Opening an app is more reliable than clicking through the Dock or Spotlight. On a headless Mac with no display, create a virtual display first (at most two), and remove it when done.

## Errors

| Status | What to do |
|---|---|
| 401 | The token is wrong or was revoked. Ask the person for a new one. |
| 404 | Unknown display, app or endpoint. Re-check `/v1/displays` or the app name. |
| 409 | A person is using the Mac. Wait a few seconds and retry; never fight them for control. |
| 429 | Too many bad tokens. Wait a minute. |
| 503 | ClawTank is missing Screen Recording or Accessibility. Ask the person to grant it. |

## Rules

- A person always wins. If you get 409, or the person says stop, stop.
- If `/v1/state` shows `screen_locked: true`, ask the person to unlock the Mac. Don't type a password.
- Don't type passwords, payment details or other secrets unless the person explicitly asks for that exact step.
- Ask before anything destructive or hard to undo: deleting files, sending messages or email, purchases, changing system settings.
- Everything you do shows in ClawTank's badge and Connection Log. The person can press **Stop** at any time, which turns the Agent API off.
