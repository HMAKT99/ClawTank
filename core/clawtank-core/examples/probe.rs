//! Connects to a running ClawTank server like a real client (TLS + NLA), checks that the test
//! pattern arrives, and saves what it received as a BMP. For checking the app end to end.
//!
//! Usage: `CLAWTANK_PASSWORD=… cargo run --example probe -- <host:port> <user> [WxH] [out.bmp]`
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

    let started = Instant::now();
    let (result, mut session, cert) = client::connect(addr, user, &password, width, height).await?;
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
