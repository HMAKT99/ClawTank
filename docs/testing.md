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
- [ ] (CI) `tests/freerdp-smoke.sh` passes in the `freerdp-interop` job.
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
- [ ] Not yet measured: end-to-end input→display latency (needs input, Phase 3).
