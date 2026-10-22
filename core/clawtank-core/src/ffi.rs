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

use crate::access::{AccessPolicy, IpNet};
use crate::clipboard::{FileAnswer, FileEntry, FileQuery};
use crate::events::CoreEvent;
use crate::input::InputEvent;
use crate::server::{self, ServerConfig, ServerHandle};
use crate::tls::TlsIdentity;
use crate::video::SubmitResult;

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
    /// Peer refused before the handshake. Detail: `"ip:port\nreason"` (`lan-only`, `allowlist`,
    /// `locked-out`).
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
    /// Client graphics pipeline ready: start capture + encode. Detail: `"WIDTHxHEIGHT"`.
    VideoStart = 7,
    /// Graphics pipeline closed: stop capture + encode. Detail: empty.
    VideoStop = 8,
    /// Client resized: restart capture + encode. Detail: `"WIDTHxHEIGHT@SCALE"` (scale in %).
    VideoResize = 9,
    /// Repeated failed logins locked out an IP. Detail: `"ip\nminutes"`.
    LockedOut = 10,
    /// Audio negotiated. Detail: `"RATExCHANNELS"`; submit 16-bit PCM with `ct_server_submit_audio`.
    AudioStart = 11,
    /// Audio channel closed. Detail: empty.
    AudioStop = 12,
    /// Clipboard ready (or the client asked): announce the host clipboard. Detail: empty.
    ClipboardReady = 13,
    /// The client copied. Detail: one format per line, `"ID"` or `"ID\tNAME"`.
    ClipboardRemoteFormats = 14,
    /// The client wants the host clipboard. Detail: format id; answer with `ct_clipboard_provide`.
    ClipboardDataRequested = 15,
    /// Requested client data arrived. Detail: format id; fetch with `ct_clipboard_take_data`.
    ClipboardData = 16,
    /// The client copied files. Detail: one per line, `"SIZE\tDIR\tPATH"` (DIR is 0/1, PATH
    /// uses `/` and is relative). Line index = file index for contents requests.
    ClipboardRemoteFiles = 17,
    /// The client wants file contents. Detail: `"STREAM\tINDEX\tsize"` or
    /// `"STREAM\tINDEX\trange\tPOSITION\tLENGTH"`; answer with `ct_clipboard_answer_file`.
    ClipboardFileRequested = 18,
    /// File contents from the client arrived. Detail: stream id; take with `ct_clipboard_take_file`.
    ClipboardFileContents = 19,
}

/// Result of `ct_server_submit_h264`.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CtSubmitResult {
    /// Queued to the client.
    Sent = 0,
    /// No graphics session; nothing sent, nothing owed.
    NotReady = 1,
    /// Not sent; the next submitted frame must be a keyframe (IDR).
    NeedKeyframe = 2,
}

/// Video counters for the current session.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CtVideoStats {
    pub frames_sent: u64,
    pub bytes_sent: u64,
    pub frames_dropped: u64,
    pub frames_acked: u64,
    pub frames_in_flight: u32,
    /// Smoothed send→ack time in microseconds (0 = no acks yet).
    pub ack_latency_us: u32,
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

/// Kind of a client input event.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CtInputKind {
    /// `code` = Set-1 scancode, `extended` = 0xE0 prefix, `down`.
    Key = 0,
    /// `code` = UTF-16 code unit, `down`.
    Unicode = 1,
    /// `flags` = lock keys (bit 0 Scroll, 1 Num, 2 Caps, 3 Kana).
    Sync = 2,
    /// `x`, `y` = absolute position in desktop (session) pixels.
    Move = 3,
    /// `x`, `y` = relative motion.
    RelMove = 4,
    /// `button` (0 left, 1 right, 2 middle, 3 X1/back, 4 X2/forward), `down`.
    Button = 5,
    /// `y` = vertical, `x` = horizontal wheel units (120 per notch; +y away from user, +x right).
    Wheel = 6,
}

/// One client input event. Fields not used by `kind` are zero.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CtInputEvent {
    pub kind: CtInputKind,
    pub code: u16,
    pub extended: bool,
    pub down: bool,
    pub button: u8,
    pub flags: u32,
    pub x: i32,
    pub y: i32,
}

/// Receives input events on a core thread. `event` is valid only for the call. Keep it fast:
/// it runs on the session's network task.
pub type CtInputCallback =
    Option<unsafe extern "C" fn(ctx: *mut c_void, event: *const CtInputEvent)>;

