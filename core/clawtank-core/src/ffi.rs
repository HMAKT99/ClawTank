//! C ABI exported to the Swift host.
//!
//! Rules for this module (keep the boundary small and auditable):
//! - Only `#[repr(C)]` types and raw pointers cross the boundary.
//! - Every pointer argument is null-checked; failures return a [`CtStatus`], never panic.
//! - Memory allocated here is freed here: [`ct_buffer_free`], [`ct_string_free`],
//!   [`ct_server_stop`]. Strings from [`ct_version`] are `'static` and must not be freed.
//! - Callbacks are invoked on core-owned threads; the host must hop to its own queues.
//! - Every exported item is prefixed `ct_` / `Ct`.

use std::ffi::{CStr, CString, c_char, c_void};
use std::net::{IpAddr, SocketAddr};
use std::sync::{Arc, OnceLock};

use tracing::Level;

use crate::events::CoreEvent;
use crate::server::{self, ServerConfig, ServerHandle};
use crate::tls::TlsIdentity;

/// Result code for FFI calls.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CtStatus {
    /// The call succeeded.
    Ok = 0,
    /// `ct_core_init` (or `ct_set_log_callback`) was already called; the call had no effect.
    AlreadyInitialized = 1,
    /// A required pointer was null, a string was not UTF-8, or a value was out of range.
    InvalidArgument = 2,
    /// Generating or loading the TLS identity failed.
    TlsError = 3,
    /// The listen address could not be bound (port in use, permission, bad address).
    BindFailed = 4,
    /// Any other failure; details are in the log.
    InternalError = 5,
}

/// Kind of a server event delivered to [`CtEventCallback`].
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CtEventKind {
    /// Listener bound. Detail: `"ip:port"`.
    Listening = 0,
    /// Peer refused by the LAN-only policy. Detail: `"ip:port"`.
    Rejected = 1,
    /// Client authenticated; session started. Detail: `"ip:port"`.
    ClientConnected = 2,
    /// Session ended. Detail: `"ip:port"` or `"ip:port\nerror"`.
    ClientDisconnected = 3,
    /// Connection failed before the session started (e.g. bad password). Detail: `"ip:port\nerror"`.
    ConnectionFailed = 4,
    /// Server loop exited. Detail: empty.
    Stopped = 5,
    /// Server loop failed. Detail: error message.
    Error = 6,
}

/// Log severity for [`CtLogCallback`].
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CtLogLevel {
    Error = 0,
    Warn = 1,
    Info = 2,
    Debug = 3,
    Trace = 4,
}

/// Receives server events. `detail` is a NUL-terminated UTF-8 string valid only for the call.
pub type CtEventCallback =
    Option<unsafe extern "C" fn(ctx: *mut c_void, kind: CtEventKind, detail: *const c_char)>;

/// Receives log lines. `message` is a NUL-terminated UTF-8 string valid only for the call.
pub type CtLogCallback = Option<unsafe extern "C" fn(level: CtLogLevel, message: *const c_char)>;

/// Bytes allocated by the core. Free with [`ct_buffer_free`].
#[repr(C)]
#[derive(Debug)]
pub struct CtBuffer {
    pub data: *mut u8,
    pub len: usize,
}

impl CtBuffer {
    #[cfg(test)]
    const EMPTY: CtBuffer = CtBuffer {
        data: std::ptr::null_mut(),
        len: 0,
    };

    fn from_vec(v: Vec<u8>) -> Self {
        let boxed = v.into_boxed_slice();
        let len = boxed.len();
        let data = Box::into_raw(boxed).cast::<u8>();
        Self { data, len }
    }
}

/// Server configuration. All pointers are borrowed for the duration of `ct_server_start`.
#[repr(C)]
#[derive(Debug)]
pub struct CtServerConfig {
    /// Listen IP address, e.g. `"0.0.0.0"` or `"127.0.0.1"`. NUL-terminated UTF-8.
    pub bind_ip: *const c_char,
    /// Listen port; 0 picks a free port (see `ct_server_port`).
    pub port: u16,
    /// NLA username. NUL-terminated UTF-8.
    pub username: *const c_char,
    /// NLA password. NUL-terminated UTF-8.
    pub password: *const c_char,
    /// DER certificate from `ct_generate_tls_identity`.
    pub cert_der: *const u8,
    pub cert_der_len: usize,
    /// PKCS#8 DER private key from `ct_generate_tls_identity`.
    pub key_der: *const u8,
    pub key_der_len: usize,
    /// Refuse peers outside local/private address ranges.
    pub lan_only: bool,
}

