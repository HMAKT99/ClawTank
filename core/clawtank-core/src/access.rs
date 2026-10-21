//! Connection access policy and session lifecycle events.
//!
//! Every TCP peer is checked *before* any TLS or NLA work, in this order:
//! 1. lockout: too many failed logins from this IP recently ([`Lockout`]);
//! 2. allowlist: if configured, the IP must match one of its entries ([`IpNet`]);
//! 3. LAN-only: by default only local/private addresses ([`is_lan_addr`]).
//!
//! [`SessionTracker`] applies the policy in the accept loop and turns the connection
//! lifecycle into [`CoreEvent`]s for the host (which keeps the audit log).

use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use tracing::{info, warn};

use crate::events::{CoreEvent, EventSink, RejectReason};

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

/// An IP network such as `192.168.1.0/24`, `10.0.0.5` (a /32) or `fd00::/8`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct IpNet {
    addr: IpAddr,
    prefix: u8,
}

impl IpNet {
    pub fn parse(text: &str) -> Option<Self> {
        let text = text.trim();
        let (addr, prefix) = match text.split_once('/') {
            Some((a, p)) => (a.parse::<IpAddr>().ok()?, Some(p.parse::<u8>().ok()?)),
            None => (text.parse::<IpAddr>().ok()?, None),
        };
        let addr = addr.to_canonical();
        let max = if addr.is_ipv4() { 32 } else { 128 };
        let prefix = prefix.unwrap_or(max);
        (prefix <= max).then_some(Self { addr, prefix })
    }

    /// Parses a comma/whitespace-separated list; returns `None` if any entry is invalid.
    pub fn parse_list(text: &str) -> Option<Vec<Self>> {
        text.split(|c: char| c == ',' || c.is_whitespace())
            .filter(|s| !s.is_empty())
            .map(Self::parse)
            .collect()
    }

    pub fn contains(&self, ip: IpAddr) -> bool {
        match (self.addr, ip.to_canonical()) {
            (IpAddr::V4(net), IpAddr::V4(ip)) => {
                let mask = u32::MAX
                    .checked_shl(32 - u32::from(self.prefix))
                    .unwrap_or(0);
                u32::from(net) & mask == u32::from(ip) & mask
            }
            (IpAddr::V6(net), IpAddr::V6(ip)) => {
                let mask = u128::MAX
                    .checked_shl(128 - u32::from(self.prefix))
                    .unwrap_or(0);
                u128::from(net) & mask == u128::from(ip) & mask
            }
            _ => false,
        }
    }
}

/// Who may connect.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AccessPolicy {
    /// Refuse peers outside loopback/private/link-local/CGNAT ranges.
    pub lan_only: bool,
    /// If non-empty, only these networks may connect.
    pub allowlist: Vec<IpNet>,
}

impl AccessPolicy {
    pub fn lan_only() -> Self {
        Self {
            lan_only: true,
            allowlist: Vec::new(),
        }
    }

    fn check(&self, ip: IpAddr) -> Option<RejectReason> {
        if !self.allowlist.is_empty() && !self.allowlist.iter().any(|n| n.contains(ip)) {
            return Some(RejectReason::NotAllowlisted);
        }
        if self.lan_only && !is_lan_addr(ip) {
            return Some(RejectReason::LanOnly);
        }
        None
    }
}

/// Failed-login lockout: `max_failures` within `window` locks the IP for `duration`.
#[derive(Debug)]
pub struct Lockout {
    pub max_failures: usize,
    pub window: Duration,
    pub duration: Duration,
    failures: HashMap<IpAddr, Vec<Instant>>,
    locked_until: HashMap<IpAddr, Instant>,
}

impl Default for Lockout {
    fn default() -> Self {
        Self {
            max_failures: 5,
            window: Duration::from_secs(5 * 60),
            duration: Duration::from_secs(5 * 60),
            failures: HashMap::new(),
            locked_until: HashMap::new(),
        }
    }
}

impl Lockout {
    /// Is `ip` locked at `now`? Expired locks are forgotten.
    pub fn is_locked(&mut self, ip: IpAddr, now: Instant) -> bool {
        match self.locked_until.get(&ip) {
            Some(&until) if now < until => true,
            Some(_) => {
                self.locked_until.remove(&ip);
                false
            }
            None => false,
        }
    }

