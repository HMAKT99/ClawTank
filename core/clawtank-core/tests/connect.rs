//! End-to-end test: a real RDP client (IronRDP's client stack) connects to the ClawTank core
//! over TCP with TLS + NLA, receives the test frame, and disconnects. Also checks that a wrong
//! password is refused and that stopping the server releases the port.

#[path = "support/client.rs"]
mod client;

use std::net::{SocketAddr, TcpListener as StdTcpListener};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use clawtank_core::events::CoreEvent;
use clawtank_core::server::{self, ServerConfig, ServerHandle};
use clawtank_core::tls::TlsIdentity;

const USER: &str = "tester";
const PASSWORD: &str = "correct horse battery staple";
const WIDTH: u16 = 1024;
const HEIGHT: u16 = 768;

type Events = Arc<Mutex<Vec<CoreEvent>>>;

fn start_server(bind: SocketAddr) -> (ServerHandle, Events, TlsIdentity) {
    let events: Events = Arc::default();
    let log = Arc::clone(&events);
    let identity = TlsIdentity::generate("clawtank-test.local").unwrap();
    let config = ServerConfig {
        bind,
        username: USER.to_owned(),
        password: PASSWORD.to_owned(),
        identity: identity.clone(),
        lan_only: true,
    };
    let handle = server::start(config, Arc::new(move |e| log.lock().unwrap().push(e))).unwrap();
    (handle, events, identity)
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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn nla_client_receives_test_frame_and_disconnects() {
    let (server, events, identity) = start_server("127.0.0.1:0".parse().unwrap());
    let addr = server.local_addr();
    wait_for(&events, "Listening", |e| {
        matches!(e, CoreEvent::Listening(_))
    })
    .await;

    let (result, mut session, cert) = client::connect(addr, USER, PASSWORD, WIDTH, HEIGHT)
        .await
        .expect("NLA connection");
    assert_eq!(
        cert, identity.cert_der,
        "server must present the configured certificate"
    );
    assert_eq!(
        (result.desktop_size.width, result.desktop_size.height),
        (WIDTH, HEIGHT)
    );
    wait_for(&events, "ClientConnected", |e| {
        matches!(e, CoreEvent::ClientConnected(_))
    })
    .await;

    client::receive_test_pattern(result, &mut session, Duration::from_secs(20))
        .await
        .expect("test pattern");

    drop(session);
    wait_for(&events, "ClientDisconnected", |e| {
        matches!(e, CoreEvent::ClientDisconnected { .. })
    })
    .await;
    server.stop();
    assert_eq!(events.lock().unwrap().last(), Some(&CoreEvent::Stopped));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn wrong_password_is_refused() {
    let (server, events, _) = start_server("127.0.0.1:0".parse().unwrap());
    let addr = server.local_addr();

    let attempt = client::connect(addr, USER, "wrong password", WIDTH, HEIGHT).await;
    assert!(attempt.is_err(), "bad password must fail NLA");
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
    let (server, events, _) = start_server("127.0.0.1:0".parse().unwrap());
    let addr = server.local_addr();
    server.stop();
    assert_eq!(events.lock().unwrap().last(), Some(&CoreEvent::Stopped));
    StdTcpListener::bind(addr).expect("port must be free after stop");
}
