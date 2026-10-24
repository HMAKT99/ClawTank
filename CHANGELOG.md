# Changelog

All notable changes are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### MCP
- The MCP server is packaged as an MCP Bundle (`clawtank-mcp-<version>-arm64.mcpb`) for one-click install in Claude Desktop, and listed in the MCP Registry as `io.github.HMAKT99/clawtank` (`server.json`). `make release` builds both.

### Documentation
- README hero diagram (clients → Mac mini running ClawTank) in place of the demo-GIF placeholder, and a GitHub social preview image (`docs/media/*.svg` are the sources).
- README: Mac to Mac use (a Mac mini or Mac Studio from a MacBook), a FAQ entry comparing it with macOS Screen Sharing, and a headless-Mac row in the comparison table.
- README screenshots (Settings, connection guide), rendered from the app's views by an opt-in test (`TEST_RUNNER_CLAWTANK_SCREENSHOTS=<dir>`).
- CodeQL scanning for Rust and the workflows; CI actions pinned to commit SHAs.

### Dependencies
- `crypto-bigint` 0.7.6 and `ctutils` 0.4.5 for RUSTSEC-2026-0387 and RUSTSEC-2026-0385 (timing side channels in constant-time code).
- `x509-cert` 0.3 (certificate fields are now accessor methods; `TlsIdentity::public_key` updated), `sha2` 0.11.1, `base64` 0.23.
- CI: `actions/checkout` and `actions/upload-artifact` v7.

## [0.9.0] - 2026-10-22

First public beta. ClawTank is a native RDP server for macOS: connect from Windows App, `mstsc`, FreeRDP or any standard RDP client and get a hardware-accelerated desktop.

**Highlights**
- H.264 (AVC420) over the RDP graphics pipeline: about 60 fps at under 10% CPU on Apple silicon.
- Live resize to the client's window, with Retina virtual displays (great for a headless Mac mini).
- Keyboard and mouse with local cursor shapes, system audio, two-way clipboard (text, rich text, images), and file and folder copy and paste.
- Secure by default: TLS with NLA, LAN-only, lockout after failed logins, and an audit log. Reach it from anywhere with Tailscale, with no port forwarding.
- Agent API and MCP server: let local AI agents see and drive the Mac, with tokens, an audit log and a visible Stop.

**Known limitations in this beta**
- Not notarized yet, so you need the one-time "Open Anyway" step. Apple silicon only.
- One monitor per session (multi-monitor clients get one resizable desktop). No AVC444 (full-colour) mode; Retina sessions give crisp text instead.
- A locked Mac shows only the wallpaper to remote clients until it's unlocked at the Mac (macOS limitation).
- Manual checks against Windows `mstsc`/Windows App, a headless Mac mini and real-world Wi-Fi are still in progress. Please report issues.
- No automatic updates yet: watch GitHub Releases.

**Documentation:** a beta testing guide (docs/beta-testing.md), issue forms for bug reports, beta test reports and feature requests, a rewritten architecture overview, a docs index, SUPPORT.md, an expanded CONTRIBUTING.md and security scope, a PR template and Dependabot configuration.

