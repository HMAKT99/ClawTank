# Contributing to ClawTank

Thanks for helping! Before opening a PR:

1. `make lint test` must pass.
2. Keep the FFI boundary narrow (ADR-002). New `extern "C"` functions go in `core/clawtank-core/src/ffi.rs` with tests.
3. Every module starts with a doc comment explaining what it does and why.
4. Significant or hard-to-reverse choices get an ADR in `docs/decisions.md`.

## Clean-room rule
ClawTank is built only from Microsoft's published RDP specifications, Apple's public documentation, and open-source code whose license permits reuse (credited in `THIRD_PARTY_NOTICES.md`). **Do not** contribute anything derived from decompiling, disassembling or otherwise inspecting closed-source remote-desktop products, and don't copy their code, assets, text, UI or branding.

By contributing you agree your work is licensed under Apache-2.0.