    /// Records a failed login; returns `true` if this failure triggered a lock.
    pub fn record_failure(&mut self, ip: IpAddr, now: Instant) -> bool {
        let window = self.window;
        let recent = self.failures.entry(ip).or_default();
        recent.retain(|&t| now.duration_since(t) < window);
        recent.push(now);
        if recent.len() >= self.max_failures {
            self.failures.remove(&ip);
            self.locked_until.insert(ip, now + self.duration);
            return true;
        }
        false
    }

    /// A successful login clears the IP's failure history.
    pub fn record_success(&mut self, ip: IpAddr) {
        self.failures.remove(&ip);
    }
}

/// Enforces the access policy and tracks the current session for lifecycle events.
///
/// Shared between the accept loop (which calls [`accept`](Self::accept) and
/// [`finished`](Self::finished)) and the display source (which calls
/// [`session_started`](Self::session_started) once the client has authenticated: IronRDP only
/// asks the display for updates after TLS + NLA and capability exchange succeed).
pub struct SessionTracker {
    policy: AccessPolicy,
    sink: EventSink,
    current: Mutex<Option<SocketAddr>>,
    started: AtomicBool,
    lockout: Mutex<Lockout>,
}

impl SessionTracker {
    pub fn new(policy: AccessPolicy, sink: EventSink) -> Self {
        Self::with_lockout(policy, sink, Lockout::default())
    }

    pub fn with_lockout(policy: AccessPolicy, sink: EventSink, lockout: Lockout) -> Self {
        Self {
            policy,
            sink,
            current: Mutex::new(None),
            started: AtomicBool::new(false),
            lockout: Mutex::new(lockout),
        }
    }

    fn lockout(&self) -> std::sync::MutexGuard<'_, Lockout> {
        self.lockout.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Applies the access policy to a new TCP peer. `false` means drop the stream.
    pub fn accept(&self, peer: SocketAddr) -> bool {
        let locked = self.lockout().is_locked(peer.ip(), Instant::now());
        let reason = if locked {
            Some(RejectReason::LockedOut)
        } else {
            self.policy.check(peer.ip())
        };
        if let Some(reason) = reason {
            warn!(%peer, ?reason, "Refused connection");
            (self.sink)(CoreEvent::Rejected { peer, reason });
            return false;
        }
        info!(%peer, "Accepted TCP connection");
        *self.current.lock().unwrap_or_else(|e| e.into_inner()) = Some(peer);
        self.started.store(false, Ordering::Release);
        true
    }

    /// Whether a client is authenticated and in session right now.
    pub fn in_session(&self) -> bool {
        self.started.load(Ordering::Acquire)
    }

