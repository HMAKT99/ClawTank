//! Phase 1 display source: one static test frame per connection.
//!
//! The frame is sized to the client's requested desktop (clamped) and sent once, so an idle
//! session costs no bandwidth. Live capture replaces this in Phase 2.
//!
//! IronRDP calls [`RdpServerDisplay::updates`] only after the client has authenticated and
//! finished capability exchange, so that call doubles as our "session started" signal.

use std::num::{NonZeroU16, NonZeroUsize};
use std::sync::Arc;

use bytes::Bytes;
use ironrdp_server::{
    BitmapUpdate, DesktopSize, DisplayUpdate, PixelFormat, RdpServerDisplay,
    RdpServerDisplayUpdates,
};
use tracing::info;

use crate::access::SessionTracker;
use crate::test_pattern;

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
}

impl TestPatternDisplay {
    pub fn new(tracker: Arc<SessionTracker>) -> Self {
        Self {
            size: DEFAULT_SIZE,
            tracker,
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
        info!(?client_size, chosen = ?self.size, "Client requested desktop size");
        self.size
    }

    async fn updates(&mut self) -> anyhow::Result<Box<dyn RdpServerDisplayUpdates>> {
        self.tracker.session_started();
        Ok(Box::new(TestPatternUpdates {
            size: self.size,
            sent: false,
        }))
    }
}

struct TestPatternUpdates {
    size: DesktopSize,
    sent: bool,
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
        // Static content: nothing more to send. Must not return `None` (that ends the session).
        std::future::pending().await
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
