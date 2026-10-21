// Thin Swift wrapper over the Rust core's C ABI (core/include/clawtank_core.h).
// All calls into Rust go through this file so the FFI surface stays in one place.

import ClawTankCore
import Foundation
import os

private let coreLog = Logger(subsystem: "dev.clawtank.ClawTank", category: "core")

final class CoreBridge: Sendable {
    static let shared = CoreBridge()

    /// Rust core version, e.g. "0.1.0".
    let version: String

    private init() {
        _ = ct_core_init()
        version = String(cString: ct_version())
        // Route Rust `tracing` output into the unified log (Console.app, category "core").
        _ = ct_set_log_callback({ level, message in
            guard let message else { return }
            let text = String(cString: message)
            switch level {
            case CT_LOG_LEVEL_ERROR: coreLog.error("\(text, privacy: .public)")
            case CT_LOG_LEVEL_WARN: coreLog.warning("\(text, privacy: .public)")
            case CT_LOG_LEVEL_INFO: coreLog.info("\(text, privacy: .public)")
            default: coreLog.debug("\(text, privacy: .public)")
            }
        }, "info")
    }

    /// Calls `ct_core_init` again; exposed for tests of the idempotency contract.
    func reinitialize() -> CtStatus {
        ct_core_init()
    }

    /// Generates a self-signed RSA-2048 identity. Returns (certificate DER, PKCS#8 key DER).
    func generateTLSIdentity(commonName: String) -> (Data, Data)? {
        var cert = CtBuffer(data: nil, len: 0)
        var key = CtBuffer(data: nil, len: 0)
        let status = commonName.withCString { ct_generate_tls_identity($0, &cert, &key) }
        defer {
            ct_buffer_free(cert)
            ct_buffer_free(key)
        }
        guard status == CT_STATUS_OK, let certData = cert.data, let keyData = key.data else { return nil }
        return (Data(bytes: certData, count: cert.len), Data(bytes: keyData, count: key.len))
    }

    /// SHA-256 certificate fingerprint as `AB:CD:…`, or nil if the data is empty.
    func fingerprint(certificateDER: Data) -> String? {
        let raw = certificateDER.withUnsafeBytes { bytes -> UnsafeMutablePointer<CChar>? in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return ct_tls_fingerprint_sha256(base, bytes.count)
        }
        guard let raw else { return nil }
        defer { ct_string_free(raw) }
        return String(cString: raw)
    }
}

