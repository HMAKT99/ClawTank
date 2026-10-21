# ClawTank

**RDP into your Mac. Open source, hardware-accelerated, no cloud.**

ClawTank is a native RDP server for macOS. Connect from any standard RDP client (Windows App on Mac/iPad/iPhone, `mstsc.exe`, FreeRDP) to your Mac, especially a headless Mac mini, and get a desktop that feels local.

> **Status: Phase 0 (foundations).** Nothing usable yet. See `docs/plans/` and `CHANGELOG.md`.

## Building

Requirements: macOS 14+, Xcode 16+, Rust (stable, via rustup), `brew install xcodegen swiftlint`.

```sh
make build     # Rust core + ClawTank.app (app/build/Build/Products/Release/)
make test      # cargo test + XCTest
make lint      # clippy -D warnings, rustfmt, swiftlint
make package   # unsigned DMG in dist/
```

To work in Xcode: `make core project`, then open `app/ClawTank.xcodeproj`.

### Unsigned builds
Default builds are ad-hoc signed, with no Apple Developer account needed. The first time you open the app, macOS blocks it. Go to **System Settings → Privacy & Security**, scroll to the message about ClawTank, and click **Open Anyway**. Developer ID signing and notarization will be supported via CI secrets (Phase 10).

## License
Apache-2.0. See `LICENSE` and `THIRD_PARTY_NOTICES.md`.
