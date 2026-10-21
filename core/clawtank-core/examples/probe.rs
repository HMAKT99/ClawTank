//! Connects to a running ClawTank server like a real client (TLS + NLA), checks that the test
//! pattern arrives, and saves what it received as a BMP. For checking the app end to end.
//!
//! Usage: `CLAWTANK_PASSWORD=… cargo run --example probe -- <host:port> <user> [WxH] [out.bmp]`
//!        `CLAWTANK_PASSWORD=… cargo run --example probe -- <host:port> <user> WxH --egfx SECONDS`
//! The second form joins the Graphics Pipeline and prints H.264 frames/s and kbit/s once per
//! second (the live ScreenCaptureKit → VideoToolbox → EGFX path), plus totals.
//!        `CLAWTANK_PASSWORD=… cargo run --example probe -- <host:port> <user> WxH --input-demo OUTDIR`
//! The third form drives the Mac like a user: clicks the screen centre, types "clawtank!" and
//! "é", scrolls down 3 notches, middle-clicks, and saves every cursor shape received to OUTDIR.
//!        `… probe <host:port> <user> WxH --resize-demo W2xH2@SCALE OUTDIR`
//! The fourth form streams at WxH, saves the first keyframe, asks for W2xH2 over Display
//! Control, times how long until a keyframe at the new size arrives, and saves that one too.
//! The password comes from the environment so it never appears in the process list.

#[path = "../tests/support/client.rs"]
mod client;

use std::net::ToSocketAddrs as _;
use std::time::{Duration, Instant};

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (Some(addr), Some(user)) = (args.first(), args.get(1)) else {
        anyhow::bail!(
            "usage: probe <host:port> <user> [WxH] [out.bmp]  (password in CLAWTANK_PASSWORD)"
        );
    };
    let (width, height) = match args.get(2) {
        Some(size) => {
            let (w, h) = size
                .split_once('x')
                .ok_or_else(|| anyhow::anyhow!("size must be WxH"))?;
            (w.parse()?, h.parse()?)
        }
        None => (1280, 800),
    };
    let egfx_seconds = match (args.get(3).map(String::as_str), args.get(4)) {
        (Some("--egfx"), Some(secs)) => Some(secs.parse::<u64>()?),
        _ => None,
    };
    let out = args
        .get(3)
        .cloned()
        .unwrap_or_else(|| "probe.bmp".to_owned());
    let password =
        std::env::var("CLAWTANK_PASSWORD").map_err(|_| anyhow::anyhow!("set CLAWTANK_PASSWORD"))?;
    let addr = addr
        .to_socket_addrs()?
        .next()
        .ok_or_else(|| anyhow::anyhow!("cannot resolve {addr}"))?;

    if args.get(3).map(String::as_str) == Some("--resize-demo") {
        let spec = args
            .get(4)
            .ok_or_else(|| anyhow::anyhow!("--resize-demo needs W2xH2@SCALE"))?;
        let (size, scale) = spec.split_once('@').unwrap_or((spec, "100"));
        let (w2, h2) = size
            .split_once('x')
            .ok_or_else(|| anyhow::anyhow!("bad size {size}"))?;
        let out_dir = args.get(5).cloned().unwrap_or_else(|| ".".to_owned());
        let target = (w2.parse()?, h2.parse()?, scale.parse()?);
        return resize_demo(addr, user, &password, (width, height), target, &out_dir).await;
    }
    if args.get(3).map(String::as_str) == Some("--audio") {
        let seconds = args.get(4).map(|s| s.parse()).transpose()?.unwrap_or(4);
        return audio_demo(addr, user, &password, width, height, seconds).await;
    }
    if args.get(3).map(String::as_str) == Some("--input-demo") {
        let out_dir = args.get(4).cloned().unwrap_or_else(|| ".".to_owned());
        return input_demo(addr, user, &password, width, height, &out_dir).await;
    }
    if let Some(seconds) = egfx_seconds {
        return measure_egfx(addr, user, &password, width, height, seconds).await;
    }

    let started = Instant::now();
    let (result, mut session, cert) =
        client::connect(addr, user, &password, width, height, None).await?;
    println!("connected: TLS + NLA ok in {:?}", started.elapsed());
    println!(
        "desktop: {}x{}",
        result.desktop_size.width, result.desktop_size.height
    );
    println!("server certificate SHA-256: {}", fingerprint(&cert));

    let image = client::receive_test_pattern(result, &mut session, Duration::from_secs(20)).await?;
    println!(
        "test pattern received and verified in {:?}",
        started.elapsed()
    );
    write_bmp(
        &out,
        image.width(),
        image.height(),
        image.data(),
        image.stride(),
    )?;
    println!("saved {out}");
    drop(session);
    println!("disconnected");
    Ok(())
}