fn input_to_c(event: InputEvent) -> CtInputEvent {
    let base = CtInputEvent {
        kind: CtInputKind::Key,
        code: 0,
        extended: false,
        down: false,
        button: 0,
        flags: 0,
        x: 0,
        y: 0,
    };
    match event {
        InputEvent::Key {
            code,
            extended,
            down,
        } => CtInputEvent {
            code: u16::from(code),
            extended,
            down,
            ..base
        },
        InputEvent::Unicode { unit, down } => CtInputEvent {
            kind: CtInputKind::Unicode,
            code: unit,
            down,
            ..base
        },
        InputEvent::Sync { flags } => CtInputEvent {
            kind: CtInputKind::Sync,
            flags,
            ..base
        },
        InputEvent::Move { x, y } => CtInputEvent {
            kind: CtInputKind::Move,
            x: i32::from(x),
            y: i32::from(y),
            ..base
        },
        InputEvent::RelMove { dx, dy } => CtInputEvent {
            kind: CtInputKind::RelMove,
            x: dx,
            y: dy,
            ..base
        },
        InputEvent::Button { button, down } => CtInputEvent {
            kind: CtInputKind::Button,
            button: button as u8,
            down,
            ..base
        },
        InputEvent::Wheel {
            vertical,
            horizontal,
        } => CtInputEvent {
            kind: CtInputKind::Wheel,
            x: horizontal,
            y: vertical,
            ..base
        },
    }
}

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
    /// Optional allowlist: comma-separated IPs/CIDRs (`"192.168.1.0/24, 10.0.0.5"`); null or
    /// empty means no allowlist.
    pub allowlist: *const c_char,
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
                cert_out.write(CtBuffer::from_vec(id.cert_der));
                key_out.write(CtBuffer::from_vec(id.key_pkcs8_der));
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
    input_callback: CtInputCallback,
    ctx: *mut c_void,
    out_status: *mut CtStatus,
) -> *mut CtServer {
    // SAFETY: forwarded caller guarantees.
    let result = unsafe { server_start(config, callback, input_callback, ctx) };
    let (server, status) = match result {
        Ok(handle) => (Box::into_raw(Box::new(CtServer { handle })), CtStatus::Ok),
        Err(status) => (std::ptr::null_mut(), status),
    };
    if !out_status.is_null() {
        // SAFETY: checked non-null; caller provides a writable CtStatus.
        unsafe { out_status.write(status) };
    }
    server
}

unsafe fn server_start(
    config: *const CtServerConfig,
    callback: CtEventCallback,
    input_callback: CtInputCallback,
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
    // SAFETY: caller guarantees `allowlist` is null or a valid C string.
    let allowlist = match unsafe { opt_str(c.allowlist) }? {
        Some(text) => IpNet::parse_list(text).ok_or(CtStatus::InvalidArgument)?,
        None => Vec::new(),
    };
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
        policy: AccessPolicy {
            lan_only: c.lan_only,
            allowlist,
        },
    };
    if config.identity.acceptor().is_err() || config.identity.public_key().is_err() {
        return Err(CtStatus::TlsError);
    }

    let ctx = Arc::new(HostCtx(ctx));
    let input_ctx = Arc::clone(&ctx);
    let sink = Arc::new(move |event: CoreEvent| {
        let Some(cb) = callback else { return };
        let (kind, detail) = event_to_c(&event);
        if let Ok(detail) = CString::new(detail.replace('\0', " ")) {
            // SAFETY: the host registered this callback and ctx for exactly this use.
            unsafe { cb(ctx.0, kind, detail.as_ptr()) };
        }
    });

    let input = Arc::new(move |event: InputEvent| {
        let Some(cb) = input_callback else { return };
        let event = input_to_c(event);
        // SAFETY: the host registered this callback and ctx for exactly this use; the event
        // pointer is valid for the duration of the call.
        unsafe { cb(input_ctx.0, &event) };
    });

    server::start(config, sink, input).map_err(|e| {
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

/// Submits one H.264 access unit (Annex-B byte stream; keyframes must carry SPS/PPS),
/// encoded for a `width`×`height` desktop (the session size from VideoStart/VideoResize;
/// frames for an outdated size are refused).
/// The bytes are copied before returning. Thread-safe; never blocks on the network.
/// Must not be called from inside the event callback.
///
/// # Safety
/// `server` must be a live pointer from `ct_server_start`; `data` must point to `len`
/// readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_server_submit_h264(
    server: *const CtServer,
    data: *const u8,
    len: usize,
    keyframe: bool,
    width: u16,
    height: u16,
) -> CtSubmitResult {
    // SAFETY: caller guarantees `data` points to `len` readable bytes.
    let (Some(server), Some(data)) = (unsafe { server.as_ref() }, unsafe { bytes(data, len) })
    else {
        return CtSubmitResult::NotReady;
    };
    match server
        .handle
        .video()
        .submit_h264(data, keyframe, width, height)
    {
        SubmitResult::Sent => CtSubmitResult::Sent,
        SubmitResult::NotReady => CtSubmitResult::NotReady,
        SubmitResult::NeedKeyframe => CtSubmitResult::NeedKeyframe,
    }
}

/// Sets the client-side cursor shape: 32 bpp **BGRA, straight alpha, rows bottom-up**,
/// at most 96×96, hotspot inside. Returns false for invalid input. Sessions starting later
/// receive the latest shape.
///
/// # Safety
/// `server` must be a live pointer from `ct_server_start`; `bgra` must point to `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_server_set_pointer(
    server: *const CtServer,
    bgra: *const u8,
    len: usize,
    width: u16,
    height: u16,
    hot_x: u16,
    hot_y: u16,
) -> bool {
    // SAFETY: caller guarantees `bgra` points to `len` readable bytes.
    let (Some(server), Some(data)) = (unsafe { server.as_ref() }, unsafe { bytes(bgra, len) })
    else {
        return false;
    };
    server
        .handle
        .pointer()
        .set(data, width, height, hot_x, hot_y)
}

