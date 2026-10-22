# Beta testing guide (0.9)

Thank you for testing ClawTank. Automated tests cover the protocol, security, clipboard, file transfer and agent API. Every CI run also checks a real FreeRDP client. What still needs checking is **real clients on real networks**, done by people who haven't seen ClawTank before.

Work through the sections that fit your setup. Each one takes 5–15 minutes. Report every result, **passes included**, with the [Beta test report](https://github.com/HMAKT99/ClawTank/issues/new?template=beta_report.yml) issue form. One report per section is ideal.

## Before you start

**You need:**
- A Mac with Apple silicon running macOS 14 or later. This is the host.
- A client device, one or more of:
  - a Windows PC (Remote Desktop Connection, `mstsc`, or Windows App)
  - another Mac, iPad or iPhone ([Windows App](https://apps.apple.com/app/windows-app/id1295203466))
  - Android (Microsoft's RDP app)
  - Linux (FreeRDP 3)

**Note for every report:**
- Mac model, and macOS version (Apple menu → About This Mac)
- client app and version, and client OS
- network: same Wi-Fi, Ethernet, mixed, or Tailscale
- whether the Mac has a monitor attached or is headless

**If something fails:**
1. Choose **ClawTank menu → Export Diagnostics…** and attach the zip. It contains no passwords or keys.
2. Include the time it happened. **Connection Log…** in the menu helps you find it.
3. Add a screenshot if something looks wrong.

**Already known, so please don't report these:**
- The "Open Anyway" step, because the build isn't notarized.
- One monitor per session.
- No AVC444 (full-colour) mode.
- A locked Mac shows only the wallpaper.
- No automatic updates.

## 1. Install (most important)
Follow only the [README's Install section](../README.md#install). Don't use any other help.
1. Download the DMG from [Releases](https://github.com/HMAKT99/ClawTank/releases). Check it: run `shasum -a 256 ~/Downloads/ClawTank-*.dmg` and compare the result with `SHA256SUMS`.
2. Drag it to Applications and open it. Use **Open Anyway** when macOS blocks it.
3. Complete setup: Screen Recording, Accessibility, password.

**Expected:** the menu-bar icon appears, setup completes, and the menu says **Ready — connect to …**.
**Report:** any step where the README was unclear, wrong or missing something.

## 2. First connection
1. Connect using the client guide for your device in the [README](../README.md#connect).
2. Check that the certificate fingerprint matches the one in **Setup Guide…**.
3. Try a wrong password once.

**Expected:**
- The desktop appears within a few seconds.
- The menu shows **Connected: <ip>**.
- The wrong password is refused, and the Connection Log shows the failed login.
- When you close the client, the menu returns to **Ready**.

## 3. Picture and smoothness
- Drag windows around, scroll a long web page, and play a video.
- Turn on **Show Stats Overlay** in the menu and note the fps and round-trip time.
- Resize the client window, or rotate an iPad.
- On a Mac or Retina client, try the "Retina" / "Optimize for Retina" option.

**Expected:**
- Motion is smooth (close to 60 fps on a good network) and text is crisp.
- The desktop resizes to the new window size within about a second.

## 4. Keyboard and mouse
- Type in a text editor, using your usual keyboard layout (set the same layout on the Mac).
- Try shortcuts: ⌘C, ⌘V, ⌘Tab, ⌘Space. On Windows, the Windows key acts as ⌘; there's also an option to swap Ctrl and ⌘ in Settings → General.
- Try a right click, a middle click, the back/forward buttons, and trackpad scrolling.

**Expected:** characters and shortcuts behave as they would at the Mac. Clicks land under the cursor, and the cursor shape changes over text and links.

## 5. Sound, clipboard, files
- **Sound:** play a video and check the sound is in sync. Then turn on **Mute this Mac while connected**: the Mac should go quiet while the client keeps playing.
- **Clipboard:** copy and paste in both directions:
  - plain text
  - formatted text (TextEdit ↔ Word/WordPad)
  - a web page selection (Safari ↔ Edge/Chrome)
  - an image (Preview ↔ Paint/Photos)
- **Files:** copy a folder in Explorer and paste it in Finder, and the reverse. Also try one large file (over 1 GB). Files sent to the Mac land in `~/Downloads/ClawTank`.

## 6. Headless Mac mini (if you have one)
With no monitor or dummy plug attached and Display set to **Automatic**, connect from a laptop.

**Expected:** a desktop at the client's own resolution. On a Retina client it's sharp at 2×.

## 7. Away from home (optional)
- **Tailscale:** follow [remote-access.md](remote-access.md). Connect over mobile data, with Wi-Fi off on the client.
- **Weak Wi-Fi:** move away from the router while connected.

**Expected:** with Tailscale, the session works with no port forwarding. On weak Wi-Fi the menu shows **(congested)**, the bit rate drops, and the session recovers when the signal improves.

## 8. Security spot checks
- With **Settings → Security → Only allow connections from my local network** on (the default), a connection from outside your network should fail.
- Five wrong passwords in a row should block your address for 5 minutes. The Connection Log should show it.
- If you find a vulnerability, **don't open a public issue**. See [SECURITY.md](../SECURITY.md).

## 9. Agent API (optional, for AI-agent users)
Follow [agent-api.md](agent-api.md) to connect an MCP client such as Claude Code. Ask it to take a screenshot and open an app.

**Expected:**
- The orange "Agent … is in control" badge appears while the agent acts.
- **Stop** works.
- If you use the mouse over RDP, the agent pauses.