/// A running RDP server in the Rust core. Events arrive on a core thread; `onEvent` must be
/// thread-safe (the controller hops to the main actor). Stopped on `stop()` or deinit.
final class RdpServer: @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case listening(String)
        case rejected(String)
        case clientConnected(String)
        case clientDisconnected(peer: String, error: String?)
        case connectionFailed(peer: String, error: String)
        case videoStart(width: Int, height: Int)
        case videoStop
        case stopped
        case error(String)
    }

    enum SubmitResult: Equatable, Sendable {
        case sent
        case notReady
        case needKeyframe
    }

    struct Configuration {
        var bindIP = "0.0.0.0"
        var port: UInt16 = 3389
        var username: String
        var password: String
        var identity: TLSIdentity
        var lanOnly = true
    }

    enum StartError: Error, Equatable {
        case failed(status: UInt32)
    }

    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var sink: Unmanaged<RdpEventSink>?

    /// The bound port (useful when `port` was 0).
    let port: UInt16

    init(configuration config: Configuration, onEvent: @escaping @Sendable (Event) -> Void,
         onInput: @escaping @Sendable (ClientInput) -> Void = { _ in }) throws {
        let sink = Unmanaged.passRetained(RdpEventSink(onEvent, onInput))
        var status = CT_STATUS_OK
        let handle: OpaquePointer? = config.bindIP.withCString { bindIP in
            config.username.withCString { user in
                config.password.withCString { pass in
                    config.identity.certificateDER.withUnsafeBytes { cert in
                        config.identity.privateKeyDER.withUnsafeBytes { key in
                            var native = CtServerConfig(
                                bind_ip: bindIP, port: config.port, username: user, password: pass,
                                cert_der: cert.bindMemory(to: UInt8.self).baseAddress, cert_der_len: cert.count,
                                key_der: key.bindMemory(to: UInt8.self).baseAddress, key_der_len: key.count,
                                lan_only: config.lanOnly)
                            return ct_server_start(&native, rdpServerEventCallback, rdpServerInputCallback,
                                                   sink.toOpaque(), &status)
                        }
                    }
                }
            }
        }
        guard let handle else {
            sink.release()
            throw StartError.failed(status: status.rawValue)
        }
        self.handle = handle
        self.sink = sink
        self.port = ct_server_port(handle)
    }

    /// Disconnects any client and stops listening. Blocks until the core thread exits
    /// (normally well under a second). Safe to call more than once.
    func stop() {
        lock.lock()
        let handle = self.handle
        let sink = self.sink
        self.handle = nil
        self.sink = nil
        lock.unlock()
        if let handle {
            ct_server_stop(handle)
        }
        sink?.release()
    }

    deinit { stop() }

    /// Hands one Annex-B access unit to the core (copied before returning). Thread-safe.
    func submitH264(_ data: Data, keyframe: Bool) -> SubmitResult {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return .notReady }
        let result = data.withUnsafeBytes { bytes in
            ct_server_submit_h264(handle, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, keyframe)
        }
        switch result {
        case CT_SUBMIT_RESULT_SENT: return .sent
        case CT_SUBMIT_RESULT_NEED_KEYFRAME: return .needKeyframe
        default: return .notReady
        }
    }

    /// Publishes the cursor shape (BGRA, straight alpha, bottom-up rows).
    @discardableResult
    func setPointer(_ shape: CursorPublisher.Shape) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return false }
        return shape.bgra.withUnsafeBytes { bytes in
            ct_server_set_pointer(handle, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                                  UInt16(shape.width), UInt16(shape.height), UInt16(shape.hotX), UInt16(shape.hotY))
        }
    }

    /// False while there's no graphics session or the client is behind (skip encoding).
    var canAcceptVideo: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return false }
        return ct_server_video_can_accept(handle)
    }

    var videoStats: CtVideoStats {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return CtVideoStats() }
        return ct_server_video_stats(handle)
    }

    fileprivate static func decode(kind: CtEventKind, detail: String) -> Event {
        let parts = detail.split(separator: "\n", maxSplits: 1).map(String.init)
        let peer = parts.first ?? ""
        let error = parts.count > 1 ? parts[1] : nil
        switch kind {
        case CT_EVENT_KIND_LISTENING: return .listening(detail)
        case CT_EVENT_KIND_REJECTED: return .rejected(detail)
        case CT_EVENT_KIND_CLIENT_CONNECTED: return .clientConnected(detail)
        case CT_EVENT_KIND_CLIENT_DISCONNECTED: return .clientDisconnected(peer: peer, error: error)
        case CT_EVENT_KIND_CONNECTION_FAILED: return .connectionFailed(peer: peer, error: error ?? "unknown error")
        case CT_EVENT_KIND_VIDEO_START:
            let size = detail.split(separator: "x").compactMap { Int($0) }
            return size.count == 2 ? .videoStart(width: size[0], height: size[1]) : .error("bad video size \(detail)")
        case CT_EVENT_KIND_VIDEO_STOP: return .videoStop
        case CT_EVENT_KIND_STOPPED: return .stopped
        default: return .error(detail)
        }
    }
}

/// Holds an `RdpServer`'s handlers for the native server's lifetime (passed as `ctx`).
private final class RdpEventSink: @unchecked Sendable {
    let handler: @Sendable (RdpServer.Event) -> Void
    let input: @Sendable (ClientInput) -> Void
    init(_ handler: @escaping @Sendable (RdpServer.Event) -> Void,
         _ input: @escaping @Sendable (ClientInput) -> Void) {
        self.handler = handler
        self.input = input
    }
}

/// C input trampoline: converts `CtInputEvent` and forwards it. Runs on a core thread.
private func rdpServerInputCallback(ctx: UnsafeMutableRawPointer?, event: UnsafePointer<CtInputEvent>?) {
    guard let ctx, let event = event?.pointee else { return }
    let sink = Unmanaged<RdpEventSink>.fromOpaque(ctx).takeUnretainedValue()
    let input: ClientInput? = switch event.kind {
    case CT_INPUT_KIND_KEY: .key(scancode: UInt8(truncatingIfNeeded: event.code), extended: event.extended,
                                 down: event.down)
    case CT_INPUT_KIND_UNICODE: .unicode(event.code, down: event.down)
    case CT_INPUT_KIND_SYNC: .sync(capsLock: event.flags & 0x4 != 0)
    case CT_INPUT_KIND_MOVE: .move(x: Int(event.x), y: Int(event.y))
    case CT_INPUT_KIND_REL_MOVE: .relativeMove(dx: Int(event.x), dy: Int(event.y))
    case CT_INPUT_KIND_BUTTON: .button(Int(event.button), down: event.down)
    case CT_INPUT_KIND_WHEEL: .wheel(vertical: Int(event.y), horizontal: Int(event.x))
    default: nil
    }
    if let input { sink.input(input) }
}

/// C callback trampoline: decodes the event and forwards it to the `RdpEventSink` in `ctx`.
private func rdpServerEventCallback(ctx: UnsafeMutableRawPointer?, kind: CtEventKind,
                                    detail: UnsafePointer<CChar>?) {
    guard let ctx else { return }
    let sink = Unmanaged<RdpEventSink>.fromOpaque(ctx).takeUnretainedValue()
    let text = detail.map { String(cString: $0) } ?? ""
    sink.handler(RdpServer.decode(kind: kind, detail: text))
}
