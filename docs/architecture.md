# Architecture

```
ClawTank.app (Swift, SwiftUI menu-bar app)
 ├─ SessionManager      lifecycle of each client session
 ├─ DisplayService      VirtualDisplayProvider (CGVirtualDisplay) + physical fallback
 ├─ CaptureService      ScreenCaptureKit stream per display, dirty rects
 ├─ EncodeService       VideoToolbox H.264 (AVC420 → AVC444), low-latency
 ├─ InputService        CGEvent injection, scancode → keycode, Ctrl↔⌘
 ├─ CursorService       cursor shapes → client-side rendering
 ├─ AudioService        system audio → RDPSND
 ├─ ClipboardService    NSPasteboard ↔ CLIPRDR
 ├─ SecurityService     TLS cert + app password (Keychain), allowlist, audit log
 └─ CoreBridge ──C ABI──► libclawtank_core.a (Rust)
                            └─ ironrdp-server 0.13 (TLS, NLA, EGFX, channels)
```

**Data flow (target, Phase 2+):** `SCStream` → IOSurface-backed `CVPixelBuffer` → `VTCompressionSession` (Annex-B) → FFI (pointer + length, no copy) → `GraphicsPipelineServer::send_avc420_frame` → client. Input travels the reverse way as small `#[repr(C)]` events polled or called back into Swift.

**Boundary rules:** see ADR-002 in `decisions.md`. Rust never calls macOS APIs; Swift never parses RDP.

**Repo map:** `core/` Rust workspace · `app/` XcodeGen project (`project.yml`) · `spikes/` throwaway experiments · `docs/` plans, research, ADRs · `scripts/` packaging/signing · `tests/` integration + bench (from Phase 1).
