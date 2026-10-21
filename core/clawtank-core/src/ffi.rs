//! C ABI exported to the Swift host.
//!
//! Rules for this module (keep the boundary small and auditable):
//! - Only `#[repr(C)]` types and raw pointers cross the boundary.
//! - Strings returned to Swift are `'static` and must never be freed by the caller.
//! - No function may panic across the boundary; release builds use `panic = "abort"`.
//! - Every exported item is prefixed `ct_` / `Ct`.

use std::ffi::c_char;
use std::sync::OnceLock;

/// Result code for FFI calls.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CtStatus {
    /// The call succeeded.
    Ok = 0,
    /// `ct_core_init` was already called; the call had no effect.
    AlreadyInitialized = 1,
}

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

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

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
}
