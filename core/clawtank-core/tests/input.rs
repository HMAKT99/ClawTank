//! End-to-end input + cursor test: a client sends fast-path keyboard and mouse input (incl.
//! horizontal wheel, middle and X1 buttons fixed by our vendored patch) and every event
//! reaches the host's input sink; a cursor shape published by the host reaches the client.

#[path = "support/client.rs"]
mod client;

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use clawtank_core::events::CoreEvent;
use clawtank_core::input::{InputEvent, MouseButton};
use clawtank_core::server::{self, ServerConfig};
use clawtank_core::tls::TlsIdentity;
use ironrdp_async::FramedWrite as _;
use ironrdp_graphics::image_processing::PixelFormat;
use ironrdp_pdu::input::fast_path::{FastPathInputEvent, KeyboardFlags};
use ironrdp_pdu::input::mouse::PointerFlags;
use ironrdp_pdu::input::mouse_x::PointerXFlags;
use ironrdp_pdu::input::{MousePdu, MouseXPdu};
use ironrdp_session::ActiveStageOutput;
use ironrdp_session::image::DecodedImage;

const USER: &str = "tester";
const PASSWORD: &str = "input-test-password";

fn mouse(flags: PointerFlags, wheel: i16, x: u16, y: u16) -> FastPathInputEvent {
    FastPathInputEvent::MouseEvent(MousePdu {
        flags,
        number_of_wheel_rotation_units: wheel,
        x_position: x,
        y_position: y,
    })
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn client_input_reaches_host_and_cursor_reaches_client() {
    let events: Arc<Mutex<Vec<CoreEvent>>> = Arc::default();
    let inputs: Arc<Mutex<Vec<InputEvent>>> = Arc::default();
    let (elog, ilog) = (Arc::clone(&events), Arc::clone(&inputs));
    let config = ServerConfig {
        bind: "127.0.0.1:0".parse().unwrap(),
        username: USER.to_owned(),
        password: PASSWORD.to_owned(),
        identity: TlsIdentity::generate("input-test.local").unwrap(),
        lan_only: true,
    };
    let server = server::start(
        config,
        Arc::new(move |e| elog.lock().unwrap().push(e)),
        Arc::new(move |e| ilog.lock().unwrap().push(e)),
    )
    .unwrap();

    // A 4x4 cursor: opaque red with a transparent corner, hotspot (1,2). BGRA, bottom-up.
    let mut shape = [0u8, 0, 255, 255].repeat(16);
    shape[3] = 0;
    assert!(server.pointer().set(&shape, 4, 4, 1, 2));

    let config = client::client_config_with(USER, PASSWORD, 800, 600, true);
    let (result, mut session, _) = client::connect_with(server.local_addr(), config, None)
        .await
        .expect("connect");
    let mut stage = client::active_stage(result);
    let mut image = DecodedImage::new(PixelFormat::RgbA32, 800, 600);

    let input = [
        FastPathInputEvent::KeyboardEvent(KeyboardFlags::empty(), 0x1e), // 'A' down
        FastPathInputEvent::KeyboardEvent(KeyboardFlags::RELEASE, 0x1e),
        FastPathInputEvent::KeyboardEvent(KeyboardFlags::EXTENDED, 0x5b), // left Win down
        FastPathInputEvent::UnicodeKeyboardEvent(KeyboardFlags::empty(), 0x00e9), // é
        mouse(PointerFlags::MOVE, 0, 400, 300),
        mouse(PointerFlags::LEFT_BUTTON | PointerFlags::DOWN, 0, 400, 300),
        mouse(PointerFlags::LEFT_BUTTON, 0, 400, 300),
        mouse(
            PointerFlags::MIDDLE_BUTTON_OR_WHEEL | PointerFlags::DOWN,
            0,
            400,
            300,
        ),
        mouse(PointerFlags::VERTICAL_WHEEL, 120, 0, 0),
        mouse(
            PointerFlags::HORIZONTAL_WHEEL | PointerFlags::WHEEL_NEGATIVE,
            -120,
            0,
            0,
        ),
        FastPathInputEvent::MouseEventEx(MouseXPdu {
            flags: PointerXFlags::BUTTON1 | PointerXFlags::DOWN,
            x_position: 400,
            y_position: 300,
        }),
    ];
    for frame in stage
        .process_fastpath_input(&mut image, &input)
        .expect("encode input")
    {
        if let ActiveStageOutput::ResponseFrame(bytes) = frame {
            session.write_all(&bytes).await.unwrap();
        }
    }

    let expected = vec![
        InputEvent::Key {
            code: 0x1e,
            extended: false,
            down: true,
        },
        InputEvent::Key {
            code: 0x1e,
            extended: false,
            down: false,
        },
        InputEvent::Key {
            code: 0x5b,
            extended: true,
            down: true,
        },
        InputEvent::Unicode {
            unit: 0x00e9,
            down: true,
        },
        InputEvent::Move { x: 400, y: 300 },
        InputEvent::Button {
            button: MouseButton::Left,
            down: true,
        },
        InputEvent::Button {
            button: MouseButton::Left,
            down: false,
        },
        InputEvent::Button {
            button: MouseButton::Middle,
            down: true,
        },
        InputEvent::Wheel {
            vertical: 120,
            horizontal: 0,
        },
        InputEvent::Wheel {
            vertical: 0,
            horizontal: -120,
        },
        InputEvent::Button {
            button: MouseButton::X1,
            down: true,
        },
    ];

    // Pump the session: answer the server, and watch for the cursor shape.
    let mut got_pointer = None;
    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline {
        let done_input = inputs.lock().unwrap().len() >= expected.len();
        if done_input && got_pointer.is_some() {
            break;
        }
        let Ok(read) = tokio::time::timeout(Duration::from_millis(200), session.read_pdu()).await
        else {
            continue;
        };
        let (action, payload) = read.expect("read");
        for out in stage
            .process(&mut image, action, &payload)
            .expect("process")
        {
            match out {
                ActiveStageOutput::ResponseFrame(bytes) => session.write_all(&bytes).await.unwrap(),
                ActiveStageOutput::PointerBitmap(p) => got_pointer = Some(p),
                _ => {}
            }
        }
    }

    // The client may also send its own sync/lock-key event; compare the rest in order.
    let received: Vec<_> = inputs
        .lock()
        .unwrap()
        .iter()
        .copied()
        .filter(|e| !matches!(e, InputEvent::Sync { .. }))
        .collect();
    assert_eq!(received, expected, "events: {:?}", events.lock().unwrap());

    let pointer = got_pointer.expect("cursor shape delivered to client");
    assert_eq!((pointer.width, pointer.height), (4, 4));
    assert_eq!((pointer.hotspot_x, pointer.hotspot_y), (1, 2));
    drop(session);
    server.stop();
}
