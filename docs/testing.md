# Manual test checklist

Run the relevant section at the end of the phase noted. Record the date, macOS version, client and result.

## Phase 0
- [ ] `make spike-vd` on this Mac after granting Screen Recording; the PNG shows the virtual desktop.
- [ ] `make spike-vd` on the headless Mac mini (no monitor, no dummy plug).

## Phase 1 — first connection
Get the connection details from the ClawTank menu: **Copy Address**, the username shown there, and **Copy Password**.
- [ ] Windows App (Mac) → Add PC → PC name `127.0.0.1` (same Mac) or `<host>.local` (other device). User account = the menu's username and password. Connect, accept the certificate (compare the SHA-256 with **Copy Certificate Fingerprint**), and see the colour-bar test pattern.
- [ ] While connected, the menu shows **Connected: <ip>** and the menu-bar icon changes.
- [ ] Close the session window. The menu returns to **Ready**.
- [ ] A wrong password fails, and the menu shows **Failed login from <ip>**.
- [ ] (Optional) the same from Windows `mstsc.exe` or another device on the LAN.
- [x] (CI, first run 2026-10-21) FreeRDP 3 on Ubuntu authenticated with NLA, was refused with a wrong password, and connected and received the test frame. The final disconnect check failed only because the script killed the `xvfb-run` wrapper instead of FreeRDP; fixed.
- Automated check against the running app (no GUI client needed):
  `CLAWTANK_PASSWORD="$(cat ~/Library/Application\ Support/ClawTank/secrets/rdp-password.secret)" core/target/debug/examples/probe 127.0.0.1:3389 "$(whoami)"`
  Build it first with `cd core && cargo build --example probe`. It connects with TLS + NLA, verifies the test pattern and saves `probe.bmp`.
  - 2026-10-21, macOS 15.6.1, M2: ✅ loopback (1280×800) and LAN 192.168.1.20 (1512×982) verified; wrong password refused by CredSSP.

## Phase 2 — live video
Automated against the running app (Screen Recording granted to ClawTank):
`CLAWTANK_PASSWORD="$(cat ~/Library/Application\ Support/ClawTank/secrets/rdp-password.secret)" core/target/debug/examples/probe 127.0.0.1:3389 "$(whoami)" 1512x982 --egfx 10`
Set `CLAWTANK_DUMP_H264=path` to save the first access unit, which you can decode to verify.

Results, 2026-10-21, M2 MacBook Air, macOS 15.6.1, loopback, 1512×982 session:
- ✅ First frame 357–586 ms after connect. It starts with SPS, PPS, IDR, and decodes with VideoToolbox (1520×992 coded) to a legible image of the screen.
- ✅ 60 fps motion window (900×600): **57–58 fps** sustained, about 1.0 Mbit/s.
- ✅ ClawTank CPU during motion: **7–8%** of one core (target < 15%).
- ⚠️ Idle: by design no frames are sent for a static screen (ScreenCaptureKit `.idle`). It couldn't be measured strictly here because a terminal spinner kept changing (9 fps, 17 kbit/s with only that). The maintainer should re-check with nothing animating.
- `make bench` (synthetic 2560×1600 @ 60): rtvc low-latency p50 11.0 ms, p95 20.3 ms; ave.avc p50 11.6 ms, p95 37.5 ms (ADR-016).
- [ ] Human: Windows App shows the live desktop, window dragging is smooth, video playback looks right, text is crisp.
- [ ] Human: "Show Stats Overlay" draws fps/bitrate/encode time on the video.
- [ ] Not yet measured: end-to-end input→display latency.

## Phase 3 — input and cursor
Automated live test (it takes over the mouse and keyboard for about 15 s; ask first): a centred test window plus
`probe … 1512x982 --input-demo OUTDIR`. Results, 2026-10-21, M2, macOS 15.6.1, Accessibility granted:
- ✅ Click at the session centre landed at the exact screen centre (735, 478 of 1470×956 pt).
- ✅ Scancodes typed `clawtank`; Shift+1 gave `!`; the Unicode event gave `é`. A Shift flag that leaked onto the Unicode event was found here and fixed.
- ✅ 3 wheel notches gave 3 continuous pixel scrolls (−40 each); the middle click arrived as button 2.
- ✅ Cursor shapes reached the client: arrow 17×24 (hotspot 4,4) and I-beam 9×18 (hotspot 4,9) over text, correct orientation.
- [ ] Human (Windows App / mstsc): type in a non-US layout with the same layout selected on the Mac; ⌘C/⌘V/⌘Tab (Windows key = ⌘ by default, or turn on "Swap Ctrl and ⌘"); trackpad scrolling feel; resize and hand cursors.

