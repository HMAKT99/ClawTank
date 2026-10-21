# Manual test checklist

Run the relevant section at the end of the phase noted. Record the date, macOS version, client and result.

## Phase 0
- [ ] `make spike-vd` on this Mac after granting Screen Recording; the PNG shows the virtual desktop.
- [ ] `make spike-vd` on the headless Mac mini (no monitor, no dummy plug).

## Phase 1 — first connection
Get the connection details from the ClawTank menu: **Copy Address**, the username shown there, and **Copy Password**.
- [ ] Windows App (Mac) → Add PC → PC name `127.0.0.1` (same Mac) or `<host>.local` (other device). User account = the menu's username and password. Connect, accept the certificate (compare the SHA-256 with **Copy Certificate Fingerprint**), and see the colour-bar test pattern.
- [ ] While connected, the menu shows **Connected: <ip>** and the menu-bar icon changes.
- [ ] Close the session window. The menu returns to **Ready**.
- [ ] A wrong password fails, and the menu shows **Failed login from <ip>**.
- [ ] (Optional) the same from Windows `mstsc.exe` or another device on the LAN.
- [ ] (CI) `tests/freerdp-smoke.sh` passes in the `freerdp-interop` job.

## Phase 2+
Filled in as phases land.
