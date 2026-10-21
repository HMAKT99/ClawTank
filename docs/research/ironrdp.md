# IronRDP research (Phase 0)

Date: 2026-10-21. Source inspected: crates.io API and `Devolutions/IronRDP` master @ `0f9154d` (2026-10-20). Repo: Apache-2.0 / MIT dual license, ~3.2k stars, very active (pushed daily).

## Versions to pin

| Crate | Version | Released |
|---|---|---|
| ironrdp-server | 0.13.0 | 2026-07-10 |
| ironrdp-egfx | 0.3.0 | 2026-07-10 |
| ironrdp-acceptor | 0.10.0 | 2026-07-10 |
| ironrdp-cliprdr | 0.7.0 | 2026-07-10 |
| ironrdp-rdpsnd | 0.9.0 | 2026-07-10 |
| ironrdp-displaycontrol | 0.8.0 | 2026-07-10 |
| ironrdp-rdpdr | 0.7.0 | 2026-07-10 |

We pin with `=x.y.z` and commit `Cargo.lock`.

> **Correction (Phase 1, 2026-10-21):** master's `Cargo.toml` shows the same version numbers as crates.io, but master carries many **unreleased** changes. The published `ironrdp-server 0.13.0` does **not** have: `ConnectionSource`/`serve`, `ConnectionHandler::on_connection_info`, `DisplayContext` (suppress-output), server-side RDPDR (`with_rdpdr_factory`), RDPEI or USB. It **does** have: `run`/`run_connection`, `ConnectionHandler::{on_accept, on_disconnected}`, `CredentialValidator`, `with_honor_client_desktop_size`, EGFX (`GfxServerFactory`), CLIPRDR, RDPSND, DisplayControl, and the bitmap/RemoteFX encoders. Sections below describe master unless marked. See ADR-009.

## Findings per requirement

### Server, TLS, NLA
- `RdpServer::builder()` is a typestate builder: `.with_addr()` → `.with_tls(acceptor)` or `.with_hybrid(acceptor, pub_key)` (Hybrid = TLS + CredSSP/NLA) → input handler → display handler → `.build()`.
- NLA credentials come from `RdpServer::set_credentials(Some(Credentials { username, password, domain }))`. CredSSP runs through `sspi` (NTLM; there are Kerberos hooks we won't use). **This fits our dedicated-app-password ADR exactly.**
- There's also `with_credential_validator(Arc<dyn CredentialValidator>)` for accept/reject decisions. It's the hook for the rate limiting, lockout and audit log we need.
- `with_connection_policy`, `with_auto_reconnect_cookie` and `with_udp_transport` (RDPEUDP) are also available.
- Open issues to watch:
  - #1432: server-side CredSSP provider refactor (tech debt)
  - #1357: server credential handling design
  - #2118 / #2122: Jump Desktop interop. Not our target clients, but it signals interop edge cases.

### Graphics: EGFX / H.264
- Feature `egfx` on ironrdp-server. `GfxServerFactory::build_server_with_handle()` returns a `GfxServerHandle = Arc<Mutex<GraphicsPipelineServer>>` that our display code can push frames into proactively.
- `GraphicsPipelineServer` exposes:
  - `create_surface` and `map_surface_to_output`
  - `send_avc420_frame(surface_id, h264_annexb, regions, timestamp_ms)`, plus `send_avc444_frame` / `send_avc444v2_frame`
  - planar, uncompressed, RemoteFX-progressive, ClearCodec
  - `supports_avc420()` / `supports_avc444()`
- Frame-ack tracking is built in: `set_max_in_flight`, `should_backpressure`, `client_queue_depth`, `acknowledge`. This is what we need for adaptive bitrate and frame dropping.
- **Bitstream format:** MS-RDPEGFX RFX_AVC420_BITMAP_STREAM requires **Annex-B** with 16-aligned coded dimensions. `ironrdp-egfx` 0.3 client docs claim "AVC length-prefixed". That's wrong per the spec; candidate upstream doc fix. The server side passes bytes through unchanged.
- **H.264 encoding is not done by IronRDP.** We supply the bitstream, which is our VideoToolbox path, as planned.
- Fallback codecs without EGFX: bitmap/RemoteFX (`encoder/rfx.rs`), QOI, and optional NSCodec. Phase 1's static test frame can use the bitmap path.
- Watch: #2121 (EGFX ResetGraphics clears the bitmap cache). It affects CacheToSurface, which we don't plan to use.

### Display control and resize
- The `RdpServerDisplay` trait has `size()`, `request_initial_size(client_size)`, `request_layout(DisplayControlMonitorLayout)`, `monitor_count()` and `offers_display_control()`.
- The builder has `with_honor_client_desktop_size(max)`. That's everything we need for live resize and multi-monitor.

### Cursor
- `DisplayUpdate` variants include `RGBAPointer`, `ColorPointer`, `LargePointer` and `CachedPointer`. Client-side cursor rendering is supported.

### Input
- `RdpServerInputHandler` receives keyboard (scancode + unicode) and mouse events. The `ironrdp-ainput` and `ironrdp-rdpei` (touch/pen) factories also exist.

### Clipboard (CLIPRDR)
- `with_cliprdr_factory(CliprdrServerFactory)`, with server role support in `ironrdp-cliprdr`. File contents are supported at the PDU level.
- **Bug to track: #2148.** `ironrdp-server` never drives `Cliprdr::drive_timeouts`, so file copies stall after about 100 locks. This matters for Phase 7. Candidate for an upstream PR.

### Audio (RDPSND)
- `with_sound_factory(SoundServerFactory)` → `RdpsndServerHandler` (we provide `get_formats()` and the PCM stream). Usable as-is.

### File transfer (RDPDR)
- **Master only (unreleased in 0.13.0):** `with_rdpdr_factory(RdpdrServerFactory)` → `RdpdrServerBackend` (`on_device_announce`, …), with an EFS PDU module (`pdu/efs.rs`). Drive redirection looks feasible. Maturity is unknown until we exercise it in Phase 7.

### Other
- USB redirection (opt-in feature), echo, auto-detect (RTT measurement; useful for adaptive quality), multitransport/UDP.

## Gaps and proposals

| Gap | Proposal |
|---|---|
| Clipboard lock timeouts (#2148) | (a) Contribute the fix upstream before Phase 7. |
| Server-side CredSSP refactor in flight (#1432) | Keep our NLA code thin and behind `CredentialValidator` / `set_credentials`, so an API change touches one file. |
| macOS-specific interop (Windows App for Mac/iPad) not tested upstream | Our own integration tests plus the manual checklist. Report upstream anything we find. |

**Verdict:** nothing blocks us. We don't need a FreeRDP fallback. Build on `ironrdp-server 0.13.0` with `egfx`.