/// Opaque running server.
pub struct CtServer {
    handle: ServerHandle,
}

/// Host context pointer, passed back verbatim to the event callback.
struct HostCtx(*mut c_void);
// SAFETY: the host promises (see `ct_server_start`) that `ctx` may be used from any thread.
unsafe impl Send for HostCtx {}
// SAFETY: as above; the core never dereferences it.
unsafe impl Sync for HostCtx {}

static INIT: OnceLock<()> = OnceLock::new();

/// Returns the core library version as a static NUL-terminated UTF-8 string.
/// The pointer is valid for the life of the process; do not free it.
#[unsafe(no_mangle)]
pub extern "C" fn ct_version() -> *const c_char {
    crate::VERSION_CSTR.as_ptr()
}

/// Initializes process-wide core state. Safe to call more than once.
#[unsafe(no_mangle)]
pub extern "C" fn ct_core_init() -> CtStatus {
    if INIT.set(()).is_ok() {
        CtStatus::Ok
    } else {
        CtStatus::AlreadyInitialized
    }
}

/// Routes core logs to `callback`. `filter` uses tracing `EnvFilter` syntax (e.g. `"info"`);
/// null means `"info"`. Can be installed once per process.
///
/// # Safety
/// `filter` must be null or a valid NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_set_log_callback(
    callback: CtLogCallback,
    filter: *const c_char,
) -> CtStatus {
    let Some(callback) = callback else {
        return CtStatus::InvalidArgument;
    };
    // SAFETY: caller guarantees `filter` is null or a valid C string.
    let filter = match unsafe { opt_str(filter) } {
        Ok(f) => f.unwrap_or("info").to_owned(),
        Err(s) => return s,
    };
    let sink = Box::new(move |level: Level, msg: &str| {
        let level = match level {
            Level::ERROR => CtLogLevel::Error,
            Level::WARN => CtLogLevel::Warn,
            Level::INFO => CtLogLevel::Info,
            Level::DEBUG => CtLogLevel::Debug,
            Level::TRACE => CtLogLevel::Trace,
        };
        if let Ok(c) = CString::new(msg.replace('\0', " ")) {
            // SAFETY: the host registered this callback for exactly this signature.
            unsafe { callback(level, c.as_ptr()) };
        }
    });
    if crate::logging::install(sink, &filter) {
        CtStatus::Ok
    } else {
        CtStatus::AlreadyInitialized
    }
}

/// Generates a self-signed RSA-2048 TLS identity for `common_name` (e.g. `"macmini.local"`).
/// On success fills `cert_out` (DER) and `key_out` (PKCS#8 DER); free both with `ct_buffer_free`.
///
/// # Safety
/// `common_name` must be a valid NUL-terminated string; `cert_out`/`key_out` must be valid
/// writable pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_generate_tls_identity(
    common_name: *const c_char,
    cert_out: *mut CtBuffer,
    key_out: *mut CtBuffer,
) -> CtStatus {
    if cert_out.is_null() || key_out.is_null() {
        return CtStatus::InvalidArgument;
    }
    // SAFETY: caller guarantees `common_name` is a valid C string (null is rejected).
    let name = match unsafe { req_str(common_name) } {
        Ok(n) if !n.is_empty() => n,
        Ok(_) => return CtStatus::InvalidArgument,
        Err(s) => return s,
    };
    match TlsIdentity::generate(name) {
        Ok(id) => {
            // SAFETY: both pointers were checked non-null and are writable per the contract.
            unsafe {
                *cert_out = CtBuffer::from_vec(id.cert_der);
                *key_out = CtBuffer::from_vec(id.key_pkcs8_der);
            }
            CtStatus::Ok
        }
        Err(e) => {
            tracing::error!(error = %e, "TLS identity generation failed");
            CtStatus::TlsError
        }
    }
}

/// Frees a buffer returned by the core. Passing an empty/null buffer is a no-op.
///
/// # Safety
/// `buffer` must have come from the core and must not be freed twice.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_buffer_free(buffer: CtBuffer) {
    if buffer.data.is_null() {
        return;
    }
    // SAFETY: data/len came from `CtBuffer::from_vec` (a leaked Box<[u8]>).
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(buffer.data, buffer.len)) });
}

/// Returns the SHA-256 fingerprint (`AB:CD:…`) of a DER certificate, or null on bad input.
/// Free with `ct_string_free`.
///
/// # Safety
/// `cert_der` must point to `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_tls_fingerprint_sha256(cert_der: *const u8, len: usize) -> *mut c_char {
    // SAFETY: caller guarantees `cert_der` points to `len` readable bytes.
    let Some(cert) = (unsafe { bytes(cert_der, len) }) else {
        return std::ptr::null_mut();
    };
    let id = TlsIdentity {
        cert_der: cert.to_vec(),
        key_pkcs8_der: Vec::new(),
    };
    CString::new(id.fingerprint_sha256()).map_or(std::ptr::null_mut(), CString::into_raw)
}