/// Joins EGFX and reports per-second H.264 frame count and bit rate for `seconds`.
async fn measure_egfx(
    addr: std::net::SocketAddr,
    user: &str,
    password: &str,
    width: u16,
    height: u16,
    seconds: u64,
) -> anyhow::Result<()> {
    let recorder = client::EgfxRecorder::default();
    let (result, mut session, _) =
        client::connect(addr, user, password, width, height, Some(&recorder)).await?;
    println!("connected with EGFX; measuring {seconds} s");
    let start = Instant::now();
    let (mut last_frames, mut last_bytes, mut next_tick) = (0u64, 0u64, 1u64);
    let mut first_frame: Option<Duration> = None;
    client::pump_until(result, &mut session, Duration::from_secs(seconds), || {
        let (frames, bytes) = (recorder.frame_count(), recorder.byte_count());
        if first_frame.is_none() && frames > 0 {
            first_frame = Some(start.elapsed());
        }
        if start.elapsed() >= Duration::from_secs(next_tick) {
            println!(
                "t={next_tick:>3}s  {:>3} fps  {:>8.1} kbit/s",
                frames - last_frames,
                (bytes - last_bytes) as f64 * 8.0 / 1000.0
            );
            (last_frames, last_bytes) = (frames, bytes);
            next_tick += 1;
        }
        false
    })
    .await?;
    let (frames, bytes) = (recorder.frame_count(), recorder.byte_count());
    let secs = start.elapsed().as_secs_f64();
    println!(
        "total: {frames} frames, {:.1} fps avg, {:.1} kbit/s avg, first frame after {:?}",
        frames as f64 / secs,
        bytes as f64 * 8.0 / 1000.0 / secs,
        first_frame
    );
    if let Some(first) = recorder.bitstreams.lock().unwrap().first() {
        let nal = first.get(4).map(|b| b & 0x1f);
        println!(
            "first bitstream: {} bytes, first NAL type {nal:?} (7 = SPS)",
            first.len()
        );
        if let Ok(path) = std::env::var("CLAWTANK_DUMP_H264") {
            std::fs::write(&path, first)?;
            println!("wrote first access unit to {path}");
        }
    }
    Ok(())
}

/// Answers the server for `duration`, collecting cursor shapes.
async fn pump_for(
    stage: &mut ironrdp_session::ActiveStage,
    session: &mut client::Session,
    image: &mut ironrdp_session::image::DecodedImage,
    duration: Duration,
    pointers: &mut Vec<std::sync::Arc<ironrdp_graphics::pointer::DecodedPointer>>,
) -> anyhow::Result<()> {
    use ironrdp_async::FramedWrite as _;
    let deadline = Instant::now() + duration;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Ok(());
        }
        let Ok(read) = tokio::time::timeout(remaining, session.read_pdu()).await else {
            return Ok(());
        };
        let (action, payload) = read?;
        for out in stage.process(image, action, &payload)? {
            match out {
                ironrdp_session::ActiveStageOutput::ResponseFrame(f) => {
                    session.write_all(&f).await?
                }
                ironrdp_session::ActiveStageOutput::PointerBitmap(p) => pointers.push(p),
                _ => {}
            }
        }
    }
}