/// Ends the current client session (the server keeps listening). Returns false if no client
/// was in session.
///
/// # Safety
/// `server` must be null or a live pointer from `ct_server_start`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_server_disconnect_client(server: *const CtServer) -> bool {
    // SAFETY: null or live per the contract.
    unsafe { server.as_ref() }.is_some_and(|s| s.handle.disconnect_client())
}

/// Replaces the NLA username/password for future connections (no restart).
///
/// # Safety
/// `server` must be a live pointer from `ct_server_start`; strings must be valid C strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_server_set_credentials(
    server: *const CtServer,
    username: *const c_char,
    password: *const c_char,
) -> CtStatus {
    // SAFETY: caller guarantees validity (nulls are rejected).
    let (Some(server), Ok(user), Ok(pass)) = (
        unsafe { server.as_ref() },
        unsafe { req_str(username) },
        unsafe { req_str(password) },
    ) else {
        return CtStatus::InvalidArgument;
    };
    if user.is_empty() || pass.is_empty() {
        return CtStatus::InvalidArgument;
    }
    server
        .handle
        .set_credentials(user.to_owned(), pass.to_owned());
    CtStatus::Ok
}

/// Submits interleaved 16-bit little-endian PCM in the format from `AudioStart`. Returns
/// false if audio isn't active. Copies the bytes.
///
/// # Safety
/// `server` must be a live pointer from `ct_server_start`; `pcm` must point to `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_server_submit_audio(
    server: *const CtServer,
    pcm: *const u8,
    len: usize,
) -> bool {
    // SAFETY: caller guarantees `pcm` points to `len` readable bytes.
    let (Some(server), Some(pcm)) = (unsafe { server.as_ref() }, unsafe { bytes(pcm, len) }) else {
        return false;
    };
    server.handle.audio().submit_pcm(pcm)
}

/// Offers the host clipboard's formats to the client. `ids[i]` with optional `names[i]`
/// (null for standard formats). Returns false if the clipboard channel isn't ready.
///
/// # Safety
/// `server` must be live; `ids` and `names` must point to `count` elements; non-null names
/// must be valid C strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_clipboard_announce(
    server: *const CtServer,
    ids: *const u32,
    names: *const *const c_char,
    count: usize,
) -> bool {
    // SAFETY: null or live per the contract.
    let Some(server) = (unsafe { server.as_ref() }) else {
        return false;
    };
    if count > 0 && (ids.is_null() || names.is_null()) {
        return false;
    }
    let mut formats = Vec::with_capacity(count);
    for i in 0..count {
        // SAFETY: both arrays have `count` elements per the contract.
        let (id, name) = unsafe { (*ids.add(i), *names.add(i)) };
        // SAFETY: each name is null or a valid C string per the contract.
        let name = match unsafe { opt_str(name) } {
            Ok(n) => n.map(str::to_owned),
            Err(_) => return false,
        };
        formats.push(crate::clipboard::Format { id, name });
    }
    server.handle.clipboard().announce(&formats)
}

