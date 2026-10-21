// Thin Swift wrapper over the Rust core's C ABI (core/include/clawtank_core.h).
// All calls into Rust go through this type so the FFI surface stays in one place.

import ClawTankCore

final class CoreBridge: Sendable {
    static let shared = CoreBridge()

    /// Rust core version, e.g. "0.1.0".
    let version: String

    private init() {
        _ = ct_core_init()
        version = String(cString: ct_version())
    }

    /// Calls `ct_core_init` again; exposed for tests of the idempotency contract.
    func reinitialize() -> CtStatus {
        ct_core_init()
    }
}
