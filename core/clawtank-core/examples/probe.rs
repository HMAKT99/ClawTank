//! Connects to a running ClawTank server like a real client (TLS + NLA), checks that the test
//! pattern arrives, and saves what it received as a BMP. For checking the app end to end.
//!
//! Usage: `CLAWTANK_PASSWORD=… cargo run --example probe -- <host:port> <user> [WxH] [out.bmp]`
//!        `CLAWTANK_PASSWORD=… cargo run --example probe -- <host:port> <user> WxH --egfx SECONDS`
//! The second form joins the Graphics Pipeline and prints H.264 frames/s and kbit/s once per
//! second (the live ScreenCaptureKit → VideoToolbox → EGFX path), plus totals.
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
