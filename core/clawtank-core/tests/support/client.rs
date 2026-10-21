// Shared by several test binaries and an example; each uses a different subset.
#![allow(dead_code)]

//! Minimal RDP client built on IronRDP's client crates, shared by the integration tests and
//! the `probe` example. It connects with TLS + NLA, optionally joins the EGFX graphics
//! pipeline (recording the H.264 bitstreams it receives instead of decoding them), and either
//! reads legacy updates until the image matches ClawTank's test pattern or pumps the session.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use clawtank_core::test_pattern::expected_rgb;
use clawtank_core::tls::TlsIdentity;
use ironrdp_async::FramedWrite as _;
use ironrdp_connector::{ClientConnector, ConnectionResult, Credentials};
use ironrdp_dvc::DrdynvcClient;
use ironrdp_egfx::client::{GraphicsPipelineClient, GraphicsPipelineHandler};
use ironrdp_egfx::decode::{DecodedFrame, DecoderResult, H264Decoder};
use ironrdp_graphics::image_processing::PixelFormat;
use ironrdp_pdu::gcc::KeyboardType;
use ironrdp_pdu::rdp::capability_sets::MajorPlatformType;
use ironrdp_pdu::rdp::client_info::{PerformanceFlags, TimezoneInfo};
use ironrdp_session::image::DecodedImage;
use ironrdp_session::{ActiveStageBuilder, ActiveStageOutput};
use ironrdp_tokio::reqwest::ReqwestNetworkClient;
use tokio::net::TcpStream;
use tokio_rustls::client::TlsStream;
use tokio_rustls::rustls;

/// Max per-channel difference accepted between sent and decoded pixels (the server may pick a
/// lossy codec such as RemoteFX).
pub const CODEC_TOLERANCE: u8 = 8;

pub type Session = ironrdp_tokio::TokioFramed<TlsStream<TcpStream>>;

pub fn client_config(
    user: &str,
    password: &str,
    width: u16,
    height: u16,
) -> ironrdp_connector::Config {
    ironrdp_connector::Config {
        desktop_size: ironrdp_connector::DesktopSize { width, height },
        desktop_scale_factor: 0,
        enable_tls: false,
        enable_credssp: true,
        credentials: Credentials::UsernamePassword {
            username: user.to_owned(),
            password: password.to_owned(),
        },
        domain: None,
        client_build: 0,
        client_name: "clawtank-probe".to_owned(),
        keyboard_type: KeyboardType::IbmEnhanced,
        keyboard_subtype: 0,
        keyboard_functional_keys_count: 12,
        keyboard_layout: 0,
        ime_file_name: String::new(),
        bitmap: None,
        dig_product_id: String::new(),
        client_dir: String::new(),
        alternate_shell: String::new(),
        work_dir: String::new(),
        platform: MajorPlatformType::MACINTOSH,
        hardware_id: None,
        request_data: None,
        autologon: false,
        enable_audio_playback: false,
        performance_flags: PerformanceFlags::default(),
        license_cache: None,
        timezone_info: TimezoneInfo::default(),
        compression_type: None,
        enable_server_pointer: false,
        pointer_software_rendering: true,
        multitransport_flags: None,
    }
}

/// What the EGFX side of the client observed. Cheap to clone; shared with the channel.
#[derive(Clone, Default)]
pub struct EgfxRecorder {
    /// The first few AVC420 bitstreams received (Annex-B bytes as sent by the server).
    pub bitstreams: Arc<Mutex<Vec<Vec<u8>>>>,
    pub bytes: Arc<AtomicU64>,
    /// EndFrame count (frames fully delivered, whatever the codec).
    pub frames: Arc<AtomicU64>,
    /// Size from the last ResetGraphics.
    pub reset_size: Arc<Mutex<Option<(u32, u32)>>>,
}

impl EgfxRecorder {
    pub fn frame_count(&self) -> u64 {
        self.frames.load(Ordering::Acquire)
    }

    pub fn byte_count(&self) -> u64 {
        self.bytes.load(Ordering::Acquire)
    }
}

struct RecordingHandler(EgfxRecorder);

impl GraphicsPipelineHandler for RecordingHandler {
    fn on_reset_graphics(&mut self, width: u32, height: u32) {
        *self.0.reset_size.lock().unwrap() = Some((width, height));
    }

    fn on_frame_complete(&mut self, _frame_id: u32) {
        self.0.frames.fetch_add(1, Ordering::AcqRel);
    }
}

