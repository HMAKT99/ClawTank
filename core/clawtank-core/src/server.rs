//! RDP server lifecycle: build the IronRDP server, run it on a dedicated thread, stop it.
//!
//! We run our own accept loop (mirroring `RdpServer::run` in ironrdp-server 0.13) so that:
//! bind errors are reported synchronously by [`start`]; the real port is known even for
//! port 0; the LAN-only policy runs before any handshake; and stopping works whether or not a
//! client is connected. The server runs on its own small tokio runtime so it never shares
//! threads with the host's capture/encode work. One session at a time (Phase 1).

use std::net::SocketAddr;
use std::thread::JoinHandle;
use std::time::Duration;

use std::sync::Arc;

use ironrdp_server::{Credentials, RdpServer, ServerEvent};
use tokio::net::TcpListener;
use tokio::sync::{mpsc::UnboundedSender, watch};
use tracing::{error, info, warn};

use crate::Result;
use crate::access::SessionTracker;
use crate::display::TestPatternDisplay;
use crate::events::{CoreEvent, EventSink};
use crate::gfx::GfxFactory;
use crate::input::{InputForwarder, InputSink};
use crate::pointer::PointerHub;
use crate::tls::TlsIdentity;
use crate::video::VideoHub;

/// Everything needed to start a server.
#[derive(Debug, Clone)]
pub struct ServerConfig {
    pub bind: SocketAddr,
    /// NLA account name (matched exactly; the client's domain, if any, is accepted as sent).
    pub username: String,
    pub password: String,
    pub identity: TlsIdentity,
    /// Refuse peers outside loopback/private/link-local/CGNAT ranges.
    pub lan_only: bool,
}

/// A running server. Dropping it stops the server.
pub struct ServerHandle {
    /// Ends an active session (handled inside IronRDP's session loop).
    quit: UnboundedSender<ServerEvent>,
    /// Ends our accept loop.
    shutdown: watch::Sender<bool>,
    thread: Option<JoinHandle<()>>,
    local_addr: SocketAddr,
    video: Arc<VideoHub>,
    pointer: Arc<PointerHub>,
}

impl ServerHandle {
    /// Where the host publishes cursor shapes.
    pub fn pointer(&self) -> &Arc<PointerHub> {
        &self.pointer
    }

    /// Where the host submits encoded video.
    pub fn video(&self) -> &Arc<VideoHub> {
        &self.video
    }

    /// The bound listen address (with the real port if `bind` used port 0).
    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    /// Disconnects any client, stops listening and waits for the server thread to exit.
    pub fn stop(mut self) {
        self.shutdown();
    }

    fn shutdown(&mut self) {
        if let Some(thread) = self.thread.take() {
            let _ = self.shutdown.send(true);
            let _ = self
                .quit
                .send(ServerEvent::Quit("server stopped by host".to_owned()));
            if thread.join().is_err() {
                error!("RDP server thread panicked");
            }
        }
    }
}

impl Drop for ServerHandle {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// Starts the server. Returns once the listener is bound; events arrive on `sink`.
/// Input events arrive on `input`, on a server thread.
pub fn start(config: ServerConfig, sink: EventSink, input: InputSink) -> Result<ServerHandle> {
    let acceptor = config.identity.acceptor()?;
    let public_key = config.identity.public_key()?;

    let listener = std::net::TcpListener::bind(config.bind)?;
    listener.set_nonblocking(true)?;
    let local_addr = listener.local_addr()?;

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_name("clawtank-rdp-worker")
        .enable_all()
        .build()?;

    let tracker = Arc::new(SessionTracker::new(config.lan_only, sink.clone()));
    let video = Arc::new(VideoHub::new(sink.clone()));
    let pointer = Arc::new(PointerHub::default());
    let thread_pointer = Arc::clone(&pointer);
    let thread_video = Arc::clone(&video);
    let (shutdown, mut shutdown_rx) = watch::channel(false);
    // RdpServer is not Send, so it is built on the server thread; its quit sender comes back here.
    let (quit_tx, quit_rx) = std::sync::mpsc::sync_channel(1);
    let credentials = Credentials {
        username: config.username,
        password: config.password,
        domain: None,
    };

    let thread = std::thread::Builder::new()
        .name("clawtank-rdp".to_owned())
        .spawn(move || {
            let mut server = RdpServer::builder()
                .with_addr(local_addr)
                .with_hybrid(acceptor, public_key)
                .with_input_handler(InputForwarder::new(input))
                .with_display_handler(TestPatternDisplay::new(
                    Arc::clone(&tracker),
                    Arc::clone(&thread_video),
                    thread_pointer,
                ))
                .with_honor_client_desktop_size(true)
                .with_gfx_factory(Some(Box::new(GfxFactory::new(Arc::clone(&thread_video)))))
                .build();
            server.set_credentials(Some(credentials));
            let _ = quit_tx.send(server.event_sender().clone());

            runtime.block_on(async move {
                let listener = match TcpListener::from_std(listener) {
                    Ok(l) => l,
                    Err(e) => {
                        sink(CoreEvent::Error(format!("listener: {e}")));
                        sink(CoreEvent::Stopped);
                        return;
                    }
                };
                info!(%local_addr, "RDP server listening");
                sink(CoreEvent::Listening(local_addr));

                loop {
                    let (stream, peer) = tokio::select! {
                        _ = shutdown_rx.wait_for(|stop| *stop) => break,
                        accepted = listener.accept() => match accepted {
                            Ok(a) => a,
                            Err(e) => {
                                // Errors like EMFILE repeat immediately; back off instead of spinning.
                                warn!(error = %e, "accept failed");
                                tokio::time::sleep(Duration::from_millis(100)).await;
                                continue;
                            }
                        },
                    };
                    if !tracker.accept(peer) {
                        continue;
                    }
                    if let Err(e) = stream.set_nodelay(true) {
                        warn!(%peer, error = %e, "TCP_NODELAY failed; latency may suffer");
                    }
                    let result = server.run_connection(stream).await;
                    thread_video.session_ended();
                    tracker.finished(peer, result.err().map(|e| format!("{e:#}")));
                    if *shutdown_rx.borrow() {
                        break;
                    }
                }
                info!("RDP server stopped");
                sink(CoreEvent::Stopped);
            });
            // Don't let a stuck session task block process shutdown forever.
            runtime.shutdown_timeout(Duration::from_secs(2));
        })?;
    let quit = quit_rx
        .recv()
        .map_err(|_| "RDP server thread exited during startup")?;

    Ok(ServerHandle {
        quit,
        shutdown,
        thread: Some(thread),
        local_addr,
        video,
        pointer,
    })
}
