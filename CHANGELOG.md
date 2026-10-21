# Changelog

All notable changes are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
