//! Events the core reports to the host app (connection lifecycle, server state).

use std::net::SocketAddr;
use std::sync::Arc;

/// Something the host app should know about. Delivered on the core's network thread.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CoreEvent {
    /// The listener is bound and accepting connections.
    Listening(SocketAddr),
    /// A peer was refused by the access policy before any handshake.
    Rejected(SocketAddr),
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
    /// The server loop exited; no more events follow.
    Stopped,
    /// The server loop failed.
    Error(String),
}

/// Callback receiving [`CoreEvent`]s.
pub type EventSink = Arc<dyn Fn(CoreEvent) + Send + Sync>;
