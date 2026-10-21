# Vendored crates

| Crate | Upstream | Why | Remove when |
|---|---|---|---|
| `ironrdp-server` 0.13.0 | [Devolutions/IronRDP](https://github.com/Devolutions/IronRDP) (Apache-2.0 OR MIT) | (1) Mouse PDU mapping in `src/handler.rs`: horizontal wheel, middle button, X1/X2 buttons. (2) AND mask derived from alpha for 32 bpp pointers (`src/encoder/pointer_mask.rs`, copied from master), without which Windows App for macOS ignores our cursor shapes. (3) `ServerEvent::CliprdrDriveTimeouts` (#2148): the clipboard lock/file timeouts are driven by a host timer. All mirror IronRDP master; search for `ClawTank patch`. | A published `ironrdp-server` release contains the fix (ADR-017) |

Only the lines marked `ClawTank patch` differ from the crates.io release. `diff -r` against `~/.cargo/registry/src/*/ironrdp-server-0.13.0` to verify.
