# Security Policy

ClawTank gives remote control of a Mac, so we treat security bugs as top priority.

## Reporting a vulnerability
**Do not open a public issue.** Use GitHub's private vulnerability reporting (Security tab → *Report a vulnerability*) on the project repository. Include the affected version, the macOS version, reproduction steps and the impact.

We aim to acknowledge reports within 3 business days and to ship a fix or mitigation within 30 days for high-severity issues. We'll credit reporters unless you prefer otherwise.

## Supported versions
Only the latest release receives security fixes until 1.0.

## Security defaults
TLS always, NLA required, LAN-only bind by default, failed-login lockout, local audit log, no telemetry. See `docs/decisions.md` (ADR-003).