async fn send(
    stage: &mut ironrdp_session::ActiveStage,
    session: &mut client::Session,
    image: &mut ironrdp_session::image::DecodedImage,
    events: &[ironrdp_pdu::input::fast_path::FastPathInputEvent],
) -> anyhow::Result<()> {
    use ironrdp_async::FramedWrite as _;
    for out in stage.process_fastpath_input(image, events)? {
        if let ironrdp_session::ActiveStageOutput::ResponseFrame(f) = out {
            session.write_all(&f).await?;
        }
    }
    Ok(())
}

async fn input_demo(
    addr: std::net::SocketAddr,
    user: &str,
    password: &str,
    width: u16,
    height: u16,
    out_dir: &str,
) -> anyhow::Result<()> {
    use ironrdp_pdu::input::MousePdu;
    use ironrdp_pdu::input::fast_path::{FastPathInputEvent as E, KeyboardFlags as K};
    use ironrdp_pdu::input::mouse::PointerFlags as P;
    let mouse = |flags, wheel, x, y| {
        E::MouseEvent(MousePdu {
            flags,
            number_of_wheel_rotation_units: wheel,
            x_position: x,
            y_position: y,
        })
    };
    let config = client::client_config_with(user, password, width, height, true);
    let (result, mut session, _) = client::connect_with(addr, config, None).await?;
    let mut stage = client::active_stage(result);
    let mut image = ironrdp_session::image::DecodedImage::new(
        ironrdp_graphics::image_processing::PixelFormat::RgbA32,
        width,
        height,
    );
    let mut pointers = Vec::new();
    let (cx, cy) = (width / 2, height / 2);
    let ms = Duration::from_millis;
    println!("connected; driving input");
    pump_for(
        &mut stage,
        &mut session,
        &mut image,
        ms(1500),
        &mut pointers,
    )
    .await?;

    // Click the centre of the screen (the test window's text box) to focus it.
    send(
        &mut stage,
        &mut session,
        &mut image,
        &[mouse(P::MOVE, 0, cx, cy)],
    )
    .await?;
    pump_for(&mut stage, &mut session, &mut image, ms(300), &mut pointers).await?;
    let click = [
        mouse(P::LEFT_BUTTON | P::DOWN, 0, cx, cy),
        mouse(P::LEFT_BUTTON, 0, cx, cy),
    ];
    send(&mut stage, &mut session, &mut image, &click).await?;
    pump_for(&mut stage, &mut session, &mut image, ms(500), &mut pointers).await?;

    // "clawtank" by scancode, then Shift+1 for "!", then "é" as a Unicode event.
    for code in [0x2e_u8, 0x26, 0x1e, 0x11, 0x14, 0x1e, 0x31, 0x25] {
        let key = [
            E::KeyboardEvent(K::empty(), code),
            E::KeyboardEvent(K::RELEASE, code),
        ];
        send(&mut stage, &mut session, &mut image, &key).await?;
        pump_for(&mut stage, &mut session, &mut image, ms(40), &mut pointers).await?;
    }
    let bang = [
        E::KeyboardEvent(K::empty(), 0x2a),
        E::KeyboardEvent(K::empty(), 0x02),
        E::KeyboardEvent(K::RELEASE, 0x02),
        E::KeyboardEvent(K::RELEASE, 0x2a),
        E::UnicodeKeyboardEvent(K::empty(), 0x00e9),
        E::UnicodeKeyboardEvent(K::RELEASE, 0x00e9),
    ];
    send(&mut stage, &mut session, &mut image, &bang).await?;
    pump_for(&mut stage, &mut session, &mut image, ms(500), &mut pointers).await?;

    // Scroll down three notches, then a middle click.
    for _ in 0..3 {
        let wheel = [mouse(P::VERTICAL_WHEEL | P::WHEEL_NEGATIVE, -120, cx, cy)];
        send(&mut stage, &mut session, &mut image, &wheel).await?;
        pump_for(&mut stage, &mut session, &mut image, ms(100), &mut pointers).await?;
    }
    let middle = [
        mouse(P::MIDDLE_BUTTON_OR_WHEEL | P::DOWN, 0, cx, cy),
        mouse(P::MIDDLE_BUTTON_OR_WHEEL, 0, cx, cy),
    ];
    send(&mut stage, &mut session, &mut image, &middle).await?;
    pump_for(
        &mut stage,
        &mut session,
        &mut image,
        ms(1000),
        &mut pointers,
    )
    .await?;

    println!("cursor shapes received: {}", pointers.len());
    for (i, p) in pointers.iter().enumerate() {
        let path = format!("{out_dir}/cursor-{i}.bmp");
        let stride = usize::from(p.width) * 4;
        write_bmp(&path, p.width, p.height, &p.bitmap_data, stride)?;
        println!(
            "  #{i}: {}x{} hotspot ({}, {}) -> {path}",
            p.width, p.height, p.hotspot_x, p.hotspot_y
        );
    }
    drop(session);
    println!("disconnected");
    Ok(())
}

