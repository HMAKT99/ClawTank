# Phase 1 — First connection

## Goals
Run the IronRDP server inside ClawTank.app with TLS + NLA. A stock client (Windows App, FreeRDP) connects, authenticates, sees a static test frame, and disconnects cleanly. An integration test proves it in CI.

## Design

### Rust (`core/clawtank-core`)
- `server.rs`: owns a tokio runtime on a dedicated thread and builds `RdpServer` with `with_hybrid` (TLS + CredSSP/NTLM). The fixed username/password are set with `set_credentials`. To stop, it sends `ServerEvent::Quit` and joins the thread.
- `tls.rs`:
  - Generates a self-signed RSA-2048 identity with `rcgen` (aws-lc-rs backend, already in the dependency tree). RSA is the most compatible choice for stock clients.
  - Builds the rustls `TlsAcceptor` from in-memory DER. We don't use IronRDP's `helper` module, because it enables `KeyLogFile`.
  - Extracts the CredSSP public key with `x509-cert`.
- `test_pattern.rs`: draws a deterministic test frame (colour bars, a gradient and a checker block) at the client's requested size, capped at 4096×2160. `display.rs` sends it once as a `DisplayUpdate::Bitmap`, then idles. That's enough for the bitmap/RemoteFX path IronRDP picks.
- `input.rs`: logs keyboard/mouse events at trace level and counts them. Injection is Phase 3.
- `access.rs` (`ConnectionHandler`):
  - `on_accept` enforces **LAN-only**: loopback, RFC 1918, link-local, CGNAT 100.64/10 (Tailscale), and IPv6 ULA/link-local are allowed. Anything else is rejected and reported to Swift.
  - The connect/disconnect hooks emit events.
- `ffi.rs` grows:
  - `ct_generate_tls_identity`, `ct_buffer_free`, `ct_tls_fingerprint_sha256`
  - `ct_server_start(config, event_cb, ctx)` → `CtServer*`, `ct_server_stop(CtServer*)`
  - `ct_set_log_callback`, which routes `tracing` output to Swift's `os.Logger`

  Events are `#[repr(C)]` kind + a UTF-8 detail string, and callbacks run on the Rust thread. Every pointer is null-checked, and failures return a `CtStatus`.
- `examples/testserver.rs`: a headless server binary (no Swift) used by the integration tests and for debugging.

### Swift (`app/`)
- `SecurityService`:
  - Loads or creates the TLS identity and the RDP password as Keychain generic-password items (service `dev.clawtank.ClawTank`).
  - For Phase 1 the password is generated randomly (20 chars). The menu shows it with a Copy button. Phase 5 onboarding replaces this with a user-chosen password.
  - The username is `NSUserName()`.
- `ServerController` (`@MainActor`, `ObservableObject`): starts the server at launch on port 3389 and maps core events to UI state (status, connected clients).
- The menu shows:
  - status (Stopped / Listening on host:3389 / Connected: ip)
  - username, Copy password, TLS fingerprint
  - Start/Stop, Quit

### Tests
- **Rust integration test** (`tests/connect.rs`):
  - Starts the server on an ephemeral port. Connects with IronRDP's client stack (`ironrdp-connector` + `ironrdp-session`, NLA on), receives frames, and asserts known test-pattern pixels.
  - Checks that a wrong password is rejected.
  - Checks that `ct_server_stop` returns promptly and the port is released.
- **Unit tests**: LAN-only address classification, test-pattern determinism, TLS identity round-trip and fingerprint, and FFI null-safety.
- **FreeRDP (independent implementation)**: `tests/freerdp-smoke.sh` runs `xfreerdp3 /auth-only` for NLA, then a timed full connect under `xvfb-run`. The script asserts on the test server's log ("bitmap sent", "client disconnected"). It runs in an Ubuntu CI job, which works because the core is pure Rust.

## Risks
- Ad-hoc-signed rebuilds change the code signature, so Keychain may prompt "ClawTank wants to access…" after each rebuild. Clicking **Always Allow** clears it until the next rebuild. Acceptable for development; signed releases won't do this.
- The macOS firewall may ask to allow incoming connections. That's a human checkpoint.
- Stock-client quirks in IronRDP's bitmap path (cf. upstream #2122 for Jump Desktop). Mitigation: test with Windows App and FreeRDP.

## Verification
- `make lint test` green, including the Rust connect test.
- The app launches and the menu shows "Listening on <host>.local:3389".
- **Human:**
  1. Connect from Windows App on this Mac to `127.0.0.1` (or `<host>.local`) with the menu's username and password, and see the test pattern.
  2. Close the window; the menu returns to Listening.
  3. Optionally repeat from another device on the LAN.
