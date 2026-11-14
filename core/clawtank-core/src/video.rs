//! Bridge between the host's H.264 encoder and the EGFX graphics pipeline (MS-RDPEGFX AVC420).
//!
//! The host (VideoToolbox) submits Annex-B access units with [`VideoHub::submit_h264`]. We
//! create the EGFX surface lazily on the first keyframe, queue the frame on IronRDP's
//! `GraphicsPipelineServer`, drain its output and post it to the session loop.
//!
//! Two rules keep the decoder healthy:
//! - A frame that can't be sent (backpressure) is dropped, and every following frame is
//!   refused until the host sends a keyframe. A dropped P-frame would break the reference
//!   chain.
//! - Lock order is always `inner` then the pipeline mutex. IronRDP calls our
//!   `GraphicsPipelineHandler` while holding the pipeline mutex, so handler callbacks only
//!   touch atomics (never `inner`).
//!
//! Clients that negotiate EGFX without AVC (`AVC_DISABLED`: the Windows App on Android and
//! iOS) can't decode H.264. For them [`VideoHub::codec`] reports [`VideoCodec::Raw`] and the
//! host submits raw BGRA frames with [`VideoHub::submit_bgra`] instead: we diff them against
//! the last frame the client received and send the changed tiles losslessly with ClearCodec
//! (MS-RDPEGFX 2.2.4.1), which every EGFX client must support.

use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::time::Instant;

use ironrdp_egfx::pdu::Avc420Region;
use ironrdp_egfx::server::{GraphicsPipelineServer, MixedTilePayload};
use ironrdp_graphics::clearcodec::ClearCodecEncoder;
use ironrdp_pdu::gcc::{Monitor, MonitorFlags};
use ironrdp_pdu::geometry::ExclusiveRectangle;
use ironrdp_server::{EgfxServerMessage, GfxServerHandle, ServerEvent};
use ironrdp_svc::ChannelFlags;
use tokio::sync::mpsc::UnboundedSender;
use tracing::{debug, info, warn};

use crate::events::{CoreEvent, EventSink};

/// Outcome of [`VideoHub::submit_h264`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SubmitResult {
    /// Queued to the client.
    Sent,
    /// No EGFX session yet (or it closed); nothing was sent and nothing is owed.
    NotReady,
    /// Not sent; the host must send a keyframe next.
    NeedKeyframe,
}

/// How the host must feed video for the current session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VideoCodec {
    /// H.264 access units via [`VideoHub::submit_h264`] (EGFX AVC420).
    H264,
    /// Raw BGRA frames via [`VideoHub::submit_bgra`] (EGFX ClearCodec tiles); the client
    /// negotiated EGFX with AVC disabled.
    Raw,
}

/// Tile edge for the raw path. Remainders narrower than [`MIN_TILE`] are merged into the
/// previous tile so every tile has more than 1024 pixels: IronRDP's ClearCodec encoder only
/// uses its glyph cache for tiles of at most 1024 pixels, and we keep it out of play (see
/// `submit_bgra` on sequence numbers).
const TILE: usize = 64;
const MIN_TILE: usize = 33;

/// Splits `0..len` into `(start, size)` spans of about [`TILE`].
fn tile_spans(len: usize) -> Vec<(usize, usize)> {
    let mut spans = Vec::with_capacity(len / TILE + 1);
    let mut start = 0;
    while start < len {
        let remaining = len - start;
        let size = if remaining < TILE + MIN_TILE {
            remaining
        } else {
            TILE
        };
        spans.push((start, size));
        start += size;
    }
    spans
}

/// Counters for the stats readout. All monotonic within a session.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct VideoStats {
    pub frames_sent: u64,
    pub bytes_sent: u64,
    pub frames_dropped: u64,
    pub frames_acked: u64,
    pub frames_in_flight: u32,
    /// Smoothed time from sending a frame to the client acknowledging it (decode included),
    /// in microseconds; 0 until the first ack. The main congestion signal for adaptive bitrate.
    pub ack_latency_us: u32,
}

