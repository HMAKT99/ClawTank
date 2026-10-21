# Phase 2 — Live video

## Goals
Stream the Mac's main display to the client as H.264 over the Graphics Pipeline (EGFX AVC420):
- Captured with ScreenCaptureKit and encoded with VideoToolbox.
- Up to 60 fps, with near-zero bandwidth and CPU when idle.
- An IDR on refresh requests.
- A stats readout (fps, bitrate, encode time) and an optional overlay drawn into the video.

## Design

### Pipeline (zero-copy on the hot path)
`SCStream` (NV12 `420v`, IOSurface-backed `CVPixelBuffer`, at the client's desktop size) → `VTCompressionSession` (hardware H.264) → AVCC→Annex-B conversion (SPS/PPS prepended on keyframes) → FFI `ct_server_submit_h264(ptr, len, …)` → `GraphicsPipelineServer::send_avc420_frame` → `drain_output` → DVC/SVC messages → `ServerEvent::Egfx` → client.

The only copy is the compressed bitstream crossing into Rust, a few KB to tens of KB per frame. Pixels never touch the CPU.

### Rust (`core/clawtank-core`)
- `gfx.rs`:
  - A `GfxServerFactory` plus `GraphicsPipelineHandler`.
  - `on_ready` creates a surface of the session size, maps it to the output, and emits `CoreEvent::VideoStart { width, height }`.
  - Frame acks feed stats and backpressure.
  - `close` emits `VideoStop`.
- `video.rs`: `VideoSink`, shared with the FFI. `submit_h264(data, keyframe, ts)`:
  1. Locks the handle and checks readiness and backpressure.
  2. Sends the frame and drains the output.
  3. Encodes the DVC messages and posts `ServerEvent::Egfx`.

  If a frame can't be sent, it's dropped and the next frame is **forced to be an IDR**. Dropping a P-frame would otherwise corrupt the decoder's reference chain. `can_accept()` lets Swift skip encoding entirely under backpressure.
- The display handler still sends the static test frame. With EGFX it's only visible until the first video frame. Clients without EGFX keep seeing the test pattern; a bitmap fallback is later work (ADR-014).
- FFI:
  - `ct_server_submit_h264`, `ct_server_video_can_accept`, and stats getters.
  - New event kinds: `VideoStart` (detail `"WxH"`), `VideoStop`, `KeyframeRequested`.

### Swift (`app/`)
- `CaptureService`: an `SCStream` of the main display, scaled (aspect-preserving) to the session size.
  - `minimumFrameInterval` = 1/60 s and `queueDepth` 3.
  - It only forwards `.complete` frames. ScreenCaptureKit emits nothing when the screen is static, so idle costs nothing.
- `EncodeService`: a `VTCompressionSession` configured for low latency:
  - real-time mode, hardware required (Apple silicon), no frame reordering (no B-frames)
  - Main profile, auto level
  - long GOP with on-demand IDR (`kVTEncodeFrameOptionKey_ForceKeyFrame`)
  - average bit rate plus data-rate limits from a quality preset
  - It converts AVCC output to Annex-B, measures encode latency per frame, and runs on a dedicated queue.
- `VideoSession` wires capture → encode → core. It starts on `VideoStart`, stops on `VideoStop` or disconnect, and honours `KeyframeRequested`. It skips encoding while the core reports backpressure.
- `StatsOverlay` (toggle in the menu): Core Image text composited into a pooled pixel buffer, only when enabled. The menu also shows live fps, bitrate and encode ms.

### Dev signing (user decision)
`scripts/dev-signing.sh` creates `~/Library/Keychains/clawtank-dev.keychain-db` with a random password, which is kept in git-ignored `build/dev-signing/`. It holds a self-signed "ClawTank Dev" code-signing identity, and `make app` signs with it. Rebuilds keep the same identity, so Screen Recording is granted once. The login keychain isn't touched (ADR-015).

### Tests and benchmarks
- **Rust unit tests:** handle capability negotiation through `GraphicsPipelineServer`; feed fake H.264 and assert `WireToSurface1` with AVC420; backpressure forces an IDR.
- **Rust e2e:** the shared test client joins DRDYNVC + EGFX (`ironrdp-egfx` client). The test server submits a canned H.264 frame, and the client asserts it receives AVC420 with an Annex-B SPS.
- **Swift unit tests:** the encoder produces Annex-B (start codes, SPS/PPS on keyframes) from synthetic pixel buffers; forced IDR works.
- **`make bench`** (`tests/bench`): encodes N synthetic 2560×1600 moving frames and reports encode ms (p50/p95), bitrate and fps.
- **Probe in EGFX mode against the running app:** counts H.264 frames and bytes while the screen moves versus idle. That gives measured fps and idle bandwidth through the real ScreenCaptureKit → VideoToolbox pipeline.

## Risks
- **Screen Recording grant:** a human checkpoint. ClawTank.app is the app to enable.
- **Annex-B / level constraints:** some decoders reject streams. Mitigation: Main profile, standard parameter sets, and FreeRDP plus Windows App manual checks.
- **IronRDP 0.13 EGFX maturity** (#2121 cache bug: we don't use CacheToSurface).
- **Disk space** (about 2 GB free): keep builds lean.

## Verification
- `make lint test bench` green.
- Probe against the app:
  - fps close to 60 while a window is being dragged
  - idle bandwidth < 10 kbit/s
  - encode time logged
  - CPU measured with `top`/`ps`
- **Human:** Windows App connection shows the live desktop smoothly, including video playback.
