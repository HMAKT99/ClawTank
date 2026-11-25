//! End-to-end test for clients without H.264 (the Windows App on Android/iOS advertises EGFX
//! with `AVC_DISABLED`). The server must keep the flag in the confirmed capabilities, never
//! send AVC420, report `VideoCodec::Raw`, and deliver raw frames as ClearCodec tiles that
//! decode back to the submitted pixels, sending only changed tiles afterwards.

#[path = "support/client.rs"]
mod client;

use std::sync::{Arc, Mutex};
use std::time::Duration;

use clawtank_core::events::CoreEvent;
use clawtank_core::server::{self, ServerConfig};
use clawtank_core::tls::TlsIdentity;
use clawtank_core::video::{SubmitResult, VideoCodec};
use ironrdp_egfx::pdu::{
    CapabilitiesV8Flags, CapabilitiesV10Flags, CapabilitiesV81Flags, CapabilitiesV104Flags,
    CapabilitySet,
};
use ironrdp_graphics::clearcodec::ClearCodecDecoder;

const USER: &str = "tester";
const PASSWORD: &str = "raw-video-test-password";
const W: u16 = 640;
const H: u16 = 400;
/// Row padding, like a CVPixelBuffer's bytesPerRow.
const STRIDE: usize = W as usize * 4 + 64;

const FAKE_IDR: &[u8] = &[0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00];

