# Changelog

All notable changes are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