async fn resize_demo(
    addr: std::net::SocketAddr,
    user: &str,
    password: &str,
    (width, height): (u16, u16),
    (w2, h2, scale): (u32, u32, u32),
    out_dir: &str,
) -> anyhow::Result<()> {
    use ironrdp_async::FramedWrite as _;
    let recorder = client::EgfxRecorder::default();
    let (result, mut session, _) =
        client::connect(addr, user, password, width, height, Some(&recorder)).await?;
    let mut stage = client::active_stage(result);
    let mut image = ironrdp_session::image::DecodedImage::new(
        ironrdp_graphics::image_processing::PixelFormat::RgbA32,
        width,
        height,
    );
    let started = Instant::now();
    let mut resized_at: Option<Instant> = None;
    let mut first_reset = None;
    while started.elapsed() < Duration::from_secs(20) {
        let streams = recorder.bitstreams.lock().unwrap().len();
        let reset = *recorder.reset_size.lock().unwrap();
        match resized_at {
            None if streams > 0 => {
                std::fs::write(
                    format!("{out_dir}/before.h264"),
                    &recorder.bitstreams.lock().unwrap()[0],
                )?;
                println!(
                    "first frame at {width}x{height} after {:?} (ResetGraphics {reset:?})",
                    started.elapsed()
                );
                first_reset = reset;
                if let Some(bytes) = stage.encode_resize(w2, h2, Some(scale), None) {
                    session.write_all(&bytes?).await?;
                    recorder.bitstreams.lock().unwrap().clear();
                    resized_at = Some(Instant::now());
                    println!("requested {w2}x{h2} @ {scale}%");
                }
            }
            Some(t) if streams > 0 && reset == Some((w2, h2)) && reset != first_reset => {
                std::fs::write(
                    format!("{out_dir}/after.h264"),
                    &recorder.bitstreams.lock().unwrap()[0],
                )?;
                println!(
                    "first frame at {w2}x{h2} {:?} after the request (ResetGraphics {reset:?})",
                    t.elapsed()
                );
                return Ok(());
            }
            _ => {}
        }
        let Ok(read) = tokio::time::timeout(Duration::from_millis(50), session.read_pdu()).await
        else {
            continue;
        };
        let (action, payload) = read?;
        for out in stage.process(&mut image, action, &payload)? {
            if let ironrdp_session::ActiveStageOutput::ResponseFrame(f) = out {
                session.write_all(&f).await?;
            }
        }
    }
    anyhow::bail!("timed out (resize requested: {})", resized_at.is_some())
}

#[derive(Debug)]
struct AudioProbe {
    bytes: std::sync::Arc<std::sync::atomic::AtomicU64>,
    peak: std::sync::Arc<std::sync::atomic::AtomicU64>,
    formats: Vec<ironrdp_rdpsnd::pdu::AudioFormat>,
}

