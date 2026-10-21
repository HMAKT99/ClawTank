//! Phase 1 input sink: counts and traces client input without acting on it.
//! Real injection (CGEvent) lives in the Swift host from Phase 3.

use ironrdp_server::{KeyboardEvent, MouseEvent, RdpServerInputHandler};
use tracing::trace;

#[derive(Debug, Default)]
pub struct InputLogger {
    keyboard_events: u64,
    mouse_events: u64,
}

impl RdpServerInputHandler for InputLogger {
    fn keyboard(&mut self, event: KeyboardEvent) {
        self.keyboard_events += 1;
        trace!(?event, total = self.keyboard_events, "keyboard");
    }

    fn mouse(&mut self, event: MouseEvent) {
        self.mouse_events += 1;
        trace!(?event, total = self.mouse_events, "mouse");
    }
}
