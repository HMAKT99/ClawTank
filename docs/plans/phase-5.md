# Phase 5 — Polished app

## Goals
A fresh Mac goes from DMG to first connection in under 2 minutes by following only the onboarding.

## Scope
### Core (Rust)
- **Failed-login lockout:** 5 failed logins from one IP within 5 minutes block that IP for 5 minutes, enforced before TLS in the accept loop. Lockouts are reported to the host.
- **Refusal reasons:** `Rejected` events carry why the peer was refused: `lan-only`, `allowlist` or `locked-out`.
- **Allowlist:** optional list of IPs/CIDRs; when set, only those may connect (still subject to LAN-only unless that's off).
- **Disconnect the current client:** `ct_server_disconnect_client` sends `ServerEvent::Quit` to the session; the server keeps listening.
- **Change the password live:** `ct_server_set_credentials` goes through `ServerEvent::SetCredentials`, with no restart.

### App services (Swift)
- **`AuditLog`:** JSON lines in `~/Library/Application Support/ClawTank/audit.log` with time, peer IP, user and outcome. It covers connected, disconnected, failed login, refused (with reason) and locked out. Rotates at 1 MB. Never stores secrets.
- **`PowerAssertions`:** while a client is connected, prevents idle system and display sleep (`IOPMAssertionCreateWithName`). Optional setting, default on.
- **`LoginItem`:** `SMAppService.mainApp` register/unregister with live status.
- **`AppSettings`:** a UserDefaults-backed model:
  - display mode, max fps (30/60), quality preset (Balanced / Sharp text / Low bandwidth → bitrate factor), Ctrl↔⌘ swap
  - port, LAN-only, allowlist
  - keep awake, start at login, stats overlay
  - Network changes restart the server.
- **`Diagnostics`:** exports a .zip with this process's recent unified-log entries (`OSLogStore`), the settings with secrets redacted, the audit log, the app/core/macOS versions and the display list. Passwords and keys are never included.
- **Password:** user-chosen during onboarding and in Settings. Minimum 12 characters; the strength meter rejects very common or repetitive passwords. The random password stays as the initial default.

### UI
- **Onboarding window** (first launch, or from the menu):
  1. Welcome
  2. Screen Recording: deep link, detects the grant live
  3. Accessibility: same
  4. Password
  5. Done: address, copy buttons, fingerprint, and tabs for *How to connect* from Windows, Mac, iPad/iPhone and Linux
- **Menu:**
  - status
  - the connected session: IP, resolution, fps, bitrate, encode ms
  - Disconnect, Start/Stop sharing
  - Copy address/password
  - Settings…, Connection Log…, Setup Guide…, Export Diagnostics…, Quit
- **Settings window:** General / Display & Quality / Security tabs. The LAN-only switch shows a clear warning before allowing other networks.
- **Connection Log window:** table of audit entries, newest first, with a Reveal in Finder button.
- Accessibility: every control labelled for VoiceOver, keyboard navigable, dark mode via system colours.

## Not in this phase
Audio, clipboard and file transfer settings arrive with their features (Phases 6–7); no placeholder toggles.

## Tests
- **Rust:** lockout state machine; allowlist matching (IPv4/IPv6 CIDR); end-to-end showing that 5 bad passwords lock out the IP, the next connection is refused before TLS, a good password still works from another IP (or after expiry, simulated), and disconnect-client keeps the listener up.
- **Swift:**
  - audit log append, read, rotate and redaction
  - password strength rules
  - settings persistence, and quality presets mapping to bitrate
  - diagnostics bundle contents with no secrets inside
  - power assertion lifecycle via an injected fake
- **Manual:** the onboarding flow, from DMG to connected in under 2 minutes, on a fresh macOS user account.