impl ironrdp_rdpsnd::client::RdpsndClientHandler for AudioProbe {
    fn get_formats(&self) -> &[ironrdp_rdpsnd::pdu::AudioFormat] {
        &self.formats
    }
    fn wave(&mut self, _format_no: usize, _ts: u32, data: std::borrow::Cow<'_, [u8]>) {
        use std::sync::atomic::Ordering;
        self.bytes.fetch_add(data.len() as u64, Ordering::Relaxed);
        let peak = data
            .as_chunks::<2>()
            .0
            .iter()
            .map(|s| u64::from(i16::from_le_bytes(*s).unsigned_abs()))
            .max()
            .unwrap_or(0);
        self.peak.fetch_max(peak, Ordering::Relaxed);
    }
    fn set_volume(&mut self, _v: ironrdp_rdpsnd::pdu::VolumePdu) {}
    fn set_pitch(&mut self, _p: ironrdp_rdpsnd::pdu::PitchPdu) {}
    fn close(&mut self) {}
}

/// Receives system audio for `seconds`, printing kbit/s and peak level each second.
async fn audio_demo(
    addr: std::net::SocketAddr,
    user: &str,
    password: &str,
    width: u16,
    height: u16,
    seconds: u64,
) -> anyhow::Result<()> {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU64, Ordering};
    let (bytes, peak) = (Arc::new(AtomicU64::new(0)), Arc::new(AtomicU64::new(0)));
    let probe = AudioProbe {
        bytes: Arc::clone(&bytes),
        peak: Arc::clone(&peak),
        formats: vec![ironrdp_rdpsnd::pdu::AudioFormat {
            format: ironrdp_rdpsnd::pdu::WaveFormat::PCM,
            n_channels: 2,
            n_samples_per_sec: 48_000,
            n_avg_bytes_per_sec: 192_000,
            n_block_align: 4,
            bits_per_sample: 16,
            data: None,
        }],
    };
    let mut config = client::client_config(user, password, width, height);
    config.enable_audio_playback = true;
    let (result, mut session, _) = client::connect_with_channels(addr, config, None, move |c| {
        c.attach_static_channel(ironrdp_rdpsnd::client::Rdpsnd::new(Box::new(probe)));
    })
    .await?;
    println!("connected with audio; listening {seconds} s");
    let start = Instant::now();
    let (mut last, mut tick) = (0u64, 1u64);
    client::pump_until(result, &mut session, Duration::from_secs(seconds), || {
        if start.elapsed() >= Duration::from_secs(tick) {
            let now = bytes.load(Ordering::Relaxed);
            println!(
                "t={tick}s  {:.0} kbit/s  peak {}",
                (now - last) as f64 * 8.0 / 1000.0,
                peak.swap(0, Ordering::Relaxed)
            );
            (last, tick) = (now, tick + 1);
        }
        false
    })
    .await?;
    println!("total audio bytes: {}", bytes.load(Ordering::Relaxed));
    Ok(())
}

fn fingerprint(cert_der: &[u8]) -> String {
    clawtank_core::tls::TlsIdentity {
        cert_der: cert_der.to_vec(),
        key_pkcs8_der: Vec::new(),
    }
    .fingerprint_sha256()
}

/// Writes RGBA pixels as a 24-bit bottom-up BMP (no image crate needed).
fn write_bmp(
    path: &str,
    width: u16,
    height: u16,
    rgba: &[u8],
    stride: usize,
) -> std::io::Result<()> {
    let (w, h) = (usize::from(width), usize::from(height));
    let row = (w * 3).div_ceil(4) * 4;
    let size = 54 + row * h;
    let mut out = Vec::with_capacity(size);
    out.extend_from_slice(b"BM");
    out.extend_from_slice(&(size as u32).to_le_bytes());
    out.extend_from_slice(&[0; 4]);
    out.extend_from_slice(&54u32.to_le_bytes());
    out.extend_from_slice(&40u32.to_le_bytes());
    out.extend_from_slice(&(w as i32).to_le_bytes());
    out.extend_from_slice(&(h as i32).to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&24u16.to_le_bytes());
    out.extend_from_slice(&[0; 24]);
    for y in (0..h).rev() {
        let start = out.len();
        for x in 0..w {
            let i = y * stride + x * 4;
            out.extend_from_slice(&[rgba[i + 2], rgba[i + 1], rgba[i]]);
        }
        out.resize(start + row, 0);
    }
    std::fs::write(path, out)
}
