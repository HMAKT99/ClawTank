# Changelog

All notable changes are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Phase 0 — Research and foundations (2026-10-21)
- Research: IronRDP server/EGFX/channel maturity (`docs/research/ironrdp.md`) and a CGVirtualDisplay spike (`docs/research/virtual-display.md`).
- ADR-001…008 in `docs/decisions.md`: Rust + Swift, C ABI via cbindgen, app password for NLA, isolated private virtual-display API, macOS 14 minimum, XcodeGen, host-arch builds, audited acceptance of RUSTSEC-2023-0071 (MSRV raised to Rust 1.88 for the `time` fix).
- Scaffold: `clawtank-core` Rust staticlib (pins `ironrdp-server =0.13.0`), SwiftUI menu-bar app linked to it, Makefile (`build`/`test`/`lint`/`package`), GitHub Actions CI, licenses and community docs.