**Security:** built with tokio 1.54.1, which fixes RUSTSEC-2026-0384 (a race in `tokio::time::Interval`; ClawTank doesn't use it directly).

### Phase 9 — Agent API and MCP (2026-10-21)
- A local Agent API lets AI agents on the Mac take screenshots, click, type, press shortcuts, read the cursor and frontmost app, open apps, and create or remove virtual displays (docs/agent-api.md, ADR-023).
  - Off by default. Loopback only, with per-agent tokens (only hashes stored).
  - Browser requests are refused, and bad tokens are throttled.
- `clawtank-mcp`, an MCP server over stdio bundled in the app, so Claude Code and other MCP clients can drive the Mac. Coordinates are in screenshot pixels.
- While an agent acts, a badge with Stop appears on every display, and the menu-bar icon and menu show it. Every agent request is in the connection log. A person using the Mac over RDP always wins: agent input is refused for 3 s after their input.
- Settings → Agents: on/off, port, create and revoke tokens, and the MCP setup command.

### Phase 8 — Secure remote access (2026-10-21)
- Remote access from anywhere via Tailscale, with no port forwarding and nothing exposed publicly (ADR-022). ClawTank detects Tailscale and shows the MagicDNS name or IP to connect to: "Copy Remote Address" in the menu, a new Settings → Remote Access tab with a guided flow, and a "From anywhere" tab in the connect guide.
- Shows whether "Wake for network access" is on, and how to turn it on. New guide: docs/remote-access.md (Tailscale setup, Wake-on-LAN, why not port-forward).

### Phase 7 — Files and quality (2026-10-21)
- Copy and paste files and folders both ways over the clipboard. Client → Mac lands in ~/Downloads/ClawTank and is put on the pasteboard for Finder; Mac → client serves Finder copies.
  - Paths are re-sanitized, and free disk space is checked first.
  - Measured live with a 1 GiB folder: 207 MB/s in, 244 MB/s out (loopback), with identical SHA-256.
- IronRDP #2148 patched in the vendored server, so clipboard lock and file timeouts are now driven.
- Adaptive bitrate from EGFX frame acks (send→ack latency, frames in flight, skips). The menu shows rtt and the target rate.
- "Sharp text" preset renamed "High quality": measurement showed bit rate doesn't sharpen text (ADR-021).
- Deferred: multi-monitor (ADR-019) and AVC444 (ADR-021). Both are maintainer decisions backed by the findings above.
- CI: the FreeRDP smoke test now stops the client process itself.

### Phase 6 — Audio and clipboard (2026-10-21)
- System audio goes to the client over RDPSND: 16-bit PCM stereo at 48 or 44.1 kHz, captured with ScreenCaptureKit, excluding ClawTank's own sound. Silence isn't sent, and there's an optional local mute during sessions.
- Two-way clipboard over CLIPRDR: plain text (UTF-16, CRLF), Rich Text Format, HTML (CF_HTML) and images (PNG and CF_DIB). The client's formats are fetched in full when it copies, then written to the pasteboard together, with no echo loops.
- Settings toggles for audio, local mute and clipboard.
- Tests: Rust end-to-end audio and clipboard in both directions; Swift conversion tests. Live: system audio reaches the client; silence measures 0 kbit/s.

### Phase 5 — Polished app (2026-10-21)
- First-run setup window: what ClawTank does, Screen Recording and Accessibility (detected live), choosing a password, and how to connect from Windows, Mac, iPad/iPhone and Linux.
- Menu shows the connected client (address, since when, display, live stats) with Disconnect, plus Start/Stop sharing, Settings, Connection Log, Setup Guide and Export Diagnostics.
- Settings:
  - start at login; keep awake while connected (default on)
  - Ctrl↔⌘ swap; stats overlay
  - display mode, max fps and quality preset
  - password change with strength rules
  - LAN-only (with a warning before turning it off), allowlist of IPs/CIDRs, port
- Security:
  - 5 failed logins in 5 minutes lock the IP out for 5 minutes, enforced before TLS
  - refusal reasons are reported
  - the password changes live without a restart
- Connection log (audit) of every attempt, rotated at 1 MB, file mode 0600. Diagnostics export (.zip) never reads secrets.
- Locked-screen detection with a menu notice (ADR-018).

### Phase 4 — Virtual display and headless (2026-10-21)
- Virtual display at the client's exact pixel size (Retina/HiDPI when the client is scaled ≥150% or sends a Retina-sized desktop), via the private `CGVirtualDisplay` behind `VirtualDisplayProvider`, with fallback to the physical display.
- Display setting:
  - Automatic: virtual when headless, physical otherwise.
  - Virtual.
  - Physical.
- Live resize over Display Control. The virtual display is reconfigured in place (recreated for Retina→1x), and capture and encoding restart on a serialized chain. Frames for the old size are refused.
- The virtual display is removed at disconnect and dies with the process, so a crash can't leave one behind.
- Tests:
  - Rust resize end-to-end.
  - DisplayService with a fake provider.
  - Opt-in real virtual-display test.
  - `probe --resize-demo`: 172 ms from resize request to first new-size frame.

### Phase 3 — Input (2026-10-21)
- Keyboard: positional scancode map (so Mac input sources decide the layout), all modifiers, Caps Lock, auto-repeat, F1–F20, navigation and keypad, ISO/JIS keys, media keys, and Unicode events including surrogate pairs. Optional Ctrl↔⌘ swap in the menu.
- Mouse: absolute and relative motion mapped through the same aspect-fit rect used for capture; left, right, middle, back and forward buttons; drags; double and triple clicks; smooth vertical and horizontal pixel scrolling.
- Held keys and buttons are released when a session ends.
- Client-side cursor: the Mac's current cursor shape is sent to the client (≤32 px, only on change) and no longer drawn into the video.
- Accessibility is requested on the first session.
- Vendored `ironrdp-server` 0.13.0 with two IronRDP-master fixes: mouse button/wheel mapping and the pointer AND mask (ADR-017).
- Tests: input and cursor end-to-end in Rust; Swift key map, coordinate mapping, injector and cursor tests; live input test against the app (docs/testing.md).

### Phase 2 — Live video (2026-10-21)
- Main display streamed as H.264 over EGFX AVC420. The pipeline is ScreenCaptureKit (IOSurface NV12) → VideoToolbox (hardware, low-latency rtvc, no B-frames) → Annex-B → IronRDP graphics pipeline. Backpressure is checked before encoding, and any refused frame forces an IDR.
- Only changed frames are captured or encoded. The coded size is 16-aligned, with the region rect cropping to the desktop.
- Menu shows live fps, bitrate and encode time; there's an optional stats overlay drawn into the video.
- Screen Recording permission is requested when the first video session starts. The dev signing identity (`make dev-signing`) keeps grants across rebuilds.
- Tests:
  - EGFX end-to-end in Rust (byte-exact AVC420 delivery, keyframe rule, ResetGraphics, VideoStop).
  - Encoder tests (Annex-B, SPS/PPS on IDR, forced IDR).
  - `make bench`.
  - `probe --egfx` measures the live app.
- Measured: 57–58 fps during motion, 7–8% CPU, first frame in about 0.4–0.6 s (see docs/testing.md).
- ADR-014…016.

### Phase 1 — First connection (2026-10-21)
- RDP server in the app: TLS + NLA (CredSSP/NTLM) on port 3389, LAN-only peer filter, and a static colour-bar test frame sized to the client's desktop.
- TLS identity: self-signed RSA-2048 generated in Rust (rcgen + aws-lc-rs), persisted (see below), and its SHA-256 fingerprint shown in the menu. The NLA password is randomly generated and persisted the same way.
- Menu shows status, address, username, Copy Password, fingerprint, Start/Stop. Core logs go to the unified log (`dev.clawtank.ClawTank`, category `core`).
- FFI: `ct_server_start/stop/port`, `ct_generate_tls_identity`, `ct_tls_fingerprint_sha256`, `ct_set_log_callback`, buffer/string free.
- Tests:
  - Rust end-to-end NLA connect with IronRDP's client: verifies the decoded frame, wrong-password refusal, and stop releasing the port.
  - Swift tests for the FFI server lifecycle and the security service.
  - FreeRDP smoke test (`tests/freerdp-smoke.sh`, CI job on Ubuntu).
- Build: `MACOSX_DEPLOYMENT_TARGET=14.0` for cargo (aws-lc C objects were targeting the SDK version); smaller dev debug info; MSRV unchanged (1.88).
- Secrets: Keychain for team-signed builds; owner-only file store for ad-hoc dev builds, so rebuilds don't trigger login-keychain password prompts (ADR-013).
- ADR-009…013; IronRDP research corrected (master vs 0.13.0).

### Phase 0 — Research and foundations (2026-10-21)
- Research: IronRDP server/EGFX/channel maturity (`docs/research/ironrdp.md`) and a CGVirtualDisplay spike (`docs/research/virtual-display.md`).
- ADR-001…008 in `docs/decisions.md`: Rust + Swift, C ABI via cbindgen, app password for NLA, isolated private virtual-display API, macOS 14 minimum, XcodeGen, host-arch builds, audited acceptance of RUSTSEC-2023-0071 (MSRV raised to Rust 1.88 for the `time` fix).
- Scaffold: `clawtank-core` Rust staticlib (pins `ironrdp-server =0.13.0`), SwiftUI menu-bar app linked to it, Makefile (`build`/`test`/`lint`/`package`), GitHub Actions CI, licenses and community docs.