/// BGRA test image with row padding; `marker` paints a small square near (300, 200).
fn frame(marker: bool) -> Vec<u8> {
    let mut data = vec![0xEE; STRIDE * H as usize];
    for y in 0..H as usize {
        for x in 0..W as usize {
            let o = y * STRIDE + x * 4;
            let px = if marker && (300..310).contains(&x) && (200..205).contains(&y) {
                [0x10, 0x20, 0xF0, 0xFF]
            } else if x < 200 {
                [0x80, 0x40, 0x20, 0xFF] // flat area: long runs
            } else {
                [x as u8, y as u8, (x ^ y) as u8, 0xFF] // busy area
            };
            data[o..o + 4].copy_from_slice(&px);
        }
    }
    data
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn avc_disabled_client_gets_clearcodec_frames() {
    let events: Arc<Mutex<Vec<CoreEvent>>> = Arc::default();
    let log = Arc::clone(&events);
    let config = ServerConfig {
        bind: "127.0.0.1:0".parse().unwrap(),
        username: USER.to_owned(),
        password: PASSWORD.to_owned(),
        identity: TlsIdentity::generate("raw-video-test.local").unwrap(),
        policy: clawtank_core::access::AccessPolicy::lan_only(),
    };
    let server = server::start(
        config,
        Arc::new(move |e| log.lock().unwrap().push(e)),
        Arc::new(|_| {}),
    )
    .unwrap();
    let video = Arc::clone(server.video());

    // What the Windows App on Android/iOS advertises: AVC disabled everywhere.
    let recorder = client::EgfxRecorder {
        advertise: Some(vec![
            CapabilitySet::V8 {
                flags: CapabilitiesV8Flags::SMALL_CACHE,
            },
            CapabilitySet::V8_1 {
                flags: CapabilitiesV81Flags::SMALL_CACHE,
            },
            CapabilitySet::V10 {
                flags: CapabilitiesV10Flags::SMALL_CACHE | CapabilitiesV10Flags::AVC_DISABLED,
            },
            CapabilitySet::V10_4 {
                flags: CapabilitiesV104Flags::SMALL_CACHE | CapabilitiesV104Flags::AVC_DISABLED,
            },
        ]),
        ..Default::default()
    };
    let (result, mut session, _cert) =
        client::connect(server.local_addr(), USER, PASSWORD, W, H, Some(&recorder))
            .await
            .expect("connect with EGFX");

    let started = {
        let events = Arc::clone(&events);
        move || {
            events.lock().unwrap().iter().any(|e| {
                matches!(
                    e,
                    CoreEvent::VideoStart {
                        width: W,
                        height: H
                    }
                )
            })
        }
    };
    let first = frame(false);
    let second = frame(true);
    let ok = client::pump_until(result, &mut session, Duration::from_secs(15), {
        let video = Arc::clone(&video);
        let recorder = recorder.clone();
        let second = second.clone();
        let mut step = 0;
        move || {
            if !started() {
                return false;
            }
            match step {
                0 => {
                    assert_eq!(video.codec(), VideoCodec::Raw);
                    assert_eq!(
                        video.submit_h264(FAKE_IDR, true, W, H),
                        SubmitResult::NotReady,
                        "H.264 must never reach a client that disabled AVC"
                    );
                    assert_eq!(
                        video.submit_bgra(&first, W + 2, H, STRIDE),
                        SubmitResult::NotReady,
                        "stale size"
                    );
                    if video.submit_bgra(&first, W, H, STRIDE) == SubmitResult::Sent {
                        step = 1;
                    }
                    false
                }
                1 if recorder.frame_count() >= 1 => {
                    if video.submit_bgra(&second, W, H, STRIDE) == SubmitResult::Sent {
                        step = 2;
                    }
                    false
                }
                2 if recorder.frame_count() >= 2 => {
                    // Nothing changed: nothing to send, nothing owed.
                    assert_eq!(video.submit_bgra(&second, W, H, STRIDE), SubmitResult::Sent);
                    true
                }
                _ => false,
            }
        }
    })
    .await
    .expect("session");
    assert!(ok, "timed out; events: {:?}", events.lock().unwrap());

    assert_eq!(
        *recorder.confirmed.lock().unwrap(),
        Some(CapabilitySet::V10 {
            flags: CapabilitiesV10Flags::SMALL_CACHE | CapabilitiesV10Flags::AVC_DISABLED
        }),
        "AVC_DISABLED must survive negotiation"
    );
    assert!(
        recorder.bitstreams.lock().unwrap().is_empty(),
        "no AVC420 sent"
    );
    assert_eq!(
        *recorder.reset_size.lock().unwrap(),
        Some((W.into(), H.into()))
    );

    // Rebuild the picture from the tiles and compare with the last submitted frame.
    let tiles = recorder.clear_tiles.lock().unwrap().clone();
    let full_tiles = 10 * 6; // 640 = 10×64; 400 = 5×64 + 80 merged into the last row
    assert_eq!(
        tiles.len(),
        full_tiles + 1,
        "full frame, then only the changed tile"
    );
    let mut decoder = ClearCodecDecoder::new();
    let mut surface = vec![0u8; W as usize * H as usize * 4];
    for (i, (rect, data)) in tiles.iter().enumerate() {
        assert_eq!(
            usize::from(data[1]),
            i % 256,
            "ClearCodec seqNumber continuity"
        );
        let (tw, th) = (rect.right - rect.left, rect.bottom - rect.top);
        assert!(
            u32::from(tw) * u32::from(th) > 1024,
            "glyph cache stays unused"
        );
        let pixels = decoder
            .decode(data, tw, th)
            .expect("valid ClearCodec stream");
        for row in 0..usize::from(th) {
            let dst = ((usize::from(rect.top) + row) * W as usize + usize::from(rect.left)) * 4;
            let src = row * usize::from(tw) * 4;
            surface[dst..dst + usize::from(tw) * 4]
                .copy_from_slice(&pixels[src..src + usize::from(tw) * 4]);
        }
    }
    let last = &tiles[full_tiles].0;
    assert_eq!(
        (last.left, last.top, last.right, last.bottom),
        (256, 192, 320, 256)
    );
    for y in 0..H as usize {
        for x in 0..W as usize {
            let got = &surface[(y * W as usize + x) * 4..][..3];
            let want = &second[y * STRIDE + x * 4..][..3];
            assert_eq!(got, want, "pixel ({x}, {y})");
        }
    }

    drop(session);
    server.stop();
}