/// Frees a string returned by the core. Null is a no-op.
///
/// # Safety
/// `s` must have come from the core and must not be freed twice.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_string_free(s: *mut c_char) {
    if !s.is_null() {
        // SAFETY: `s` came from `CString::into_raw` in this module.
        drop(unsafe { CString::from_raw(s) });
    }
}

/// Starts the RDP server. Returns null on failure and writes the reason to `out_status`
/// (if non-null). Events are delivered to `callback` with `ctx` on a core thread, until
/// `ct_server_stop` returns.
///
/// # Safety
/// `config` and the strings/buffers it points to must be valid for the duration of the call.
/// `ctx` must remain valid, and be safe to use from any thread, until `ct_server_stop` returns.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_server_start(
    config: *const CtServerConfig,
    callback: CtEventCallback,
    ctx: *mut c_void,
    out_status: *mut CtStatus,
) -> *mut CtServer {
    // SAFETY: forwarded caller guarantees.
    let result = unsafe { server_start(config, callback, ctx) };
    let (server, status) = match result {
        Ok(handle) => (Box::into_raw(Box::new(CtServer { handle })), CtStatus::Ok),
        Err(status) => (std::ptr::null_mut(), status),
    };
    if !out_status.is_null() {
        // SAFETY: checked non-null; caller provides a writable CtStatus.
        unsafe { *out_status = status };
    }
    server
}

unsafe fn server_start(
    config: *const CtServerConfig,
    callback: CtEventCallback,
    ctx: *mut c_void,
) -> Result<ServerHandle, CtStatus> {
    if config.is_null() {
        return Err(CtStatus::InvalidArgument);
    }
    // SAFETY: checked non-null; caller guarantees validity.
    let c = unsafe { &*config };
    // SAFETY: caller guarantees these are valid C strings (null is rejected).
    let (ip, username, password) = unsafe {
        (
            req_str(c.bind_ip)?,
            req_str(c.username)?,
            req_str(c.password)?,
        )
    };
    if username.is_empty() || password.is_empty() {
        return Err(CtStatus::InvalidArgument);
    }
    let ip: IpAddr = ip.parse().map_err(|_| CtStatus::InvalidArgument)?;
    // SAFETY: caller guarantees the buffers are readable for the given lengths.
    let (cert, key) = unsafe {
        (
            bytes(c.cert_der, c.cert_der_len),
            bytes(c.key_der, c.key_der_len),
        )
    };
    let (Some(cert), Some(key)) = (cert, key) else {
        return Err(CtStatus::InvalidArgument);
    };

    let config = ServerConfig {
        bind: SocketAddr::new(ip, c.port),
        username: username.to_owned(),
        password: password.to_owned(),
        identity: TlsIdentity {
            cert_der: cert.to_vec(),
            key_pkcs8_der: key.to_vec(),
        },
        lan_only: c.lan_only,
    };
    if config.identity.acceptor().is_err() || config.identity.public_key().is_err() {
        return Err(CtStatus::TlsError);
    }

    let ctx = Arc::new(HostCtx(ctx));
    let sink = Arc::new(move |event: CoreEvent| {
        let Some(cb) = callback else { return };
        let (kind, detail) = event_to_c(&event);
        if let Ok(detail) = CString::new(detail.replace('\0', " ")) {
            // SAFETY: the host registered this callback and ctx for exactly this use.
            unsafe { cb(ctx.0, kind, detail.as_ptr()) };
        }
    });

    server::start(config, sink).map_err(|e| {
        tracing::error!(error = %e, "Failed to start RDP server");
        if e.downcast_ref::<std::io::Error>().is_some() {
            CtStatus::BindFailed
        } else {
            CtStatus::InternalError
        }
    })
}

/// Stops the server, waits for its thread to exit, and frees it. Null is a no-op.
/// No events are delivered after this returns.
///
/// # Safety
/// `server` must come from `ct_server_start` and must not be used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_server_stop(server: *mut CtServer) {
    if !server.is_null() {
        // SAFETY: `server` came from Box::into_raw in `ct_server_start`.
        let server = unsafe { Box::from_raw(server) };
        server.handle.stop();
    }
}