/// Stands in for an H.264 decoder: records the bitstream and returns a blank frame.
struct RecordingDecoder(EgfxRecorder);

impl H264Decoder for RecordingDecoder {
    fn decode(&mut self, data: &[u8]) -> DecoderResult<DecodedFrame> {
        self.0.bytes.fetch_add(data.len() as u64, Ordering::AcqRel);
        let mut streams = self.0.bitstreams.lock().unwrap();
        // Keep memory bounded on long probe runs: only the first few are kept for inspection.
        if streams.len() < 8 {
            streams.push(data.to_vec());
        }
        let (w, h) = self.0.reset_size.lock().unwrap().unwrap_or((8192, 8192));
        let (w, h) = (w.div_ceil(16) * 16, h.div_ceil(16) * 16);
        Ok(DecodedFrame::new(vec![0; (w * h * 4) as usize], w, h))
    }

    fn reset(&mut self) {}
}

/// Connects with TLS + NLA. Returns the negotiated session and the server certificate DER.
/// With `egfx`, the client also offers the Graphics Pipeline (AVC420) and records into it.
pub async fn connect(
    addr: SocketAddr,
    user: &str,
    password: &str,
    width: u16,
    height: u16,
    egfx: Option<&EgfxRecorder>,
) -> anyhow::Result<(ConnectionResult, Session, Vec<u8>)> {
    let server_name = "clawtank-server";
    let tcp = TcpStream::connect(addr).await?;
    let client_addr = tcp.local_addr()?;
    let mut framed = ironrdp_tokio::TokioFramed::new(tcp);
    let mut connector =
        ClientConnector::new(client_config(user, password, width, height), client_addr);
    if let Some(recorder) = egfx {
        let gfx = GraphicsPipelineClient::new(
            Box::new(RecordingHandler(recorder.clone())),
            Some(Box::new(RecordingDecoder(recorder.clone()))),
        );
        connector.attach_static_channel(DrdynvcClient::new().with_dynamic_channel(gfx));
    }

    let should_upgrade = ironrdp_async::connect_begin(&mut framed, &mut connector).await?;
    let tcp = framed.into_inner_no_leftover();

    let tls_config = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::aws_lc_rs::default_provider(),
    ))
    .with_safe_default_protocol_versions()?
    .dangerous()
    .with_custom_certificate_verifier(Arc::new(AcceptAnyCert))
    .with_no_client_auth();
    let tls = tokio_rustls::TlsConnector::from(Arc::new(tls_config))
        .connect(server_name.try_into()?, tcp)
        .await?;
    let cert_der = tls
        .get_ref()
        .1
        .peer_certificates()
        .and_then(|c| c.first())
        .ok_or_else(|| anyhow::anyhow!("no server certificate"))?
        .to_vec();
    let server_public_key = TlsIdentity {
        cert_der: cert_der.clone(),
        key_pkcs8_der: Vec::new(),
    }
    .public_key()
    .map_err(|e| anyhow::anyhow!("{e}"))?;

    let upgraded = ironrdp_async::mark_as_upgraded(should_upgrade, &mut connector);
    let mut framed = ironrdp_tokio::TokioFramed::new(tls);
    let result = ironrdp_async::connect_finalize(
        upgraded,
        connector,
        &mut framed,
        &mut ReqwestNetworkClient::new(),
        server_name.into(),
        server_public_key,
        None,
    )
    .await?;
    Ok((result, framed, cert_der))
}

fn active_stage(result: ConnectionResult) -> ironrdp_session::ActiveStage {
    ActiveStageBuilder {
        static_channels: result.static_channels,
        user_channel_id: result.user_channel_id,
        io_channel_id: result.io_channel_id,
        message_channel_id: result.message_channel_id,
        share_id: result.share_id,
        compression_type: None,
        enable_server_pointer: result.enable_server_pointer,
        pointer_software_rendering: result.pointer_software_rendering,
    }
    .build()
}

/// Drives the session (answering the server, feeding channels) until `done()` returns true,
/// the server ends the session, or `timeout` passes. Returns whether `done()` was reached.
pub async fn pump_until(
    result: ConnectionResult,
    framed: &mut Session,
    timeout: Duration,
    mut done: impl FnMut() -> bool,
) -> anyhow::Result<bool> {
    let (width, height) = (result.desktop_size.width, result.desktop_size.height);
    let mut stage = active_stage(result);
    let mut image = DecodedImage::new(PixelFormat::RgbA32, width, height);
    let deadline = Instant::now() + timeout;
    while !done() {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Ok(false);
        }
        // Wake periodically so `done()` is re-checked even when the server is quiet.
        let read =
            tokio::time::timeout(remaining.min(Duration::from_millis(200)), framed.read_pdu())
                .await;
        let Ok(read) = read else { continue };
        let (action, payload) = read?;
        for out in stage.process(&mut image, action, &payload)? {
            match out {
                ActiveStageOutput::ResponseFrame(frame) => framed.write_all(&frame).await?,
                ActiveStageOutput::Terminate(reason) => {
                    anyhow::bail!("server terminated: {reason:?}")
                }
                _ => {}
            }
        }
    }
    Ok(true)
}