/// Answers the client's latest clipboard request with `len` bytes (or `ok = false` for
/// "can't provide").
///
/// # Safety
/// `server` must be live; `data` must point to `len` bytes when `ok` and `len > 0`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_clipboard_provide(
    server: *const CtServer,
    data: *const u8,
    len: usize,
    ok: bool,
) -> bool {
    // SAFETY: null or live per the contract.
    let Some(server) = (unsafe { server.as_ref() }) else {
        return false;
    };
    let payload = if ok {
        // SAFETY: caller guarantees `data` points to `len` readable bytes.
        Some(
            unsafe { bytes(data, len) }
                .map(<[u8]>::to_vec)
                .unwrap_or_default(),
        )
    } else {
        None
    };
    server.handle.clipboard().provide(payload)
}

/// Asks the client for its clipboard in `format`; `ClipboardData` follows.
///
/// # Safety
/// `server` must be null or a live pointer from `ct_server_start`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_clipboard_request(server: *const CtServer, format: u32) -> bool {
    // SAFETY: null or live per the contract.
    unsafe { server.as_ref() }.is_some_and(|s| s.handle.clipboard().request(format))
}

/// Takes the oldest clipboard data received from the client. Returns its format id (0 if
/// none) and fills `out` (free with `ct_buffer_free`); `ok` is false if the client reported an
/// error for that format.
///
/// # Safety
/// `server` must be live; `out` and `ok` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_clipboard_take_data(
    server: *const CtServer,
    out: *mut CtBuffer,
    ok: *mut bool,
) -> u32 {
    // SAFETY: null or live per the contract.
    let (Some(server), false, false) = (unsafe { server.as_ref() }, out.is_null(), ok.is_null())
    else {
        return 0;
    };
    let Some((format, data)) = server.handle.clipboard().take_data() else {
        return 0;
    };
    // SAFETY: checked non-null and writable per the contract. `write` doesn't read or drop the
    // previous contents, so the caller may pass uninitialized memory.
    unsafe {
        ok.write(data.is_some());
        out.write(CtBuffer::from_vec(data.unwrap_or_default()));
    }
    format
}

/// One file or folder offered to the client (`path` relative, `/`-separated).
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CtFileEntry {
    pub path: *const c_char,
    pub size: u64,
    pub is_dir: bool,
}

/// Offers files/folders (in this order; the index is used in requests) to the client.
///
/// # Safety
/// `server` must be live; `entries` must point to `count` entries with valid C strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_clipboard_announce_files(
    server: *const CtServer,
    entries: *const CtFileEntry,
    count: usize,
) -> bool {
    // SAFETY: null or live per the contract.
    let Some(server) = (unsafe { server.as_ref() }) else {
        return false;
    };
    if count > 0 && entries.is_null() {
        return false;
    }
    let mut files = Vec::with_capacity(count);
    for i in 0..count {
        // SAFETY: `entries` has `count` elements per the contract.
        let entry = unsafe { *entries.add(i) };
        // SAFETY: each path is a valid C string per the contract (null rejected).
        let Ok(path) = (unsafe { req_str(entry.path) }) else {
            return false;
        };
        files.push(FileEntry {
            path: path.to_owned(),
            size: entry.size,
            is_dir: entry.is_dir,
        });
    }
    server.handle.clipboard().announce_files(&files)
}

/// Answers a file-contents request: `kind` 0 = data (`data`/`len`), 1 = size (`size`), 2 = error.
///
/// # Safety
/// `server` must be live; for data, `data` must point to `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_clipboard_answer_file(
    server: *const CtServer,
    stream_id: u32,
    kind: u32,
    data: *const u8,
    len: usize,
    size: u64,
) -> bool {
    // SAFETY: null or live per the contract.
    let Some(server) = (unsafe { server.as_ref() }) else {
        return false;
    };
    let answer = match kind {
        // SAFETY: caller guarantees `data` points to `len` bytes for kind 0.
        0 => FileAnswer::Data(
            unsafe { bytes(data, len) }
                .map(<[u8]>::to_vec)
                .unwrap_or_default(),
        ),
        1 => FileAnswer::Size(size),
        _ => FileAnswer::Error,
    };
    server
        .handle
        .clipboard()
        .answer_file_contents(stream_id, answer)
}

