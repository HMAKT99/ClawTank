# Security Policy

ClawTank gives remote control of a Mac, so security bugs are our top priority.

## Reporting a vulnerability

**Please don't open a public issue.** Report privately through [GitHub private vulnerability reporting](https://github.com/HMAKT99/ClawTank/security/advisories/new) (Security tab → *Report a vulnerability*). Include:
- the ClawTank version and macOS version
- the client used, if relevant
- steps to reproduce, and the impact

We aim to acknowledge reports within 3 business days, and to ship a fix or mitigation within 30 days for high-severity issues. We'll credit you in the advisory unless you'd rather we didn't.

## Supported versions

| Version | Supported |
|---|---|
| Latest 0.9.x beta | ✅ |
| Older | ❌ |

Until 1.0, only the latest release gets security fixes.

## In scope

- **Getting in without the password:**
  - bypassing authentication, NLA or the lockout
  - connecting from a non-local address while "Only allow connections from my local network" is on
- **Agent API:**
  - reaching it from another machine or from a web page (CSRF, DNS rebinding)
  - using it without a valid token
- **Leaks:**
  - leaking the RDP password, TLS private key or agent tokens (in logs, diagnostics, files, or across the C ABI)
  - memory-safety bugs in the core or at the FFI boundary that a remote client can trigger
  - clipboard or file-transfer bugs that read or write files outside the intended locations

## Out of scope

- Weaknesses that come from the RDP protocol itself. For example, NTLM inside CredSSP can be attacked offline if an attacker captures a login exchange (ADR-003). This is why ClawTank is LAN-only by default and enforces a minimum password strength.
- Attacks that need an admin account or physical access on the host Mac.
- The "Open Anyway" step for unsigned beta builds.

## Security defaults

- TLS is always on and NLA is required.
- ClawTank uses a dedicated password, separate from your macOS password.
- Only local-network addresses can connect by default, and repeated failed logins lock that address out.
- There's a local audit log, and no telemetry.
- The Agent API is off by default and listens only on loopback, with hashed tokens.

See [docs/architecture.md](docs/architecture.md#security-model) and [docs/decisions.md](docs/decisions.md) (ADR-003, ADR-023).
