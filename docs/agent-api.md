# Agent API and MCP server

ClawTank can let AI agents running **on the same Mac** see the screen and use the keyboard and mouse. A typical use is a headless Mac mini that an agent drives. It's **off by default**.

## Turn it on

1. Go to **ClawTank → Settings → Agents** and turn on **Allow AI agents to control this Mac**.
2. Type a name (for example `Claude Code`) and click **Create Token**. Copy the token: it's shown only once. ClawTank stores only its SHA-256 hash.
3. Connect your agent.

   **MCP (recommended).** The MCP server ships inside the app:

   ```sh
   claude mcp add clawtank --env CLAWTANK_AGENT_TOKEN=ct_… -- \
     "/Applications/ClawTank.app/Contents/MacOS/clawtank-mcp"
   ```

   Any MCP client works the same way: run that binary over stdio with `CLAWTANK_AGENT_TOKEN` set. If you changed the port, also set `CLAWTANK_AGENT_URL=http://127.0.0.1:<port>`.

   **Claude Desktop.** Download `clawtank-mcp-<version>-arm64.mcpb` from [Releases](https://github.com/HMAKT99/ClawTank/releases) and double-click it. Claude Desktop asks for the token. The bundle contains the same `clawtank-mcp` as the app, so ClawTank itself must still be installed and running.

   The server is also listed in the [MCP Registry](https://registry.modelcontextprotocol.io) as `io.github.HMAKT99/clawtank`.

ClawTank needs Screen Recording (for screenshots) and Accessibility (for input). It already asks for both during setup.

## What a person sees

- While an agent is acting, an orange **Agent "name" is in control** badge appears at the top of every display. The badge has a **Stop** button.
- The menu-bar icon changes, and the menu shows the agent's last action.
- **Stop** (in the badge or the menu) turns the Agent API off. That also removes any virtual displays agents created.
- Every agent request is written to **Connection Log** as "Agent action" or "Agent refused": screenshots, clicks, keys, apps opened, failed tokens. Typed text is recorded as a character count, never the text itself.
- **A person always wins.** For 3 seconds after any keyboard or mouse input from an RDP client, agent input and app launches are refused with HTTP 409 (the MCP tools say "a person is controlling the Mac; wait and try again"). Screenshots and state reads still work.

## MCP tools

| Tool | What it does |
|---|---|
| `screenshot` | Captures a display (default: the main one), at most 1568 px wide. **All coordinates in the other tools are pixels of the latest screenshot of that display.** |
| `get_state` | Returns the cursor position, the frontmost app and its focused window title, and whether the screen is locked. |
| `list_displays` | Lists displays: id, size in points, scale, main, virtual. |
| `click`, `move_mouse`, `drag`, `scroll` | Mouse actions. `click` takes `button` (left/right/middle) and `count` (2 = double-click). `scroll`: `dy` > 0 scrolls down. |
| `press_key` | A key or shortcut: `return`, `cmd+space`, `cmd+shift+t`, `f5`, `ctrl+alt+delete`… |
| `type_text` | Types Unicode text into the focused field. It doesn't depend on the keyboard layout; newlines press Return. |
| `open_app` | Opens or activates an installed app by name (`TextEdit`) or bundle id. |
| `create_virtual_display`, `remove_virtual_display` | Creates up to two extra desktops (for example on a headless Mac) and removes them. |

## REST API

For scripts. It listens on `127.0.0.1:3390` only. Every call except `/v1/health` needs `Authorization: Bearer <token>`.

| Request | Body / query | Returns |
|---|---|---|
| `GET /v1/health` | | `{"ok": true, "version": "…"}` |
| `GET /v1/displays` | | `{"displays": [{"id", "width", "height", "scale", "main", "virtual"}]}`. Width and height are in points. |
| `GET /v1/screenshot` | `display`, `max_width`, `format=png\|jpeg` | An image. Headers `X-ClawTank-Display`, `-Width`, `-Height`, `-Points-Per-Pixel`. |
| `GET /v1/state` | | `{"cursor": {"display", "x", "y"}, "frontmost_app": {"name", "bundle_id", "pid", "window_title"}, "screen_locked"}` |
| `POST /v1/input` | `{"actions": [ … ]}` (1–50), or a single action | `{"ok": true, "performed": n}` |
| `POST /v1/apps/open` | `{"name": "TextEdit"}` | `{"ok": true, "app": "TextEdit"}` |
| `POST /v1/virtual-displays` | `{"width": 1920, "height": 1080, "hidpi": false}` | `{"id": …}` |
| `DELETE /v1/virtual-displays/{id}` | | `{"ok": true}` |

REST coordinates are **display-local points**, with the origin at the display's top-left. A default screenshot (no `max_width`) is exactly one pixel per point.

The available actions are:

```json
{"type": "move", "x": 100, "y": 200}
{"type": "click", "x": 100, "y": 200, "button": "left", "count": 1}
{"type": "drag", "from_x": 10, "from_y": 10, "to_x": 300, "to_y": 200}
{"type": "scroll", "dy": 5, "x": 400, "y": 300}
{"type": "key", "key": "cmd+space"}
{"type": "type", "text": "hello"}
```

Each one also takes an optional `"display"`. For example:

```sh
T=ct_…
curl -s -H "Authorization: Bearer $T" "http://127.0.0.1:3390/v1/screenshot?max_width=1024" -o shot.png
curl -s -H "Authorization: Bearer $T" -d '{"name":"TextEdit"}' http://127.0.0.1:3390/v1/apps/open
```

Errors are JSON `{"error": "…"}`:

| Status | Meaning |
|---|---|
| 400 | Bad request |
| 401 | Bad token |
| 403 | Browser or non-loopback Host |
| 404 | Unknown display, app or endpoint |
| 409 | A person is using the Mac |
| 429 | Too many bad tokens; wait a minute |
| 503 | A permission is missing |

## Security model

- **Local only.** The listener binds 127.0.0.1, so other machines can't reach it. Remote agents should run on the Mac, or reach it via SSH.
- **Per-agent tokens.** Each agent has its own 256-bit random token. Only hashes are stored, in `~/Library/Application Support/ClawTank/agents.json` (mode 0600). Revoke a token in Settings.
- **Browsers are refused.** A browser can't call the API from a web page: requests with an `Origin` header, or with a `Host` that isn't loopback (DNS rebinding), are rejected before authentication.
- **Brute force is throttled.** After 10 bad tokens in a minute, all requests get 429 for a minute.
- **Any process running as your user could act like an agent if it had a token.** That's the same trust level as any app you've granted Accessibility. Keep tokens out of shared files and repos.