/// Requests file `index` of the client's copied files: `size_query` asks for its size
/// (8-byte little-endian answer), otherwise `length` bytes from `position`. Returns the stream
/// id (0 on failure); the answer arrives as `ClipboardFileContents`.
///
/// # Safety
/// `server` must be null or a live pointer from `ct_server_start`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_clipboard_request_file(
    server: *const CtServer,
    index: u32,
    size_query: bool,
    position: u64,
    length: u32,
) -> u32 {
    // SAFETY: null or live per the contract.
    let Some(server) = (unsafe { server.as_ref() }) else {
        return 0;
    };
    let query = if size_query {
        FileQuery::Size
    } else {
        FileQuery::Range { position, length }
    };
    server
        .handle
        .clipboard()
        .request_file_contents(index, query)
        .unwrap_or(0)
}

/// Takes file contents received for `stream_id`. Returns false if nothing arrived yet; on
/// success fills `out` (free with `ct_buffer_free`) and `ok` (false if the client errored).
///
/// # Safety
/// `server` must be live; `out` and `ok` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_clipboard_take_file(
    server: *const CtServer,
    stream_id: u32,
    out: *mut CtBuffer,
    ok: *mut bool,
) -> bool {
    // SAFETY: null or live per the contract.
    let (Some(server), false, false) = (unsafe { server.as_ref() }, out.is_null(), ok.is_null())
    else {
        return false;
    };
    let Some(data) = server.handle.clipboard().take_file_contents(stream_id) else {
        return false;
    };
    // SAFETY: checked non-null and writable per the contract. `write` doesn't read or drop the
    // previous contents, so the caller may pass uninitialized memory.
    unsafe {
        ok.write(data.is_some());
        out.write(CtBuffer::from_vec(data.unwrap_or_default()));
    }
    true
}

/// Hides the client-side cursor.
///
/// # Safety
/// `server` must be null or a live pointer from `ct_server_start`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_server_hide_pointer(server: *const CtServer) {
    // SAFETY: null or live per the contract.
    if let Some(server) = unsafe { server.as_ref() } {
        server.handle.pointer().hide();
    }
}

/// True if a frame submitted now would be sent (session ready, no backpressure). Lets the
/// host skip encoding work it would only throw away.
///
/// # Safety
/// `server` must be null or a live pointer from `ct_server_start`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_server_video_can_accept(server: *const CtServer) -> bool {
    // SAFETY: null or live per the contract.
    unsafe { server.as_ref() }.is_some_and(|s| s.handle.video().can_accept())
}

/// Video counters for the current session (zeros for a null server).
///
/// # Safety
/// `server` must be null or a live pointer from `ct_server_start`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ct_server_video_stats(server: *const CtServer) -> CtVideoStats {
    // SAFETY: null or live per the contract.
    let Some(server) = (unsafe { server.as_ref() }) else {
        return CtVideoStats::default();
    };
    let s = server.handle.video().stats();
    CtVideoStats {
        frames_sent: s.frames_sent,
        bytes_sent: s.bytes_sent,
        frames_dropped: s.frames_dropped,
        frames_acked: s.frames_acked,
        frames_in_flight: s.frames_in_flight,
        ack_latency_us: s.ack_latency_us,
    }
}

