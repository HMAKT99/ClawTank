# Contributing to ClawTank

Thanks for your interest! Bug reports, test reports, documentation fixes and code are all welcome. By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

- **Found a bug?** Open a [bug report](https://github.com/HMAKT99/ClawTank/issues/new?template=bug_report.yml) and attach **Export Diagnostics…** from the menu.
- **Testing the beta?** Follow [docs/beta-testing.md](docs/beta-testing.md) and file a [beta test report](https://github.com/HMAKT99/ClawTank/issues/new?template=beta_report.yml).
- **Security issue?** Don't open a public issue. See [SECURITY.md](SECURITY.md).
- **Bigger change?** Open an issue first, so we can agree on the approach before you invest time.

## Clean-room rule

ClawTank is built only from:
- Microsoft's published RDP specifications ([MS-RDPBCGR], [MS-RDPEGFX], …)
- Apple's public documentation
- open-source code whose license permits reuse, credited in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)

**Do not** contribute anything derived from decompiling, disassembling or otherwise inspecting closed-source remote-desktop products. Don't copy their code, assets, text, UI or branding. If you've studied such a product's internals, say so in your PR so we can decide together.

## Development setup

Requirements: an Apple silicon Mac with macOS 14+, Xcode 16+, Rust stable via [rustup](https://rustup.rs), and `brew install xcodegen swiftlint`.

```sh
git clone https://github.com/HMAKT99/ClawTank.git && cd ClawTank
make dev-signing   # once: a local code-signing identity, so macOS permissions survive rebuilds
make build         # Rust core + app → app/build/Build/Products/Release/ClawTank.app
make test          # cargo test + XCTest
make lint          # clippy -D warnings, rustfmt --check, swiftlint --strict
```

For Xcode, run `make core project` and open `app/ClawTank.xcodeproj`. The project is generated from `app/project.yml` by XcodeGen, so edit that file, not the `.xcodeproj`.

| Target | What it does |
|---|---|
| `make test-core` / `make test-app` | Only the Rust or only the Swift tests |
| `make bench` | Encoder benchmark (2560×1600 @ 60 fps) |
| `make audit` | `cargo audit` of Rust dependencies |
| `make package` / `make release` | Unsigned DMG / versioned release artifacts (see [docs/releasing.md](docs/releasing.md)) |

**README screenshots** are rendered from the real views with sample data: `TEST_RUNNER_CLAWTANK_SCREENSHOTS=$PWD/docs/media make test-app`.

**Testing against the running app without a GUI client.** `core/clawtank-core/examples/probe.rs` connects like a real client (TLS and NLA), and can measure video, input, resize and audio. The usage is in [docs/testing.md](docs/testing.md). Some live tests take over the mouse and keyboard, and the real-display tests are opt-in (`TEST_RUNNER_CLAWTANK_VD_TESTS=1`).

## Where things go

Read [docs/architecture.md](docs/architecture.md) first. The key rule: **Rust never calls macOS APIs, and Swift never parses RDP.**

- **Protocol work** goes in `core/clawtank-core/src/`, with an end-to-end test in `core/clawtank-core/tests/`. Those tests use IronRDP's client.
- **macOS work** goes in `app/ClawTank/<Area>/`, with XCTest in `app/ClawTankTests/`. Inject fakes for system APIs.
- **New C ABI functions** go only in `core/clawtank-core/src/ffi.rs`, with a Swift wrapper in `CoreBridge.swift` and tests. Keep the boundary narrow (ADR-002).
- **Significant or hard-to-reverse choices** get an ADR in [docs/decisions.md](docs/decisions.md).

## Conventions

- Every source file starts with a comment explaining what it does and why.
- Swift 6 strict concurrency, with no warnings. Rust with `clippy -D warnings`.
- No new dependencies without a reason in the PR. Licenses must be compatible with Apache-2.0, and they go in THIRD_PARTY_NOTICES.md.
- Never log secrets. Audit-log entries describe actions, not content (for example, the character count of typed text, not the text).
- Commits: an imperative subject line, prefixed by area when that helps (`core:`, `app:`, `docs:`). Keep changes focused.
- User-visible changes go in [CHANGELOG.md](CHANGELOG.md) under *Unreleased*.

## Pull requests

1. Fork, create a branch, and make your change with tests.
2. `make lint test` passes locally. CI runs it on macOS, plus a FreeRDP interop test and `cargo audit`.
3. Fill in the PR template, including how you tested it (client, macOS version).

By contributing, you agree that your work is licensed under [Apache-2.0](LICENSE).

[MS-RDPBCGR]: https://learn.microsoft.com/openspecs/windows_protocols/ms-rdpbcgr/
[MS-RDPEGFX]: https://learn.microsoft.com/openspecs/windows_protocols/ms-rdpegfx/
