//! Headless ClawTank RDP server for integration tests and debugging (no Swift app needed).
//!
//! Usage: `cargo run --example testserver -- [--bind 0.0.0.0] [--port 3389] [--user NAME]
//!         [--password PW] [--allow-wan]`
//! Logs go to stderr; core events are printed to stdout as `EVENT <kind> <detail>`, which
//! `tests/freerdp-smoke.sh` greps. Runs until killed.

use std::net::SocketAddr;
use std::sync::Arc;

use clawtank_core::events::CoreEvent;
use clawtank_core::server::{self, ServerConfig};
use clawtank_core::tls::TlsIdentity;

fn main() -> clawtank_core::Result<()> {
    let mut bind = "127.0.0.1".to_owned();
    let mut port = 3389u16;
    let mut user = "clawtank".to_owned();
    let mut password = "clawtank-test-password".to_owned();
    let mut lan_only = true;

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let mut value = || args.next().ok_or_else(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "--bind" => bind = value()?,
            "--port" => port = value()?.parse()?,
            "--user" => user = value()?,
            "--password" => password = value()?,
            "--allow-wan" => lan_only = false,
            other => return Err(format!("unknown argument {other}").into()),
        }
    }

    clawtank_core::logging::install(
        Box::new(|level, msg| eprintln!("{level:>5} {msg}")),
        &std::env::var("RUST_LOG").unwrap_or_else(|_| "info".to_owned()),
    );

    let identity = TlsIdentity::generate("clawtank-testserver.local")?;
    println!("FINGERPRINT {}", identity.fingerprint_sha256());

    let config = ServerConfig {
        bind: SocketAddr::new(bind.parse()?, port),
        username: user,
        password,
        identity,
        lan_only,
    };
    let _server = server::start(
        config,
        Arc::new(|event| {
            let line = match event {
                CoreEvent::Listening(a) => format!("listening {a}"),
                CoreEvent::Rejected(a) => format!("rejected {a}"),
                CoreEvent::ClientConnected(a) => format!("connected {a}"),
                CoreEvent::ClientDisconnected { peer, error } => {
                    format!("disconnected {peer} {error:?}")
                }
                CoreEvent::ConnectionFailed { peer, error } => format!("failed {peer} {error}"),
                CoreEvent::Stopped => "stopped".to_owned(),
                CoreEvent::Error(e) => format!("error {e}"),
                CoreEvent::VideoStart { width, height } => format!("video-start {width}x{height}"),
                CoreEvent::VideoStop => "video-stop".to_owned(),
            };
            println!("EVENT {line}");
        }),
        Arc::new(|event| println!("INPUT {event:?}")),
    )?;

    loop {
        std::thread::park();
    }
}