    /// Called by the display source when the session's update stream begins.
    pub fn session_started(&self) {
        let peer = *self.current.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(peer) = peer
            && !self.started.swap(true, Ordering::AcqRel)
        {
            info!(%peer, "Client authenticated and connected");
            self.lockout().record_success(peer.ip());
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
            // Anything that fails before the session starts counts (a bad password is by far
            // the most common); 5 in 5 minutes is generous for legitimate retries.
            // One lock acquisition: never re-lock the mutex while a guard may still be alive.
            let locked_for = {
                let mut lockout = self.lockout();
                lockout
                    .record_failure(peer.ip(), Instant::now())
                    .then_some(lockout.duration)
            };
            if let Some(duration) = locked_for {
                let minutes = duration.as_secs() / 60;
                warn!(ip = %peer.ip(), minutes, "Locking out IP after repeated failures");
                (self.sink)(CoreEvent::LockedOut {
                    ip: peer.ip(),
                    minutes: u32::try_from(minutes).unwrap_or(u32::MAX),
                });
            }
        }
        *self.current.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

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

    #[test]
    fn cidr_matching() {
        let net = IpNet::parse("192.168.1.0/24").unwrap();
        assert!(net.contains("192.168.1.77".parse().unwrap()));
        assert!(!net.contains("192.168.2.1".parse().unwrap()));
        assert!(
            net.contains("::ffff:192.168.1.9".parse().unwrap()),
            "mapped v4"
        );
        let host = IpNet::parse("10.0.0.5").unwrap();
        assert!(host.contains("10.0.0.5".parse().unwrap()));
        assert!(!host.contains("10.0.0.6".parse().unwrap()));
        let v6 = IpNet::parse("fd00::/8").unwrap();
        assert!(v6.contains("fd12::1".parse().unwrap()));
        assert!(!v6.contains("fe80::1".parse().unwrap()));
        assert!(
            IpNet::parse("0.0.0.0/0")
                .unwrap()
                .contains("8.8.8.8".parse().unwrap())
        );
        assert_eq!(IpNet::parse("10.0.0.0/33"), None);
        assert_eq!(
            IpNet::parse_list("10.0.0.0/8, 192.168.1.5").map(|l| l.len()),
            Some(2)
        );
        assert_eq!(IpNet::parse_list("10.0.0.0/8, nonsense"), None);
    }

    #[test]
    fn lockout_after_five_failures_and_expiry() {
        let mut lockout = Lockout::default();
        let ip: IpAddr = "192.168.1.9".parse().unwrap();
        let t0 = Instant::now();
        for i in 0..4 {
            assert!(!lockout.record_failure(ip, t0 + Duration::from_secs(i)));
        }
        assert!(!lockout.is_locked(ip, t0 + Duration::from_secs(5)));
        assert!(lockout.record_failure(ip, t0 + Duration::from_secs(5)));
        assert!(lockout.is_locked(ip, t0 + Duration::from_secs(60)));
        assert!(
            !lockout.is_locked(ip, t0 + Duration::from_secs(5 * 60 + 6)),
            "expires"
        );
        let other: IpAddr = "192.168.1.10".parse().unwrap();
        assert!(!lockout.is_locked(other, t0), "per IP");
    }

    #[test]
    fn old_failures_fall_out_of_the_window_and_success_resets() {
        let mut lockout = Lockout::default();
        let ip: IpAddr = "10.0.0.1".parse().unwrap();
        let t0 = Instant::now();
        for i in 0..4 {
            lockout.record_failure(ip, t0 + Duration::from_secs(i));
        }
        assert!(
            !lockout.record_failure(ip, t0 + Duration::from_secs(6 * 60)),
            "old ones expired"
        );
        lockout.record_success(ip);
        for i in 0..4 {
            assert!(!lockout.record_failure(ip, t0 + Duration::from_secs(400 + i)));
        }
    }

    #[test]
    fn tracker_reports_failed_vs_finished_sessions_and_reasons() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let log = Arc::clone(&events);
        let policy = AccessPolicy {
            lan_only: true,
            allowlist: IpNet::parse_list("192.168.1.0/24, 8.8.8.0/24").unwrap(),
        };
        let t = SessionTracker::new(policy, Arc::new(move |e| log.lock().unwrap().push(e)));
        let lan: SocketAddr = "192.168.1.9:5000".parse().unwrap();
        let other_lan: SocketAddr = "10.0.0.9:5000".parse().unwrap();
        let wan: SocketAddr = "8.8.8.8:5000".parse().unwrap();

        assert!(!t.accept(other_lan), "not in allowlist");
        assert!(!t.accept(wan), "allowlisted but LAN-only");
        assert!(t.accept(lan));
        t.finished(lan, Some("bad password".into()));
        assert!(t.accept(lan));
        t.session_started();
        t.session_started(); // idempotent
        assert!(t.in_session());
        t.finished(lan, None);
        assert!(!t.in_session());

        assert_eq!(
            *events.lock().unwrap(),
            vec![
                CoreEvent::Rejected {
                    peer: other_lan,
                    reason: RejectReason::NotAllowlisted
                },
                CoreEvent::Rejected {
                    peer: wan,
                    reason: RejectReason::LanOnly
                },
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
    fn tracker_locks_out_and_refuses() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let log = Arc::clone(&events);
        let t = SessionTracker::new(
            AccessPolicy::lan_only(),
            Arc::new(move |e| log.lock().unwrap().push(e)),
        );
        let peer: SocketAddr = "192.168.1.50:4000".parse().unwrap();
        for _ in 0..5 {
            assert!(t.accept(peer));
            t.finished(peer, Some("CredSSP failure".into()));
        }
        assert!(!t.accept(peer));
        let events = events.lock().unwrap();
        assert!(events.contains(&CoreEvent::LockedOut {
            ip: peer.ip(),
            minutes: 5
        }));
        assert_eq!(
            events.last(),
            Some(&CoreEvent::Rejected {
                peer,
                reason: RejectReason::LockedOut
            })
        );
    }
}