fn event_to_c(event: &CoreEvent) -> (CtEventKind, String) {
    match event {
        CoreEvent::AudioStart { rate, channels } => {
            (CtEventKind::AudioStart, format!("{rate}x{channels}"))
        }
        CoreEvent::AudioStop => (CtEventKind::AudioStop, String::new()),
        CoreEvent::ClipboardReady => (CtEventKind::ClipboardReady, String::new()),
        CoreEvent::ClipboardRemoteFormats(formats) => (
            CtEventKind::ClipboardRemoteFormats,
            formats
                .iter()
                .map(|f| match &f.name {
                    Some(name) => format!("{}\t{}", f.id, name.replace(['\n', '\t'], " ")),
                    None => f.id.to_string(),
                })
                .collect::<Vec<_>>()
                .join("\n"),
        ),
        CoreEvent::ClipboardDataRequested { format } => {
            (CtEventKind::ClipboardDataRequested, format.to_string())
        }
        CoreEvent::ClipboardData { format } => (CtEventKind::ClipboardData, format.to_string()),
        CoreEvent::ClipboardRemoteFiles(files) => (
            CtEventKind::ClipboardRemoteFiles,
            files
                .iter()
                .map(|f| {
                    format!(
                        "{}\t{}\t{}",
                        f.size,
                        u8::from(f.is_dir),
                        f.path.replace(['\n', '\t'], " ")
                    )
                })
                .collect::<Vec<_>>()
                .join("\n"),
        ),
        CoreEvent::ClipboardFileRequested {
            stream_id,
            index,
            query,
        } => (
            CtEventKind::ClipboardFileRequested,
            match query {
                FileQuery::Size => format!("{stream_id}\t{index}\tsize"),
                FileQuery::Range { position, length } => {
                    format!("{stream_id}\t{index}\trange\t{position}\t{length}")
                }
            },
        ),
        CoreEvent::ClipboardFileContents { stream_id } => {
            (CtEventKind::ClipboardFileContents, stream_id.to_string())
        }
        CoreEvent::VideoStart { width, height } => {
            (CtEventKind::VideoStart, format!("{width}x{height}"))
        }
        CoreEvent::VideoStop => (CtEventKind::VideoStop, String::new()),
        CoreEvent::VideoResize {
            width,
            height,
            scale_percent,
        } => (
            CtEventKind::VideoResize,
            format!("{width}x{height}@{scale_percent}"),
        ),
        CoreEvent::Listening(a) => (CtEventKind::Listening, a.to_string()),
        CoreEvent::Rejected { peer, reason } => (
            CtEventKind::Rejected,
            format!("{peer}\n{}", reason.as_str()),
        ),
        CoreEvent::LockedOut { ip, minutes } => {
            (CtEventKind::LockedOut, format!("{ip}\n{minutes}"))
        }
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
            assert!(ct_server_start(null(), None, None, null_mut(), &mut status).is_null());
            assert!(!ct_server_set_pointer(null(), null(), 0, 1, 1, 0, 0));
            ct_server_hide_pointer(null());
            assert!(!ct_server_disconnect_client(null()));
            assert!(!ct_server_submit_audio(null(), null(), 0));
            assert!(!ct_clipboard_announce(null(), null(), null(), 0));
            assert!(!ct_clipboard_provide(null(), null(), 0, false));
            assert!(!ct_clipboard_request(null(), 13));
            assert_eq!(ct_clipboard_take_data(null(), null_mut(), null_mut()), 0);
            assert!(!ct_clipboard_announce_files(null(), std::ptr::null(), 0));
            assert!(!ct_clipboard_answer_file(null(), 1, 2, null(), 0, 0));
            assert_eq!(ct_clipboard_request_file(null(), 0, true, 0, 0), 0);
            assert!(!ct_clipboard_take_file(null(), 1, null_mut(), null_mut()));
            assert_eq!(
                ct_server_set_credentials(null(), null(), null()),
                CtStatus::InvalidArgument
            );
            assert_eq!(status, CtStatus::InvalidArgument);
            assert_eq!(
                ct_generate_tls_identity(null(), null_mut(), null_mut()),
                CtStatus::InvalidArgument
            );
            assert!(ct_tls_fingerprint_sha256(null(), 0).is_null());
            assert_eq!(ct_server_port(null()), 0);
            assert_eq!(
                ct_server_submit_h264(null(), null(), 0, true, 0, 0),
                CtSubmitResult::NotReady
            );
            assert!(!ct_server_video_can_accept(null()));
            assert_eq!(ct_server_video_stats(null()), CtVideoStats::default());
            ct_server_stop(null_mut());
            ct_string_free(null_mut());
            ct_buffer_free(CtBuffer::EMPTY);
        }
    }

    #[test]
    fn input_events_flatten() {
        let e = input_to_c(InputEvent::Wheel {
            vertical: -120,
            horizontal: 60,
        });
        assert_eq!((e.kind, e.x, e.y), (CtInputKind::Wheel, 60, -120));
        let e = input_to_c(InputEvent::Button {
            button: crate::input::MouseButton::X2,
            down: true,
        });
        assert_eq!((e.kind, e.button, e.down), (CtInputKind::Button, 4, true));
        let e = input_to_c(InputEvent::Key {
            code: 0x5b,
            extended: true,
            down: false,
        });
        assert_eq!(
            (e.kind, e.code, e.extended, e.down),
            (CtInputKind::Key, 0x5b, true, false)
        );
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
