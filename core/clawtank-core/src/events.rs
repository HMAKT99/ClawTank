//! Events the core reports to the host app (connection lifecycle, server state).

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

/// Something the host app should know about. Delivered on the core's network thread.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CoreEvent {
    /// The listener is bound and accepting connections.
    Listening(SocketAddr),
    /// A peer was refused by the access policy before any handshake.
    Rejected {
        peer: SocketAddr,
        reason: RejectReason,
    },
    /// Repeated failed logins: `ip` is refused for `minutes`.
    LockedOut { ip: IpAddr, minutes: u32 },
    /// A client finished TLS + NLA and the session started.
    ClientConnected(SocketAddr),
    /// A connected client's session ended (`error` is `None` for a clean disconnect).
    ClientDisconnected {
        peer: SocketAddr,
        error: Option<String>,
    },
    /// A connection ended before the session started (bad password, TLS failure, …).
    ConnectionFailed { peer: SocketAddr, error: String },
    /// The client's graphics pipeline is ready: start capturing/encoding at this size.
    VideoStart { width: u16, height: u16 },
    /// The client resized its desktop: restart capture/encoding at this size.
    /// `scale_percent` is the client's desktop scale (100 = 1x, 200 = Retina).
    VideoResize {
        width: u16,
        height: u16,
        scale_percent: u32,
    },
    /// The graphics pipeline closed: stop capturing/encoding.
    VideoStop,
    /// Audio negotiated: start capturing system audio as 16-bit PCM in this format.
    AudioStart { rate: u32, channels: u16 },
    /// Audio channel closed: stop capturing audio.
    AudioStop,
    /// Clipboard channel up (or the client asked for our formats): announce the host clipboard.
    ClipboardReady,
    /// The client copied: these formats are available (fetch with a request).
    ClipboardRemoteFormats(Vec<crate::clipboard::Format>),
    /// The client wants the host clipboard in `format`; answer with provide.
    ClipboardDataRequested { format: u32 },
    /// Data requested from the client arrived; take it from the hub.
    ClipboardData { format: u32 },
    /// The server loop exited; no more events follow.
    Stopped,
    /// The server loop failed.
    Error(String),
}

/// Why a peer was refused before the handshake.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RejectReason {
    /// Not a local/private address and LAN-only is on.
    LanOnly,
    /// An allowlist is configured and the address isn't on it.
    NotAllowlisted,
    /// Too many recent failed logins from this address.
    LockedOut,
}

impl RejectReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::LanOnly => "lan-only",
            Self::NotAllowlisted => "allowlist",
            Self::LockedOut => "locked-out",
        }
    }
}

/// Callback receiving [`CoreEvent`]s.
pub type EventSink = Arc<dyn Fn(CoreEvent) + Send + Sync>;
