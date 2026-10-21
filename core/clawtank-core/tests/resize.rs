//! End-to-end live resize: an EGFX client asks for a new size over Display Control; the core
//! reports `VideoResize`, refuses frames still sized for the old desktop, and the next keyframe
//! at the new size reaches the client after a ResetGraphics carrying the new size.

#[path = "support/client.rs"]
mod client;

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use clawtank_core::events::CoreEvent;
use clawtank_core::server::{self, ServerConfig};
use clawtank_core::tls::TlsIdentity;
use clawtank_core::video::SubmitResult;
use ironrdp_async::FramedWrite as _;
use ironrdp_graphics::image_processing::PixelFormat;
use ironrdp_session::ActiveStageOutput;
use ironrdp_session::image::DecodedImage;

const IDR: &[u8] = &[
    0, 0, 0, 1, 0x67, 0x4d, 0, 0x2a, 0, 0, 0, 1, 0x68, 0xee, 0, 0, 0, 1, 0x65, 0x88,
];
const P: &[u8] = &[0, 0, 0, 1, 0x41, 0x9a];

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn display_control_resize_restarts_the_surface() {
    let events: Arc<Mutex<Vec<CoreEvent>>> = Arc::default();
    let log = Arc::clone(&events);
    let config = ServerConfig {
        bind: "127.0.0.1:0".parse().unwrap(),
        username: "tester".to_owned(),
        password: "resize-test-password".to_owned(),
        identity: TlsIdentity::generate("resize-test.local").unwrap(),
        lan_only: true,
    };
    let server = server::start(
        config,
        Arc::new(move |e| log.lock().unwrap().push(e)),
        Arc::new(|_| {}),
    )
    .unwrap();
    let video = Arc::clone(server.video());
    let has = |pred: &dyn Fn(&CoreEvent) -> bool| events.lock().unwrap().iter().any(pred);

    let recorder = client::EgfxRecorder::default();
    let (result, mut session, _) = client::connect(
        server.local_addr(),
        "tester",
        "resize-test-password",
        1512,
        982,
        Some(&recorder),
    )
    .await
    .unwrap();
    let mut stage = client::active_stage(result);
    let mut image = DecodedImage::new(PixelFormat::RgbA32, 1512, 982);

    // Phase machine: wait for video start → first frame → resize → new-size frame.
    let mut step = 0;
    let mut resize_sent = None;
    let deadline = Instant::now() + Duration::from_secs(20);
    while step < 4 && Instant::now() < deadline {
        match step {
            0 if has(&|e| matches!(e, CoreEvent::VideoStart { .. })) => {
                assert_eq!(video.submit_h264(IDR, true, 1512, 982), SubmitResult::Sent);
                step = 1;
            }
            1 if recorder.frame_count() >= 1 => {
                // The Display Control channel may need a moment after EGFX; retry until it encodes.
                if let Some(bytes) = stage.encode_resize(1280, 800, Some(200), None) {
                    session.write_all(&bytes.unwrap()).await.unwrap();
                    resize_sent = Some(Instant::now());
                    step = 2;
                }
            }
            2 if has(&|e| {
                matches!(
                    e,
                    CoreEvent::VideoResize {
                        width: 1280,
                        height: 800,
                        scale_percent: 200
                    }
                )
            }) =>
            {
                assert_eq!(
                    video.submit_h264(P, false, 1512, 982),
                    SubmitResult::NotReady,
                    "stale size refused"
                );
                assert_eq!(
                    video.submit_h264(P, false, 1280, 800),
                    SubmitResult::NeedKeyframe,
                    "IDR first"
                );
                assert_eq!(video.submit_h264(IDR, true, 1280, 800), SubmitResult::Sent);
                step = 3;
            }
            3 if recorder.frame_count() >= 2 => step = 4,
            _ => {}
        }
        let Ok(read) = tokio::time::timeout(Duration::from_millis(100), session.read_pdu()).await
        else {
            continue;
        };
        let (action, payload) = read.unwrap();
        for out in stage.process(&mut image, action, &payload).unwrap() {
            if let ActiveStageOutput::ResponseFrame(bytes) = out {
                session.write_all(&bytes).await.unwrap();
            }
        }
    }
    assert_eq!(
        step,
        4,
        "stuck at step {step}; events: {:?}",
        events.lock().unwrap()
    );
    assert_eq!(
        *recorder.reset_size.lock().unwrap(),
        Some((1280, 800)),
        "ResetGraphics at the new size"
    );
    println!("resize round trip: {:?}", resize_sent.unwrap().elapsed());
    drop(session);
    server.stop();
}
