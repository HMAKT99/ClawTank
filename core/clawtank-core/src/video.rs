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

use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::time::Instant;

use ironrdp_egfx::pdu::Avc420Region;
use ironrdp_pdu::gcc::{Monitor, MonitorFlags};
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

/// Counters for the stats readout. All monotonic within a session.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct VideoStats {
    pub frames_sent: u64,
    pub bytes_sent: u64,
    pub frames_dropped: u64,
    pub frames_acked: u64,
    pub frames_in_flight: u32,
}

/// Shared between the EGFX factory/handler (IronRDP side) and the FFI (host side).
pub struct VideoHub {
    sink: EventSink,
    inner: Mutex<Inner>,
    // Touched from handler callbacks (pipeline mutex held): atomics only.
    channel_open: AtomicBool,
    session_size: AtomicU32,
    frames_acked: AtomicU64,
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
            }),
            channel_open: AtomicBool::new(false),
            session_size: AtomicU32::new(pack(1920, 1080)),
            frames_acked: AtomicU64::new(0),
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
        self.frames_acked.store(0, Ordering::Release);
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

    /// Handler callback: capabilities negotiated, frames may flow.
    pub(crate) fn on_ready(&self) {
        let (w, h) = self.session_size();
        if !self.channel_open.swap(true, Ordering::AcqRel) {
            info!(width = w, height = h, "EGFX ready; requesting video");
            (self.sink)(CoreEvent::VideoStart {
                width: w,
                height: h,
            });
        }
    }

    /// Handler callback: the client acknowledged a frame.
    pub(crate) fn on_frame_ack(&self) {
        self.frames_acked.fetch_add(1, Ordering::AcqRel);
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
        let (sent, channel_id, messages) = {
            let mut gfx = handle.lock().unwrap_or_else(|e| e.into_inner());
            if !gfx.is_ready() {
                return SubmitResult::NotReady;
            }
            let surface = match inner.surface {
                Some(id) => id,
                None => {
                    // ResetGraphics with one primary monitor, then a surface mapped at (0,0).
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
                        return SubmitResult::NotReady;
                    };
                    gfx.map_surface_to_output(id, 0, 0);
                    debug!(surface = id, w, h, "EGFX surface ready");
                    inner.surface = Some(id);
                    id
                }
            };
            let region = Avc420Region {
                left: 0,
                top: 0,
                right: w.saturating_sub(1),
                bottom: h.saturating_sub(1),
                quantization_parameter: 22,
                quality: 100,
            };
            let sent = gfx
                .send_avc420_frame(surface, data, &[region], timestamp_ms)
                .is_some();
            (sent, gfx.channel_id(), gfx.drain_output())
        };

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
}
