//! End-to-end security behaviour: failed-login lockout (refused before TLS), live password
//! change without restart, and host-initiated disconnect that keeps the server listening.

#[path = "support/client.rs"]
mod client;

use std::sync::{Arc, Mutex};
use std::time::Duration;

use clawtank_core::access::AccessPolicy;
use clawtank_core::events::{CoreEvent, RejectReason};
use clawtank_core::server::{self, ServerConfig, ServerHandle};
use clawtank_core::tls::TlsIdentity;

type Events = Arc<Mutex<Vec<CoreEvent>>>;

fn start(password: &str) -> (ServerHandle, Events) {
    let events: Events = Arc::default();
    let log = Arc::clone(&events);
    let config = ServerConfig {
        bind: "127.0.0.1:0".parse().unwrap(),
        username: "tester".to_owned(),
        password: password.to_owned(),
        identity: TlsIdentity::generate("security-test.local").unwrap(),
        policy: AccessPolicy::lan_only(),
    };
    let server = server::start(
        config,
        Arc::new(move |e| log.lock().unwrap().push(e)),
        Arc::new(|_| {}),
    )
    .unwrap();
    (server, events)
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

/// Waits until at least `n` events match (the predicate never re-locks `events`).
async fn wait_count(events: &Events, what: &str, n: usize, pred: impl Fn(&CoreEvent) -> bool) {
    for _ in 0..200 {
        if count(events, &pred) >= n {
            return;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!(
        "timed out waiting for {n}× {what}; events: {:?}",
        events.lock().unwrap()
    );
}

fn count(events: &Events, pred: impl Fn(&CoreEvent) -> bool) -> usize {
    events.lock().unwrap().iter().filter(|e| pred(e)).count()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn five_bad_passwords_lock_out_the_ip() {
    let (server, events) = start("right-password-123");
    let addr = server.local_addr();
    for i in 0..5 {
        let attempt = tokio::time::timeout(
            Duration::from_secs(10),
            client::connect(addr, "tester", "wrong", 800, 600, None),
        )
        .await;
        assert!(
            matches!(attempt, Ok(Err(_))),
            "attempt {i} must fail promptly"
        );
        wait_count(&events, "failure", i + 1, |e| {
            matches!(e, CoreEvent::ConnectionFailed { .. })
        })
        .await;
    }
    wait_for(&events, "LockedOut", |e| {
        matches!(e, CoreEvent::LockedOut { minutes: 5, .. })
    })
    .await;

    // Even the right password is refused now, before any TLS.
    let refused = tokio::time::timeout(
        Duration::from_secs(10),
        client::connect(addr, "tester", "right-password-123", 800, 600, None),
    )
    .await;
    assert!(
        matches!(refused, Ok(Err(_))),
        "locked-out connect must fail promptly"
    );
    wait_for(&events, "Rejected locked-out", |e| {
        matches!(
            e,
            CoreEvent::Rejected {
                reason: RejectReason::LockedOut,
                ..
            }
        )
    })
    .await;
    assert_eq!(
        count(&events, |e| matches!(e, CoreEvent::ClientConnected(_))),
        0
    );
    server.stop();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn password_change_and_disconnect_without_restart() {
    let (server, events) = start("old-password-123");
    let addr = server.local_addr();
    assert!(!server.disconnect_client(), "nothing to disconnect yet");

    server.set_credentials("tester".to_owned(), "new-password-456".to_owned());
    assert!(
        client::connect(addr, "tester", "old-password-123", 800, 600, None)
            .await
            .is_err(),
        "old refused"
    );
    let (result, mut session, _) =
        client::connect(addr, "tester", "new-password-456", 800, 600, None)
            .await
            .expect("new password works");
    wait_for(&events, "connected", |e| {
        matches!(e, CoreEvent::ClientConnected(_))
    })
    .await;

    // Keep the session alive in the background while the host disconnects it.
    let pump = tokio::spawn(async move {
        let _ = client::pump_until(result, &mut session, Duration::from_secs(10), || false).await;
    });
    assert!(server.disconnect_client());
    wait_for(&events, "disconnected", |e| {
        matches!(e, CoreEvent::ClientDisconnected { .. })
    })
    .await;
    let _ = tokio::time::timeout(Duration::from_secs(10), pump).await;

    // Still listening: a new client can connect.
    let again = client::connect(addr, "tester", "new-password-456", 800, 600, None).await;
    assert!(again.is_ok(), "server kept listening after disconnect");
    server.stop();
}
