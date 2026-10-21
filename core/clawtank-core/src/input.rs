//! Client input → host. IronRDP decodes keyboard/mouse PDUs into events; we translate them
//! into a small, flat [`InputEvent`] and hand them to the host (which injects CGEvents).
//! Nothing here interprets keys: scancode → macOS keycode mapping lives in the host.

use std::sync::Arc;

use ironrdp_server::{KeyboardEvent, MouseEvent, RdpServerInputHandler};
use tracing::trace;

/// Mouse buttons, numbered as in the FFI.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseButton {
    Left = 0,
    Right = 1,
    Middle = 2,
    X1 = 3,
    X2 = 4,
}

/// One input event in desktop coordinates (the negotiated session size).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputEvent {
    /// Set-1 scancode; `extended` is the 0xE0 prefix.
    Key {
        code: u8,
        extended: bool,
        down: bool,
    },
    /// A UTF-16 code unit (IME / on-screen keyboards).
    Unicode {
        unit: u16,
        down: bool,
    },
    /// Lock-key state from the client (bit 0 Scroll, 1 Num, 2 Caps, 3 Kana).
    Sync {
        flags: u32,
    },
    Move {
        x: u16,
        y: u16,
    },
    RelMove {
        dx: i32,
        dy: i32,
    },
    Button {
        button: MouseButton,
        down: bool,
    },
    /// Wheel rotation units: 120 per notch, positive = away from the user / right.
    Wheel {
        vertical: i32,
        horizontal: i32,
    },
}

pub type InputSink = Arc<dyn Fn(InputEvent) + Send + Sync>;

/// IronRDP input handler that forwards everything to the host.
pub struct InputForwarder {
    sink: InputSink,
}

impl InputForwarder {
    pub fn new(sink: InputSink) -> Self {
        Self { sink }
    }

    fn emit(&self, event: InputEvent) {
        trace!(?event, "input");
        (self.sink)(event);
    }
}

pub fn translate_mouse(event: MouseEvent) -> Option<InputEvent> {
    use MouseButton as B;
    let button = |button, down| Some(InputEvent::Button { button, down });
    match event {
        MouseEvent::Move { x, y } => Some(InputEvent::Move { x, y }),
        MouseEvent::RelMove { x, y } => Some(InputEvent::RelMove { dx: x, dy: y }),
        MouseEvent::LeftPressed => button(B::Left, true),
        MouseEvent::LeftReleased => button(B::Left, false),
        MouseEvent::RightPressed => button(B::Right, true),
        MouseEvent::RightReleased => button(B::Right, false),
        MouseEvent::MiddlePressed => button(B::Middle, true),
        MouseEvent::MiddleReleased => button(B::Middle, false),
        MouseEvent::Button4Pressed => button(B::X1, true),
        MouseEvent::Button4Released => button(B::X1, false),
        MouseEvent::Button5Pressed => button(B::X2, true),
        MouseEvent::Button5Released => button(B::X2, false),
        MouseEvent::VerticalScroll { value } => Some(InputEvent::Wheel {
            vertical: i32::from(value),
            horizontal: 0,
        }),
        MouseEvent::HorizontalScroll { value } => Some(InputEvent::Wheel {
            vertical: 0,
            horizontal: i32::from(value),
        }),
        // Advanced-input (ainput) wheel deltas, same 120-per-notch convention.
        MouseEvent::Scroll { x, y } => Some(InputEvent::Wheel {
            vertical: y,
            horizontal: x,
        }),
    }
}

pub fn translate_keyboard(event: KeyboardEvent) -> Option<InputEvent> {
    Some(match event {
        KeyboardEvent::Pressed { code, extended } => InputEvent::Key {
            code,
            extended,
            down: true,
        },
        KeyboardEvent::Released { code, extended } => InputEvent::Key {
            code,
            extended,
            down: false,
        },
        KeyboardEvent::UnicodePressed(unit) => InputEvent::Unicode { unit, down: true },
        KeyboardEvent::UnicodeReleased(unit) => InputEvent::Unicode { unit, down: false },
        KeyboardEvent::Synchronize(flags) => InputEvent::Sync {
            flags: u32::from(flags.bits()),
        },
    })
}

impl RdpServerInputHandler for InputForwarder {
    fn keyboard(&mut self, event: KeyboardEvent) {
        if let Some(e) = translate_keyboard(event) {
            self.emit(e);
        }
    }

    fn mouse(&mut self, event: MouseEvent) {
        if let Some(e) = translate_mouse(event) {
            self.emit(e);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mouse_events_translate() {
        assert_eq!(
            translate_mouse(MouseEvent::Button4Pressed),
            Some(InputEvent::Button {
                button: MouseButton::X1,
                down: true
            })
        );
        assert_eq!(
            translate_mouse(MouseEvent::HorizontalScroll { value: -120 }),
            Some(InputEvent::Wheel {
                vertical: 0,
                horizontal: -120
            })
        );
        assert_eq!(
            translate_mouse(MouseEvent::Move { x: 10, y: 20 }),
            Some(InputEvent::Move { x: 10, y: 20 })
        );
    }

    #[test]
    fn keyboard_events_translate() {
        assert_eq!(
            translate_keyboard(KeyboardEvent::Pressed {
                code: 0x1d,
                extended: true
            }),
            Some(InputEvent::Key {
                code: 0x1d,
                extended: true,
                down: true
            })
        );
        assert_eq!(
            translate_keyboard(KeyboardEvent::UnicodeReleased(0x00e9)),
            Some(InputEvent::Unicode {
                unit: 0x00e9,
                down: false
            })
        );
    }
}
