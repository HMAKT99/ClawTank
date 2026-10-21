//! ClawTank protocol core.
//!
//! Hosts the IronRDP server (TLS, NLA, graphics, virtual channels) and exposes it to the
//! Swift host app through a narrow C ABI (see [`ffi`]). The Swift side owns everything
//! macOS-specific (capture, encode, input injection, Keychain); this side owns the RDP
//! protocol.
//!
//! Phase 2: the server authenticates stock clients with NLA and streams H.264 supplied by the
//! host over the Graphics Pipeline (EGFX AVC420). Non-EGFX clients see a static test frame.

pub mod access;
pub mod display;
pub mod events;
pub mod ffi;
pub mod gfx;
pub mod input;
pub mod logging;
pub mod pointer;
pub mod server;
pub mod test_pattern;
pub mod tls;
pub mod video;

/// Error type for the Rust-side API. FFI functions map errors to [`ffi::CtStatus`].
pub type Error = Box<dyn std::error::Error + Send + Sync>;
pub type Result<T> = std::result::Result<T, Error>;

/// Crate version, as a NUL-terminated string so it can cross the FFI boundary without copying.
pub const VERSION_CSTR: &std::ffi::CStr = match std::ffi::CStr::from_bytes_with_nul(
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_bytes(),
) {
    Ok(s) => s,
    Err(_) => panic!("version string must not contain interior NUL"),
};