/// Shared between the EGFX factory/handler (IronRDP side) and the FFI (host side).
pub struct VideoHub {
    sink: EventSink,
    inner: Mutex<Inner>,
    // Touched from handler callbacks (pipeline mutex held): atomics only.
    channel_open: AtomicBool,
    session_size: AtomicU32,
    frames_acked: AtomicU64,
    /// Send time per in-flight frame id. Its own lock: taken from the handler (pipeline mutex
    /// held) and from `submit_h264` *after* the pipeline mutex is released, never nested.
    send_times: Mutex<HashMap<u32, Instant>>,
    ack_latency_us: AtomicU32,
    /// Whether the negotiated EGFX capabilities allow AVC420 (set before `VideoStart`).
    avc: AtomicBool,
}

struct Inner {
    handle: Option<GfxServerHandle>,
    sender: Option<UnboundedSender<ServerEvent>>,
    surface: Option<u16>,
    need_keyframe: bool,
    started: Instant,
    frames_sent: u64,
    bytes_sent: u64,
    frames_dropped: u64,
    /// Raw path: what the client's surface currently shows (tightly packed BGRA at the session
    /// size), or empty if the next frame must be sent whole.
    shown: Vec<u8>,
    clear: ClearCodecEncoder,
    /// Next ClearCodec `seqNumber`; advanced only for streams actually sent.
    clear_seq: u8,
}

fn pack(width: u16, height: u16) -> u32 {
    (u32::from(width) << 16) | u32::from(height)
}

fn unpack(v: u32) -> (u16, u16) {
    ((v >> 16) as u16, (v & 0xffff) as u16)
}