## Phase 4 — virtual display and resize
Results, 2026-10-21, M2 MacBook Air, macOS 15.6.1:
- ✅ Opt-in real-display test (`TEST_RUNNER_CLAWTANK_VD_TESTS=1 make test-app`): create 2560×1600 @2× (1280×800 pt), resize to 2880×1800 @2× in place, Retina→1× correctly refused (recreate path), remove, then a second display in the same process works.
- ✅ Live session with Display = Virtual (`probe … 1512x982 --resize-demo 1280x800@100 DIR`): first frame 1.15 s after connect (including display creation) showing the virtual desktop (wallpaper and menu bar only) at exactly 1512×982. Resize to 1280×800 over Display Control: **first new-size frame 172 ms** after the request (target ≈ 1 s). Both keyframes decode. Virtual display gone after disconnect.
- Findings: `CGDisplayCopyDisplayMode` is unreliable for virtual displays (often nil), so we use `CGDisplayBounds`. Retina→1× doesn't apply in place, so we recreate.
- [ ] Human: headless Mac mini (no monitor, no dummy plug) with Display = Automatic. Connect from a 14"/16" MacBook (Windows App, Retina option on) and expect a crisp native-resolution desktop. Resize the client window and expect the desktop to follow within about 1 s.
- [ ] Human: `make spike-vd` on the Mac mini (Phase 0 item).

## Phase 5 — polished app
Automated: 44 Swift tests (audit log, rotation, password policy, settings, password change, diagnostics without secrets) and Rust security end-to-end tests (lockout before TLS, live password change, host disconnect).
Live, 2026-10-21:
- ✅ Connection log on disk recorded a failed login, then connected and disconnected, with time and address. Wording was improved after this run.
- ✅ `make package` produces `dist/ClawTank-0.1.0.dmg` (9.8 MB, app plus /Applications link) with a .sha256.
- ⚠️ Found: with the Mac locked, clients see only the wallpaper (ADR-018). The menu now says so.
- [ ] Human, the acceptance test: on a fresh macOS user account, open the DMG, drag to Applications, open (Open Anyway), follow setup (Screen Recording, Accessibility, password), then connect from Windows App. Target: under 2 minutes.
- [ ] Human: Settings window tabs, the LAN-only warning dialog, Start at login (may need approval in Login Items), Export Diagnostics, Disconnect from the menu, VoiceOver labels.

## Phase 6 — audio and clipboard
Automated: a Rust end-to-end test with IronRDP's RDPSND and CLIPRDR client channels (48 kHz stereo PCM arrives intact; text both ways), plus Swift tests for text, CF_HTML, DIB (24/32-bit, zero alpha), PCM conversion, silence detection and pasteboard serving.
Live, 2026-10-21 (`probe … --audio 5` while `afplay Ping.aiff` played):
- ✅ System audio reached the client: 48 kHz stereo 16-bit, peak 9716 during the ping.
- ✅ Found and fixed: silence was streamed at 1.5 Mbit/s. Pure digital silence is now skipped, so it measures **0 kbit/s**.
- [ ] Human (Windows App / mstsc): YouTube audio plays in sync on the client; "Mute this Mac while connected" silences the Mac's speakers but not the client.
- [ ] Human: copy and paste both ways for plain text, rich text (TextEdit ↔ WordPad/Word), HTML (Safari ↔ Edge), and images (Preview ↔ Paint).

## Phase 7 — file and folder copy
Automated: Rust end-to-end test of files both ways (folders, size query, byte range); an ignored core-only throughput test (`cargo test --release --test file_throughput -- --ignored`) gave **1.2 ms per 1 MiB request, about 811 MB/s**. Swift tests cover path sanitizing (traversal rejected), folder flattening and range serving.
Live, 2026-10-21, loopback, `files_demo` (examples/files_demo.rs) acting as the client:
- ✅ **Client → Mac, 1 GiB folder** (2 × 512 MiB): 4.9 s (207 MB/s). SHA-256 of both files on disk matched what the client served.
- ✅ **Mac → client, 1 GiB folder** (nested folder plus 3 files, copied in Finder via the clipboard): 4.2 s (244 MB/s). All SHA-256 hashes matched the source.
- Found and fixed: relative paths doubled under symlinked folders. File requests are now served off the main thread. (An apparent 23 ms per request turned out to be the demo client's own loop.)
- [ ] Human: mstsc / Windows App: copy a folder in Finder and paste it in Explorer, and the reverse (it lands in ~/Downloads/ClawTank and is put on the clipboard). Large copy on Wi-Fi.
