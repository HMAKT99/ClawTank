//! ClawTank protocol core.
//!
//! This crate will host the IronRDP server (TLS, NLA, EGFX, virtual channels) and expose it to
//! the Swift host app through a narrow C ABI (see [`ffi`]). The Swift side owns everything
//! macOS-specific (capture, encode, input injection); this side owns the RDP protocol.
//!
//! Phase 0 only proves the build and link path: the FFI exports a version string and an
//! idempotent init, and `ironrdp-server` is compiled in so the pinned versions are exercised.

pub mod ffi;

/// Crate version, as a NUL-terminated string so it can cross the FFI boundary without copying.
pub const VERSION_CSTR: &std::ffi::CStr = match std::ffi::CStr::from_bytes_with_nul(
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_bytes(),
) {
    Ok(s) => s,
    Err(_) => panic!("version string must not contain interior NUL"),
};

/// Compile-time proof that the pinned IronRDP server API is available.
const _: fn() = || {
    let _ = ironrdp_server::RdpServer::builder;
};
