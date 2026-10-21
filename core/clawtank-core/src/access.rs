//! Connection access policy and session lifecycle events.
//!
//! ClawTank is LAN-only by default: [`is_lan_addr`] decides which peers may even start a
//! handshake, and [`SessionTracker`] enforces it in the accept loop, before any TLS or NLA
//! work. The same tracker turns the connection lifecycle into [`CoreEvent`]s for the host.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

use tracing::{info, warn};

use crate::events::{CoreEvent, EventSink};

/// True for addresses that can only originate on a local or private network: loopback,
/// RFC 1918, IPv4 link-local, CGNAT 100.64/10 (used by Tailscale), IPv6 ULA and link-local.
/// IPv4-mapped IPv6 addresses are judged by their IPv4 form.
pub fn is_lan_addr(ip: IpAddr) -> bool {
    match ip.to_canonical() {
        IpAddr::V4(v4) => v4.is_loopback() || v4.is_private() || v4.is_link_local() || is_cgnat(v4),
        IpAddr::V6(v6) => v6.is_loopback() || is_ula(v6) || is_v6_link_local(v6),
    }
}

fn is_cgnat(ip: Ipv4Addr) -> bool {
    let [a, b, ..] = ip.octets();
    a == 100 && (64..=127).contains(&b)
}

fn is_ula(ip: Ipv6Addr) -> bool {
    ip.segments()[0] & 0xfe00 == 0xfc00
}

fn is_v6_link_local(ip: Ipv6Addr) -> bool {
    ip.segments()[0] & 0xffc0 == 0xfe80
}

/// Enforces the access policy and tracks the current session for lifecycle events.
///
/// Shared between the accept loop (which calls [`accept`](Self::accept) and
/// [`finished`](Self::finished)) and the display source (which calls
/// [`session_started`](Self::session_started) once the client has authenticated: IronRDP only
/// asks the display for updates after TLS + NLA and capability exchange succeed).
pub struct SessionTracker {
    lan_only: bool,
    sink: EventSink,
    current: Mutex<Option<SocketAddr>>,
    started: AtomicBool,
}

impl SessionTracker {
    pub fn new(lan_only: bool, sink: EventSink) -> Self {
        Self {
            lan_only,
            sink,
            current: Mutex::new(None),
            started: AtomicBool::new(false),
        }
    }

    /// Applies the access policy to a new TCP peer. `false` means drop the stream.
    pub fn accept(&self, peer: SocketAddr) -> bool {
        if self.lan_only && !is_lan_addr(peer.ip()) {
            warn!(%peer, "Rejected non-LAN peer (LAN-only mode)");
            (self.sink)(CoreEvent::Rejected(peer));
            return false;
        }
        info!(%peer, "Accepted TCP connection");
        *self.current.lock().unwrap_or_else(|e| e.into_inner()) = Some(peer);
        self.started.store(false, Ordering::Release);
        true
    }

    /// Called by the display source when the session's update stream begins.
    pub fn session_started(&self) {
        let peer = *self.current.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(peer) = peer
            && !self.started.swap(true, Ordering::AcqRel)
        {
            info!(%peer, "Client authenticated and connected");
            (self.sink)(CoreEvent::ClientConnected(peer));
        }
    }

    /// Called when a connection ends, with its error if any.
    pub fn finished(&self, peer: SocketAddr, error: Option<String>) {
        if self.started.swap(false, Ordering::AcqRel) {
            info!(%peer, ?error, "Client disconnected");
            (self.sink)(CoreEvent::ClientDisconnected { peer, error });
        } else {
            warn!(%peer, ?error, "Connection failed before the session started");
            (self.sink)(CoreEvent::ConnectionFailed {
                peer,
                error: error.unwrap_or_else(|| "closed during handshake".to_owned()),
            });
        }
        *self.current.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lan(s: &str) -> bool {
        is_lan_addr(s.parse().unwrap())
    }

    #[test]
    fn lan_addresses_are_allowed() {
        for a in [
            "127.0.0.1",
            "10.1.2.3",
            "172.16.0.1",
            "172.31.255.255",
            "192.168.1.20",
            "169.254.10.10",
            "100.64.0.1",
            "100.127.255.254",
            "::1",
            "fd12:3456::1",
            "fe80::1",
            "::ffff:192.168.1.5",
        ] {
            assert!(lan(a), "{a} should be LAN");
        }
    }

    #[test]
    fn tracker_reports_failed_vs_finished_sessions() {
        use std::sync::Arc;
        let events = Arc::new(Mutex::new(Vec::new()));
        let log = Arc::clone(&events);
        let t = SessionTracker::new(true, Arc::new(move |e| log.lock().unwrap().push(e)));
        let lan: SocketAddr = "192.168.1.9:5000".parse().unwrap();
        let wan: SocketAddr = "8.8.8.8:5000".parse().unwrap();

        assert!(!t.accept(wan));
        assert!(t.accept(lan));
        t.finished(lan, Some("bad password".into()));
        assert!(t.accept(lan));
        t.session_started();
        t.session_started(); // idempotent
        t.finished(lan, None);

        assert_eq!(
            *events.lock().unwrap(),
            vec![
                CoreEvent::Rejected(wan),
                CoreEvent::ConnectionFailed {
                    peer: lan,
                    error: "bad password".into()
                },
                CoreEvent::ClientConnected(lan),
                CoreEvent::ClientDisconnected {
                    peer: lan,
                    error: None
                },
            ]
        );
    }

    #[test]
    fn public_addresses_are_rejected() {
        for a in [
            "8.8.8.8",
            "172.32.0.1",
            "100.128.0.1",
            "100.63.255.255",
            "1.1.1.1",
            "2001:4860:4860::8888",
            "::ffff:8.8.8.8",
        ] {
            assert!(!lan(a), "{a} should not be LAN");
        }
    }
}
