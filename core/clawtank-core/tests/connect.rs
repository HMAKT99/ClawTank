//! End-to-end test: a real RDP client (IronRDP's client stack) connects to the ClawTank core
//! over TCP with TLS + NLA, receives the test frame, and disconnects. Also checks that a wrong
//! password is refused and that stopping the server releases the port.

use std::net::{SocketAddr, TcpListener as StdTcpListener};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use clawtank_core::events::CoreEvent;
use clawtank_core::server::{self, ServerConfig, ServerHandle};
use clawtank_core::test_pattern::expected_rgb;
use clawtank_core::tls::TlsIdentity;
use ironrdp_async::FramedWrite as _;
use ironrdp_connector::{ClientConnector, ConnectionResult, Credentials};
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

const USER: &str = "tester";
const PASSWORD: &str = "correct horse battery staple";
const WIDTH: u16 = 1024;
const HEIGHT: u16 = 768;
/// Max per-channel difference accepted between sent and decoded pixels.
const CODEC_TOLERANCE: u8 = 8;

type Events = Arc<Mutex<Vec<CoreEvent>>>;

fn start_server(bind: SocketAddr) -> (ServerHandle, Events) {
    let events: Events = Arc::default();
    let log = Arc::clone(&events);
    let config = ServerConfig {
        bind,
        username: USER.to_owned(),
        password: PASSWORD.to_owned(),
        identity: TlsIdentity::generate("clawtank-test.local").unwrap(),
        lan_only: true,
    };
    let handle = server::start(config, Arc::new(move |e| log.lock().unwrap().push(e))).unwrap();
    (handle, events)
}

async fn wait_for(events: &Events, what: &str, pred: impl Fn(&CoreEvent) -> bool) {
    for _ in 0..200 {
        if events.lock().unwrap().iter().any(&pred) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!(
        "timed out waiting for {what}; events: {:?}",
        events.lock().unwrap()
    );
}

fn client_config(password: &str) -> ironrdp_connector::Config {
    ironrdp_connector::Config {
        desktop_size: ironrdp_connector::DesktopSize {
            width: WIDTH,
            height: HEIGHT,
        },
        desktop_scale_factor: 0,
        enable_tls: false,
        enable_credssp: true,
        credentials: Credentials::UsernamePassword {
            username: USER.to_owned(),
            password: password.to_owned(),
        },
        domain: None,
        client_build: 0,
        client_name: "clawtank-test".to_owned(),
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

type Upgraded = ironrdp_tokio::TokioFramed<TlsStream<TcpStream>>;

async fn connect(addr: SocketAddr, password: &str) -> anyhow::Result<(ConnectionResult, Upgraded)> {
    let tcp = TcpStream::connect(addr).await?;
    let client_addr = tcp.local_addr()?;
    let mut framed = ironrdp_tokio::TokioFramed::new(tcp);
    let mut connector = ClientConnector::new(client_config(password), client_addr);

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
        .connect("clawtank-test.local".try_into()?, tcp)
        .await?;
    let cert = tls
        .get_ref()
        .1
        .peer_certificates()
        .and_then(|c| c.first())
        .cloned();
    let server_public_key = TlsIdentity {
        cert_der: cert
            .ok_or_else(|| anyhow::anyhow!("no server certificate"))?
            .to_vec(),
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
        "clawtank-test.local".into(),
        server_public_key,
        None,
    )
    .await?;
    Ok((result, framed))
}

fn frame_matches(image: &DecodedImage) -> bool {
    let (w, h) = (u32::from(image.width()), u32::from(image.height()));
    let data = image.data();
    let stride = image.stride();
    sample_points(w, h).into_iter().all(|(x, y)| {
        let i = y as usize * stride + x as usize * 4;
        let (r, g, b) = expected_rgb(x, y, w, h);
        // The server may pick a lossy codec (RemoteFX), so allow small per-channel error.
        data[i..i + 3]
            .iter()
            .zip([r, g, b])
            .all(|(&got, want)| got.abs_diff(want) <= CODEC_TOLERANCE)
    })
}

/// "(x,y) got [r,g,b,a] want (r,g,b)" for each sample point, to diagnose mismatches.
fn describe_samples(image: &DecodedImage) -> String {
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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn nla_client_receives_test_frame_and_disconnects() {
    let (server, events) = start_server("127.0.0.1:0".parse().unwrap());
    let addr = server.local_addr();
    wait_for(&events, "Listening", |e| {
        matches!(e, CoreEvent::Listening(_))
    })
    .await;

    let (result, mut framed) = connect(addr, PASSWORD).await.expect("NLA connection");
    assert_eq!(
        (result.desktop_size.width, result.desktop_size.height),
        (WIDTH, HEIGHT)
    );
    wait_for(&events, "ClientConnected", |e| {
        matches!(e, CoreEvent::ClientConnected(_))
    })
    .await;

    let mut stage = ActiveStageBuilder {
        static_channels: result.static_channels,
        user_channel_id: result.user_channel_id,
        io_channel_id: result.io_channel_id,
        message_channel_id: result.message_channel_id,
        share_id: result.share_id,
        compression_type: None,
        enable_server_pointer: result.enable_server_pointer,
        pointer_software_rendering: result.pointer_software_rendering,
    }
    .build();
    let mut image = DecodedImage::new(PixelFormat::RgbA32, WIDTH, HEIGHT);

    let mut updates = 0u32;
    let received = tokio::time::timeout(Duration::from_secs(20), async {
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
    if received.is_err() {
        panic!(
            "no matching frame within 20 s after {updates} graphics updates; sampled pixels: {}",
            describe_samples(&image)
        );
    }
    received.unwrap().expect("session error");

    drop(framed);
    wait_for(&events, "ClientDisconnected", |e| {
        matches!(e, CoreEvent::ClientDisconnected { .. })
    })
    .await;
    server.stop();
    assert_eq!(events.lock().unwrap().last(), Some(&CoreEvent::Stopped));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn wrong_password_is_refused() {
    let (server, events) = start_server("127.0.0.1:0".parse().unwrap());
    let addr = server.local_addr();

    assert!(
        connect(addr, "wrong password").await.is_err(),
        "bad password must fail NLA"
    );
    wait_for(&events, "ConnectionFailed", |e| {
        matches!(e, CoreEvent::ConnectionFailed { .. })
    })
    .await;
    assert!(
        !events
            .lock()
            .unwrap()
            .iter()
            .any(|e| matches!(e, CoreEvent::ClientConnected(_))),
        "session must not start"
    );
    server.stop();
}

#[test]
fn stop_releases_the_port() {
    let (server, events) = start_server("127.0.0.1:0".parse().unwrap());
    let addr = server.local_addr();
    server.stop();
    assert_eq!(events.lock().unwrap().last(), Some(&CoreEvent::Stopped));
    StdTcpListener::bind(addr).expect("port must be free after stop");
}

/// The test trusts the self-signed server certificate (real clients prompt the user).
#[derive(Debug)]
struct AcceptAnyCert;

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
