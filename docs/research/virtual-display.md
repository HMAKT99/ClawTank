# Virtual display spike (Phase 0)

Date: 2026-10-21 · Host: MacBook Air M2, macOS 15.6.1 (24G90), built-in 2560×1664 display · Spike: `spikes/virtual-display/` (`make spike-vd`)

## What the spike does
1. Feature-detects `CGVirtualDisplay` with `NSClassFromString`.
2. Creates a display with descriptor `maxPixels 2560×1600`, 302×189 mm, and settings `hiDPI = 1`, one mode `1280×800 @ 60 Hz`.
3. Waits for CoreGraphics to report it, then finds it in `SCShareableContent` and captures one frame with `SCScreenshotManager` at 2560×1600 → PNG.
4. Releases the object and verifies the display leaves `CGGetOnlineDisplayList`.

## Results

| Step | Result |
|---|---|
| Class present on macOS 15.6.1 | ✅ |
| Create + apply settings | ✅ 150–360 ms (first run slower) |
| Reported mode | ✅ **1280×800 points, 2560×1600 pixels, 60 Hz** (HiDPI works) |
| Visible to ScreenCaptureKit + capture | ⏳ blocked on the Screen Recording grant for the terminal. Re-run pending. |
| Teardown | ✅ gone from the online list **~270 ms** after release |

## Lessons learned (feed into `VirtualDisplayProvider`)
- **HiDPI semantics:** the mode is given in *points*, and `maxPixelsWide/High` must be the *pixel* size (2× the points). For a client asking for W×H pixels at scale 2, create mode W/2×H/2 with max pixels W×H.
- **Teardown is asynchronous** and only happens once the last reference is released. Wrap creation in `autoreleasepool` so no autoreleased reference keeps the display alive. Verify teardown with `CGGetOnlineDisplayList`: `CGDisplayIsOnline`/`CGDisplayCopyDisplayMode` on the old ID kept returning stale "online" data.
- Display IDs increment per creation (3, 4, 5, 6…), so never cache IDs across sessions.
- The display dies with the process. A crash therefore can't leak a display, but the launch-time sweep is still worth keeping in case the window-server state lingers.

## Not yet verified
- Capture contents (pending the permission grant).
- **Headless Mac mini with no monitor or dummy plug.** This host has a built-in panel. The maintainer needs to run `make spike-vd` on the Mac mini (Phase 4 checklist).
- Behaviour on macOS 14 and 26.
- Live mode change (calling `apply` again with a new mode) for Display Control resize. Planned for the Phase 4 plan.