/// Reads graphics updates until the image matches the test pattern, or `timeout` passes.
/// On timeout the error describes the sampled pixels. Returns the decoded RGBA image.
pub async fn receive_test_pattern(
    result: ConnectionResult,
    framed: &mut Session,
    timeout: Duration,
) -> anyhow::Result<DecodedImage> {
    let (width, height) = (result.desktop_size.width, result.desktop_size.height);
    let mut stage = active_stage(result);
    let mut image = DecodedImage::new(PixelFormat::RgbA32, width, height);
    let mut updates = 0u32;

    let outcome = tokio::time::timeout(timeout, async {
        loop {
            let (action, payload) = framed.read_pdu().await?;
            for out in stage.process(&mut image, action, &payload)? {
                match out {
                    ActiveStageOutput::ResponseFrame(frame) => framed.write_all(&frame).await?,
                    ActiveStageOutput::GraphicsUpdate(_) => {
                        updates += 1;
                        if frame_matches(&image) {
                            return anyhow::Ok(());
                        }
                    }
                    ActiveStageOutput::Terminate(reason) => {
                        anyhow::bail!("server terminated: {reason:?}")
                    }
                    _ => {}
                }
            }
        }
    })
    .await;
    match outcome {
        Ok(Ok(())) => Ok(image),
        Ok(Err(e)) => Err(e),
        Err(_) => anyhow::bail!(
            "no matching frame within {timeout:?} after {updates} graphics updates; sampled: {}",
            describe_samples(&image)
        ),
    }
}

fn sample_points(w: u32, h: u32) -> [(u32, u32); 6] {
    [
        (5, 5),
        (w / 2, h / 3),
        (w - 5, 10),
        (10, h - 5),
        (w / 2, h - 5),
        (w - 5, h - 5),
    ]
}

pub fn frame_matches(image: &DecodedImage) -> bool {
    let (w, h) = (u32::from(image.width()), u32::from(image.height()));
    let (data, stride) = (image.data(), image.stride());
    sample_points(w, h).into_iter().all(|(x, y)| {
        let i = y as usize * stride + x as usize * 4;
        let (r, g, b) = expected_rgb(x, y, w, h);
        data[i..i + 3]
            .iter()
            .zip([r, g, b])
            .all(|(&got, want)| got.abs_diff(want) <= CODEC_TOLERANCE)
    })
}

/// "(x,y) got [r,g,b,a] want (r,g,b)" for each sample point, to diagnose mismatches.
pub fn describe_samples(image: &DecodedImage) -> String {
    let (w, h) = (u32::from(image.width()), u32::from(image.height()));
    let (data, stride) = (image.data(), image.stride());
    sample_points(w, h)
        .into_iter()
        .map(|(x, y)| {
            let i = y as usize * stride + x as usize * 4;
            format!(
                "({x},{y}) got {:?} want {:?}",
                &data[i..i + 4],
                expected_rgb(x, y, w, h)
            )
        })
        .collect::<Vec<_>>()
        .join("; ")
}

/// Trusts the self-signed server certificate (real clients prompt the user instead).
#[derive(Debug)]
pub struct AcceptAnyCert;

impl rustls::client::danger::ServerCertVerifier for AcceptAnyCert {
    fn verify_server_cert(
        &self,
        _: &rustls::pki_types::CertificateDer<'_>,
        _: &[rustls::pki_types::CertificateDer<'_>],
        _: &rustls::pki_types::ServerName<'_>,
        _: &[u8],
        _: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        let algs = rustls::crypto::aws_lc_rs::default_provider().signature_verification_algorithms;
        rustls::crypto::verify_tls12_signature(message, cert, dss, &algs)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        let algs = rustls::crypto::aws_lc_rs::default_provider().signature_verification_algorithms;
        rustls::crypto::verify_tls13_signature(message, cert, dss, &algs)
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        rustls::crypto::aws_lc_rs::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}