/// The port the server is listening on, or 0 for a null server.
///
/// # Safety
/// `server` must be null or a live pointer from `ct_server_start`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_server_port(server: *const CtServer) -> u16 {
    if server.is_null() {
        return 0;
    }
    // SAFETY: non-null live pointer per the contract.
    unsafe { &*server }.handle.local_addr().port()
}

fn event_to_c(event: &CoreEvent) -> (CtEventKind, String) {
    match event {
        CoreEvent::Listening(a) => (CtEventKind::Listening, a.to_string()),
        CoreEvent::Rejected(a) => (CtEventKind::Rejected, a.to_string()),
        CoreEvent::ClientConnected(a) => (CtEventKind::ClientConnected, a.to_string()),
        CoreEvent::ClientDisconnected { peer, error: None } => {
            (CtEventKind::ClientDisconnected, peer.to_string())
        }
        CoreEvent::ClientDisconnected {
            peer,
            error: Some(e),
        } => (CtEventKind::ClientDisconnected, format!("{peer}\n{e}")),
        CoreEvent::ConnectionFailed { peer, error } => {
            (CtEventKind::ConnectionFailed, format!("{peer}\n{error}"))
        }
        CoreEvent::Stopped => (CtEventKind::Stopped, String::new()),
        CoreEvent::Error(e) => (CtEventKind::Error, e.clone()),
    }
}

/// # Safety
/// `p` must be null or a valid NUL-terminated string.
unsafe fn opt_str<'a>(p: *const c_char) -> Result<Option<&'a str>, CtStatus> {
    if p.is_null() {
        return Ok(None);
    }
    // SAFETY: non-null and valid per the contract.
    unsafe { CStr::from_ptr(p) }
        .to_str()
        .map(Some)
        .map_err(|_| CtStatus::InvalidArgument)
}

/// # Safety
/// As [`opt_str`]; null is an error.
unsafe fn req_str<'a>(p: *const c_char) -> Result<&'a str, CtStatus> {
    // SAFETY: forwarded.
    unsafe { opt_str(p) }?.ok_or(CtStatus::InvalidArgument)
}

/// # Safety
/// `p` must be null or point to `len` readable bytes.
unsafe fn bytes<'a>(p: *const u8, len: usize) -> Option<&'a [u8]> {
    if p.is_null() || len == 0 {
        return None;
    }
    // SAFETY: non-null and readable for `len` bytes per the contract.
    Some(unsafe { std::slice::from_raw_parts(p, len) })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ptr::{null, null_mut};

    #[test]
    fn version_matches_cargo() {
        // SAFETY: ct_version returns a pointer to a 'static NUL-terminated string.
        let v = unsafe { CStr::from_ptr(ct_version()) }.to_str().unwrap();
        assert_eq!(v, env!("CARGO_PKG_VERSION"));
    }

    #[test]
    fn init_is_idempotent() {
        let first = ct_core_init();
        let second = ct_core_init();
        // Another test may have initialized first; either way the second call must report it.
        assert!(matches!(first, CtStatus::Ok | CtStatus::AlreadyInitialized));
        assert_eq!(second, CtStatus::AlreadyInitialized);
    }

    #[test]
    fn null_arguments_are_rejected() {
        let mut status = CtStatus::Ok;
        // SAFETY: exercising the null checks.
        unsafe {
            assert!(ct_server_start(null(), None, null_mut(), &mut status).is_null());
            assert_eq!(status, CtStatus::InvalidArgument);
            assert_eq!(
                ct_generate_tls_identity(null(), null_mut(), null_mut()),
                CtStatus::InvalidArgument
            );
            assert!(ct_tls_fingerprint_sha256(null(), 0).is_null());
            assert_eq!(ct_server_port(null()), 0);
            ct_server_stop(null_mut());
            ct_string_free(null_mut());
            ct_buffer_free(CtBuffer::EMPTY);
        }
    }

    #[test]
    fn identity_round_trip_and_fingerprint() {
        let name = CString::new("ffi.local").unwrap();
        let (mut cert, mut key) = (CtBuffer::EMPTY, CtBuffer::EMPTY);
        // SAFETY: valid pointers; buffers freed below.
        unsafe {
            assert_eq!(
                ct_generate_tls_identity(name.as_ptr(), &mut cert, &mut key),
                CtStatus::Ok
            );
            assert!(cert.len > 0 && key.len > 0);
            let fp = ct_tls_fingerprint_sha256(cert.data, cert.len);
            assert!(!fp.is_null());
            assert_eq!(CStr::from_ptr(fp).to_bytes().len(), 95);
            ct_string_free(fp);
            ct_buffer_free(cert);
            ct_buffer_free(key);
        }
    }
}
