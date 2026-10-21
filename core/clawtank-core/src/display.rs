//! Legacy (non-EGFX) display source: one static test frame per connection. With EGFX the
//! live H.264 stream (see `video.rs`) replaces it as soon as the first frame arrives.
//!
//! The frame is sized to the client's requested desktop (clamped) and sent once, so an idle
//! session costs no bandwidth. Live capture replaces this in Phase 2.
//!
//! After the frame, the same stream carries cursor shapes from [`PointerHub`].
//!
//! IronRDP calls [`RdpServerDisplay::updates`] only after the client has authenticated and
//! finished capability exchange, so that call doubles as our "session started" signal.

use std::num::{NonZeroU16, NonZeroUsize};
use std::sync::Arc;

use bytes::Bytes;
use ironrdp_displaycontrol::pdu::DisplayControlMonitorLayout;
use ironrdp_server::{
    BitmapUpdate, DesktopSize, DisplayUpdate, PixelFormat, RdpServerDisplay,
    RdpServerDisplayUpdates,
};
use tracing::info;

use tokio::sync::mpsc::{UnboundedReceiver, unbounded_channel};

use crate::access::SessionTracker;
use crate::pointer::PointerHub;
use crate::test_pattern;
use crate::video::VideoHub;

const DEFAULT_SIZE: DesktopSize = DesktopSize {
    width: 1920,
    height: 1080,
};
// RDP limits (MS-RDPBCGR 2.2.1.3.2). We only clamp sizes no valid client sends, so the size we
// report always matches what the acceptor negotiated (see `with_honor_client_desktop_size`).
const MAX_WIDTH: u16 = 8192;
const MAX_HEIGHT: u16 = 8192;
const MIN_SIDE: u16 = 200;

/// Serves the static test pattern.
pub struct TestPatternDisplay {
    size: DesktopSize,
    tracker: Arc<SessionTracker>,
    video: Arc<VideoHub>,
    pointer: Arc<PointerHub>,
}

impl TestPatternDisplay {
    pub fn new(
        tracker: Arc<SessionTracker>,
        video: Arc<VideoHub>,
        pointer: Arc<PointerHub>,
    ) -> Self {
        Self {
            size: DEFAULT_SIZE,
            tracker,
            video,
            pointer,
        }
    }
}

fn clamp_size(size: DesktopSize) -> DesktopSize {
    DesktopSize {
        width: size.width.clamp(MIN_SIDE, MAX_WIDTH),
        height: size.height.clamp(MIN_SIDE, MAX_HEIGHT),
    }
}

#[async_trait::async_trait]
impl RdpServerDisplay for TestPatternDisplay {
    async fn size(&mut self) -> DesktopSize {
        self.size
    }

    async fn request_initial_size(&mut self, client_size: DesktopSize) -> DesktopSize {
        self.size = clamp_size(client_size);
        self.video
            .set_session_size(self.size.width, self.size.height);
        info!(?client_size, chosen = ?self.size, "Client requested desktop size");
        self.size
    }

    /// Display Control (MS-RDPEDISP): the client window was resized or moved to another monitor.
    /// We follow the primary monitor; the host resizes its virtual display and restarts video.
    fn request_layout(&mut self, layout: DisplayControlMonitorLayout) {
        let Some(monitor) = layout
            .monitors()
            .iter()
            .find(|m| m.is_primary())
            .or_else(|| layout.monitors().first())
        else {
            return;
        };
        let (width, height) = monitor.dimensions();
        let requested = DesktopSize {
            // MS-RDPEDISP 2.2.2.2.1: width must be even.
            width: u16::try_from(width & !1).unwrap_or(MAX_WIDTH),
            height: u16::try_from(height).unwrap_or(MAX_HEIGHT),
        };
        let size = clamp_size(requested);
        let scale = monitor.desktop_scale_factor().unwrap_or(100);
        info!(?size, scale, "Client requested new layout");
        self.size = size;
        self.video.request_resize(size.width, size.height, scale);
    }

    async fn updates(&mut self) -> anyhow::Result<Box<dyn RdpServerDisplayUpdates>> {
        self.tracker.session_started();
        let (tx, rx) = unbounded_channel();
        self.pointer.attach(tx);
        Ok(Box::new(TestPatternUpdates {
            size: self.size,
            sent: false,
            pointer: rx,
        }))
    }
}

struct TestPatternUpdates {
    size: DesktopSize,
    sent: bool,
    pointer: UnboundedReceiver<DisplayUpdate>,
}

impl TestPatternUpdates {
    fn frame(&self) -> DisplayUpdate {
        let (w, h) = (self.size.width, self.size.height);
        let data = test_pattern::render_bgra(w, h);
        DisplayUpdate::Bitmap(BitmapUpdate {
            x: 0,
            y: 0,
            width: NonZeroU16::new(w).expect("clamped to >= MIN_SIDE"),
            height: NonZeroU16::new(h).expect("clamped to >= MIN_SIDE"),
            format: PixelFormat::BgrA32,
            data: Bytes::from(data),
            stride: NonZeroUsize::new(usize::from(w) * 4).expect("non-zero width"),
        })
    }
}

#[async_trait::async_trait]
impl RdpServerDisplayUpdates for TestPatternUpdates {
    async fn next_update(&mut self) -> anyhow::Result<Option<DisplayUpdate>> {
        if !self.sent {
            self.sent = true;
            info!(
                width = self.size.width,
                height = self.size.height,
                "Sending test frame"
            );
            return Ok(Some(self.frame()));
        }
        // After the frame, only cursor shapes flow here (video goes over EGFX). Never return
        // `None` (that ends the session): if the pointer source goes away, just idle.
        match self.pointer.recv().await {
            Some(update) => Ok(Some(update)),
            None => std::future::pending().await,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sizes_are_clamped() {
        let s = clamp_size(DesktopSize {
            width: 9000,
            height: 10,
        });
        assert_eq!((s.width, s.height), (MAX_WIDTH, MIN_SIDE));
        let s = clamp_size(DesktopSize {
            width: 1512,
            height: 982,
        });
        assert_eq!((s.width, s.height), (1512, 982));
    }
}