impl VideoHub {
    pub fn new(sink: EventSink) -> Self {
        Self {
            sink,
            inner: Mutex::new(Inner {
                handle: None,
                sender: None,
                surface: None,
                need_keyframe: true,
                started: Instant::now(),
                frames_sent: 0,
                bytes_sent: 0,
                frames_dropped: 0,
                shown: Vec::new(),
                clear: ClearCodecEncoder::new(),
                clear_seq: 0,
            }),
            channel_open: AtomicBool::new(false),
            session_size: AtomicU32::new(pack(1920, 1080)),
            frames_acked: AtomicU64::new(0),
            send_times: Mutex::new(HashMap::new()),
            ack_latency_us: AtomicU32::new(0),
            avc: AtomicBool::new(true),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The session loop's event sender (set once when the server is built).
    pub fn set_sender(&self, sender: UnboundedSender<ServerEvent>) {
        self.lock().sender = Some(sender);
    }

    /// Desktop size negotiated for the current session; the EGFX surface uses it.
    pub fn set_session_size(&self, width: u16, height: u16) {
        self.session_size
            .store(pack(width, height), Ordering::Release);
    }

    pub fn session_size(&self) -> (u16, u16) {
        unpack(self.session_size.load(Ordering::Acquire))
    }

    /// A new connection built its pipeline: forget the previous session's state.
    pub fn attach(&self, handle: GfxServerHandle) {
        let mut inner = self.lock();
        inner.handle = Some(handle);
        inner.surface = None;
        inner.need_keyframe = true;
        inner.started = Instant::now();
        inner.frames_sent = 0;
        inner.bytes_sent = 0;
        inner.frames_dropped = 0;
        inner.shown.clear();
        inner.clear = ClearCodecEncoder::new();
        inner.clear_seq = 0;
        self.avc.store(true, Ordering::Release);
        self.frames_acked.store(0, Ordering::Release);
        self.ack_latency_us.store(0, Ordering::Release);
        self.send_times
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clear();
    }

    /// The client asked for a new desktop size (Display Control). The next keyframe at that size
    /// recreates the surface (ResetGraphics); frames still arriving at the old size are refused.
    pub fn request_resize(&self, width: u16, height: u16, scale_percent: u32) {
        if self.session_size() == (width, height) {
            return;
        }
        self.set_session_size(width, height);
        {
            let mut inner = self.lock();
            inner.surface = None;
            inner.need_keyframe = true;
            inner.shown.clear();
        }
        if self.channel_open.load(Ordering::Acquire) {
            info!(width, height, scale_percent, "Resizing video");
            (self.sink)(CoreEvent::VideoResize {
                width,
                height,
                scale_percent,
            });
        }
    }

    /// Handler callback: capabilities negotiated, frames may flow. `avc` says whether the
    /// client accepts AVC420; the host reads it back through [`Self::codec`] on `VideoStart`.
    pub(crate) fn on_ready(&self, avc: bool) {
        let (w, h) = self.session_size();
        self.avc.store(avc, Ordering::Release);
        if !self.channel_open.swap(true, Ordering::AcqRel) {
            info!(width = w, height = h, avc, "EGFX ready; requesting video");
            (self.sink)(CoreEvent::VideoStart {
                width: w,
                height: h,
            });
        }
    }

    /// Handler callback: the client acknowledged a frame.
    pub(crate) fn on_frame_ack(&self, frame_id: u32) {
        self.frames_acked.fetch_add(1, Ordering::AcqRel);
        let sent_at = self
            .send_times
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&frame_id);
        if let Some(sent_at) = sent_at {
            let sample = u32::try_from(sent_at.elapsed().as_micros()).unwrap_or(u32::MAX);
            // EWMA with alpha 1/8: smooth enough to ignore single hiccups, quick enough to react.
            let old = self.ack_latency_us.load(Ordering::Acquire);
            let new = if old == 0 {
                sample
            } else {
                old - old / 8 + sample / 8
            };
            self.ack_latency_us.store(new, Ordering::Release);
        }
    }

    /// Handler callback, or session end: the graphics channel is gone.
    pub(crate) fn on_close(&self) {
        if self.channel_open.swap(false, Ordering::AcqRel) {
            info!("EGFX closed; stopping video");
            (self.sink)(CoreEvent::VideoStop);
        }
    }

    /// Called by the accept loop when a connection ends.
    pub fn session_ended(&self) {
        self.on_close();
        let mut inner = self.lock();
        inner.handle = None;
        inner.surface = None;
        inner.need_keyframe = true;
        inner.shown.clear();
    }

    /// How the host must submit frames for the current session.
    pub fn codec(&self) -> VideoCodec {
        if self.avc.load(Ordering::Acquire) {
            VideoCodec::H264
        } else {
            VideoCodec::Raw
        }
    }

    /// Cheap check the host can make before spending time encoding.
    pub fn can_accept(&self) -> bool {
        if !self.channel_open.load(Ordering::Acquire) {
            return false;
        }
        let handle = self.lock().handle.clone();
        let Some(handle) = handle else { return false };
        // Never block the capture thread on the pipeline; if it's busy, say "not now".
        match handle.try_lock() {
            Ok(gfx) => gfx.is_ready() && !gfx.should_backpressure(),
            Err(_) => false,
        }
    }

    pub fn stats(&self) -> VideoStats {
        let inner = self.lock();
        let acked = self.frames_acked.load(Ordering::Acquire);
        VideoStats {
            frames_sent: inner.frames_sent,
            bytes_sent: inner.bytes_sent,
            frames_dropped: inner.frames_dropped,
            frames_acked: acked,
            frames_in_flight: u32::try_from(inner.frames_sent.saturating_sub(acked))
                .unwrap_or(u32::MAX),
            ack_latency_us: self.ack_latency_us.load(Ordering::Acquire),
        }
    }

    /// Queues one H.264 access unit (Annex-B, with SPS/PPS on keyframes) encoded for a
    /// `width`×`height` desktop. Frames for any other size (in flight across a resize) are
    /// refused with `NotReady`, since they would not fit the client's surface.
    pub fn submit_h264(
        &self,
        data: &[u8],
        keyframe: bool,
        width: u16,
        height: u16,
    ) -> SubmitResult {
        if data.is_empty() || !self.channel_open.load(Ordering::Acquire) {
            return SubmitResult::NotReady;
        }
        if !self.avc.load(Ordering::Acquire) {
            // The client can't decode H.264; sending it is what makes it disconnect.
            return SubmitResult::NotReady;
        }
        if (width, height) != self.session_size() {
            debug!(width, height, session = ?self.session_size(), "Dropping frame for a stale size");
            return SubmitResult::NotReady;
        }
        let mut inner = self.lock();
        let (Some(handle), Some(sender)) = (inner.handle.clone(), inner.sender.clone()) else {
            return SubmitResult::NotReady;
        };
        if inner.need_keyframe && !keyframe {
            inner.frames_dropped += 1;
            return SubmitResult::NeedKeyframe;
        }

        let (w, h) = self.session_size();
        let timestamp_ms = u32::try_from(inner.started.elapsed().as_millis()).unwrap_or(u32::MAX);
        let (frame_id, channel_id, messages) = {
            let mut gfx = handle.lock().unwrap_or_else(|e| e.into_inner());
            if !gfx.is_ready() {
                return SubmitResult::NotReady;
            }
            let Some(surface) = Self::ensure_surface(&mut inner, &mut gfx, w, h) else {
                return SubmitResult::NotReady;
            };
            let region = Avc420Region {
                left: 0,
                top: 0,
                right: w.saturating_sub(1),
                bottom: h.saturating_sub(1),
                quantization_parameter: 22,
                quality: 100,
            };
            let frame_id = gfx.send_avc420_frame(surface, data, &[region], timestamp_ms);
            (frame_id, gfx.channel_id(), gfx.drain_output())
        };
        let sent = frame_id.is_some();
        if let Some(frame_id) = frame_id {
            self.record_send(frame_id);
        }

        Self::post(&sender, channel_id, messages);

        if sent {
            inner.need_keyframe = false;
            inner.frames_sent += 1;
            inner.bytes_sent += data.len() as u64;
            SubmitResult::Sent
        } else {
            inner.need_keyframe = true;
            inner.frames_dropped += 1;
            SubmitResult::NeedKeyframe
        }
    }

    /// The EGFX surface for the session size, creating it (ResetGraphics with one primary
    /// monitor, then a surface mapped at (0,0)) if there is none yet.
    fn ensure_surface(
        inner: &mut Inner,
        gfx: &mut GraphicsPipelineServer,
        w: u16,
        h: u16,
    ) -> Option<u16> {
        if let Some(id) = inner.surface {
            return Some(id);
        }
        let monitor = Monitor {
            left: 0,
            top: 0,
            right: i32::from(w) - 1,
            bottom: i32::from(h) - 1,
            flags: MonitorFlags::PRIMARY,
        };
        gfx.resize_with_monitors(w, h, vec![monitor]);
        let Some(id) = gfx.create_surface(w, h) else {
            warn!("EGFX surface creation failed");
            return None;
        };
        gfx.map_surface_to_output(id, 0, 0);
        debug!(surface = id, w, h, "EGFX surface ready");
        inner.surface = Some(id);
        // A new surface starts blank: the raw path must repaint everything.
        inner.shown.clear();
        Some(id)
    }

    fn record_send(&self, frame_id: u32) {
        let mut times = self.send_times.lock().unwrap_or_else(|e| e.into_inner());
        // Bounded: a client that stops acking must not grow this forever.
        if times.len() > 256 {
            times.clear();
        }
        times.insert(frame_id, Instant::now());
    }

    /// Posts drained EGFX output to the session loop.
    fn post(
        sender: &UnboundedSender<ServerEvent>,
        channel_id: Option<u32>,
        messages: Vec<ironrdp_dvc::DvcMessage>,
    ) {
        if !messages.is_empty()
            && let Some(channel_id) = channel_id
        {
            match ironrdp_dvc::encode_dvc_messages(
                channel_id,
                messages,
                ChannelFlags::SHOW_PROTOCOL,
            ) {
                Ok(messages) => {
                    let _ = sender.send(ServerEvent::Egfx(EgfxServerMessage::SendMessages {
                        messages,
                    }));
                }
                Err(e) => warn!(error = %e, "Failed to encode EGFX messages"),
            }
        }
    }

    /// Queues one raw frame for a client without AVC (see [`VideoCodec::Raw`]): `data` is
    /// 32-bit BGRA (alpha ignored), rows top-down, `stride` bytes apart; only the top-left
    /// `width`×`height` pixels are read. Frames for any size other than the session size are
    /// refused with `NotReady`, as is everything while the session uses H.264.
    ///
    /// Only tiles that differ from what the client already shows are encoded. A frame that
    /// can't be sent (backpressure) is simply dropped: the next one is diffed against what the
    /// client really has, so nothing is lost. `Sent` is also returned when nothing changed.
    pub fn submit_bgra(&self, data: &[u8], width: u16, height: u16, stride: usize) -> SubmitResult {
        if !self.channel_open.load(Ordering::Acquire) || self.avc.load(Ordering::Acquire) {
            return SubmitResult::NotReady;
        }
        if (width, height) != self.session_size() {
            debug!(width, height, session = ?self.session_size(), "Dropping frame for a stale size");
            return SubmitResult::NotReady;
        }
        let (w, h) = (usize::from(width), usize::from(height));
        let row = w * 4;
        if w == 0 || h == 0 || stride < row || data.len() < stride * (h - 1) + row {
            warn!(
                width,
                height,
                stride,
                len = data.len(),
                "Raw frame has a bad layout"
            );
            return SubmitResult::NotReady;
        }

        let mut inner = self.lock();
        let (Some(handle), Some(sender)) = (inner.handle.clone(), inner.sender.clone()) else {
            return SubmitResult::NotReady;
        };
        if inner.surface.is_none() {
            inner.shown.clear();
        }
        let full = inner.shown.len() != row * h;

        // Encode changed tiles before taking the pipeline lock (encoding is the slow part).
        let mut tiles = Vec::new();
        let mut bytes = 0usize;
        let mut tile_buf = Vec::with_capacity(TILE * 2 * TILE * 2 * 4);
        for &(ty, th) in &tile_spans(h) {
            for &(tx, tw) in &tile_spans(w) {
                let changed = full
                    || (ty..ty + th).any(|y| {
                        let src = &data[y * stride + tx * 4..y * stride + (tx + tw) * 4];
                        src != &inner.shown[y * row + tx * 4..y * row + (tx + tw) * 4]
                    });
                if !changed {
                    continue;
                }
                tile_buf.clear();
                for y in ty..ty + th {
                    tile_buf
                        .extend_from_slice(&data[y * stride + tx * 4..y * stride + (tx + tw) * 4]);
                }
                // Tile sizes are bounded by the u16 session size.
                let bitmap_data = inner.clear.encode(&tile_buf, tw as u16, th as u16);
                bytes += bitmap_data.len();
                tiles.push(MixedTilePayload::ClearCodec {
                    destination: ExclusiveRectangle {
                        left: tx as u16,
                        top: ty as u16,
                        right: (tx + tw) as u16,
                        bottom: (ty + th) as u16,
                    },
                    bitmap_data,
                });
            }
        }
        if tiles.is_empty() {
            return SubmitResult::Sent;
        }
        // ClearCodec streams carry a sequence number the client checks for continuity. The
        // encoder bumps its own counter even for frames we end up dropping, so we number the
        // streams ourselves and only commit the counter once the frame is queued.
        let mut seq = inner.clear_seq;
        for tile in &mut tiles {
            if let MixedTilePayload::ClearCodec { bitmap_data, .. } = tile {
                bitmap_data[1] = seq;
                seq = seq.wrapping_add(1);
            }
        }

        let timestamp_ms = u32::try_from(inner.started.elapsed().as_millis()).unwrap_or(u32::MAX);
        let (frame_id, channel_id, messages) = {
            let mut gfx = handle.lock().unwrap_or_else(|e| e.into_inner());
            if !gfx.is_ready() || gfx.should_backpressure() {
                return SubmitResult::NotReady;
            }
            // No surface yet implies `full` (`shown` was cleared above under the same lock).
            let Some(surface) = Self::ensure_surface(&mut inner, &mut gfx, width, height) else {
                return SubmitResult::NotReady;
            };
            let frame_id = gfx.send_mixed_frame(surface, tiles, timestamp_ms);
            (frame_id, gfx.channel_id(), gfx.drain_output())
        };
        if let Some(frame_id) = frame_id {
            self.record_send(frame_id);
        }
        Self::post(&sender, channel_id, messages);

        if frame_id.is_some() {
            inner.clear_seq = seq;
            if full {
                inner.shown = vec![0; row * h];
            }
            for y in 0..h {
                inner.shown[y * row..(y + 1) * row]
                    .copy_from_slice(&data[y * stride..y * stride + row]);
            }
            inner.frames_sent += 1;
            inner.bytes_sent += bytes as u64;
            SubmitResult::Sent
        } else {
            inner.frames_dropped += 1;
            SubmitResult::NotReady
        }
    }
}
