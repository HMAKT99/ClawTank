//! Cursor shapes from the host → client, so the client draws the pointer locally (no
//! cursor baked into the video, no round-trip lag when moving the mouse).
//!
//! The host pushes the current shape whenever it changes. The hub remembers the latest one so
//! a session that starts later gets it immediately, and forwards updates to the session's
//! display stream (see `display.rs`).

use std::sync::Mutex;

use ironrdp_server::{DisplayUpdate, RGBAPointer};
use tokio::sync::mpsc::UnboundedSender;

/// Largest shape every client accepts without the Large Pointer capability.
pub const MAX_POINTER_SIDE: u16 = 96;

#[derive(Default)]
pub struct PointerHub {
    inner: Mutex<Inner>,
}

#[derive(Default)]
struct Inner {
    session: Option<UnboundedSender<DisplayUpdate>>,
    current: Option<DisplayUpdate>,
}

impl PointerHub {
    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// A session's display stream started; it receives the current shape right away.
    pub fn attach(&self, session: UnboundedSender<DisplayUpdate>) {
        let mut inner = self.lock();
        if let Some(current) = inner.current.clone() {
            let _ = session.send(current);
        }
        inner.session = Some(session);
    }

    fn publish(&self, update: DisplayUpdate) {
        let mut inner = self.lock();
        if let Some(session) = &inner.session
            && session.send(update.clone()).is_err()
        {
            inner.session = None;
        }
        inner.current = Some(update);
    }

    /// Sets the shape. `bgra` is 32 bpp BGRA with straight alpha, rows bottom-up (Windows DIB
    /// order, as MS-RDPBCGR pointer updates use). Returns false for invalid input.
    pub fn set(&self, bgra: &[u8], width: u16, height: u16, hot_x: u16, hot_y: u16) -> bool {
        let valid = width > 0
            && height > 0
            && width <= MAX_POINTER_SIDE
            && height <= MAX_POINTER_SIDE
            && hot_x < width
            && hot_y < height
            && bgra.len() == usize::from(width) * usize::from(height) * 4;
        if !valid {
            return false;
        }
        self.publish(DisplayUpdate::RGBAPointer(RGBAPointer {
            cache_index: 0,
            width,
            height,
            hot_x,
            hot_y,
            data: bgra.to_vec(),
        }));
        true
    }

    /// Hides the pointer (e.g. the app hid it while typing).
    pub fn hide(&self) {
        self.publish(DisplayUpdate::HidePointer);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_bad_shapes_and_replays_current_to_new_sessions() {
        let hub = PointerHub::default();
        assert!(!hub.set(&[0; 16], 2, 2, 2, 0), "hotspot outside");
        assert!(!hub.set(&[0; 15], 2, 2, 0, 0), "wrong length");
        assert!(!hub.set(&vec![0; 97 * 97 * 4], 97, 97, 0, 0), "too large");
        assert!(hub.set(&[0; 16], 2, 2, 1, 1));

        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        hub.attach(tx);
        assert!(matches!(rx.try_recv(), Ok(DisplayUpdate::RGBAPointer(p)) if p.hot_x == 1));
        hub.hide();
        assert!(matches!(rx.try_recv(), Ok(DisplayUpdate::HidePointer)));
    }
}
