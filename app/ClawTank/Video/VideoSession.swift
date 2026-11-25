// One client's video stream: ScreenCapture → (optional StatsOverlay) → H264Encoder → core.
//
// Backpressure is applied *before* encoding: if the core says a frame would not be sent, the
// captured frame is skipped (nothing was encoded, so the reference chain is intact). If the
// core ever refuses an encoded frame, the next frame is forced to be an IDR.
//
// Clients without an H.264 decoder (the Windows App on Android/iOS negotiates EGFX with
// AVC disabled) get the raw path instead: ScreenCapture → BGRA → core, which sends only the
// changed tiles losslessly (ClearCodec). Raw frames go through a one-slot mailbox: only the
// newest unsent frame is kept and retried until the core takes it, so a frame dropped under
// backpressure can't leave the client showing stale content on a now-static screen.

import CoreMedia
import CoreVideo
import Foundation
import os

final class VideoSession: @unchecked Sendable {
    /// Monotonic counters; the controller turns deltas into per-second rates.
    struct Counters: Equatable {
        var capturedFrames = 0
        var skippedFrames = 0
        var encodedFrames = 0
        var keyframes = 0
        var sentBytes = 0
        var encodeSeconds = 0.0
    }

    let contentWidth: Int
    let contentHeight: Int
    private let server: RdpServer
    private let overlayEnabled: @Sendable () -> Bool
    private let lock = NSLock()
    private var counters = Counters()
    private var needKeyframe = true
    private var overlayText = ""
    private var encoder: H264Encoder?
    private var capture: ScreenCapture?
    private let overlay = StatsOverlay()
    private var adaptive: AdaptiveBitrate?
    private let log = Logger(subsystem: "dev.clawtank.ClawTank", category: "video")

    let target: DisplayTarget

    let frameRate: Int
    let bitRateFactor: Double
    /// Raw BGRA instead of H.264 (decided by the core from the client's capabilities).
    let isRaw: Bool

    // Raw path state: newest unsent frame (guarded by `lock`), its serial submit queue, the
    // retry timer and the core's byte counter at start (for the stats readout).
    private var pendingRaw: CVPixelBuffer?
    private let rawQueue = DispatchQueue(label: "dev.clawtank.rawvideo", qos: .userInteractive)
    private var rawTimer: DispatchSourceTimer?
    private var coreBytesAtStart: UInt64 = 0

    /// Raw frames cost CPU and bandwidth per changed pixel; there's no point going faster.
    static let rawMaxFrameRate = 30

    init(server: RdpServer, width: Int, height: Int, target: DisplayTarget, frameRate: Int = 60,
         bitRateFactor: Double = 1, overlayEnabled: @escaping @Sendable () -> Bool) {
        self.server = server
        self.target = target
        let raw = server.videoCodec == .raw
        self.isRaw = raw
        self.frameRate = raw ? min(frameRate, Self.rawMaxFrameRate) : frameRate
        self.bitRateFactor = bitRateFactor
        self.contentWidth = width
        self.contentHeight = height
        self.overlayEnabled = overlayEnabled
    }

    var codedWidth: Int { isRaw ? contentWidth : H264Encoder.Settings.aligned(contentWidth) }
    var codedHeight: Int { isRaw ? contentHeight : H264Encoder.Settings.aligned(contentHeight) }

    var isHardwareAccelerated: Bool { encoder?.isHardwareAccelerated ?? false }

    func snapshot() -> Counters {
        lock.withLock { counters }
    }

    /// Text drawn by the overlay (set by the controller once per second).
    func setOverlayText(_ text: String) {
        lock.withLock { overlayText = text }
    }

    /// Feeds one second of network measurements; returns the bit rate in use and whether the
    /// link looked congested.
    func adapt(_ sample: AdaptiveBitrate.Sample) -> (bitRate: Int, congested: Bool)? {
        let (changed, state) = lock.withLock { () -> (Int?, AdaptiveBitrate?) in
            let changed = adaptive?.update(sample)
            return (changed, adaptive)
        }
        if let changed { encoder?.setBitRate(changed) }
        return state.map { ($0.current, $0.congested) }
    }

    func start() async throws {
        if isRaw {
            try await startRaw()
            return
        }
        let baseRate = H264Encoder.Settings.defaultBitRate(width: codedWidth, height: codedHeight, frameRate: frameRate)
        let settings = H264Encoder.Settings(
            width: codedWidth, height: codedHeight, frameRate: frameRate,
            averageBitRate: max(1_000_000, Int(Double(baseRate) * bitRateFactor)),
            lowLatencyRateControl: true)  // ADR-016: tighter p95 encode latency
        lock.withLock { adaptive = AdaptiveBitrate(target: settings.averageBitRate) }
        let encoder = try H264Encoder(settings: settings) { [weak self] frame in
            self?.deliver(frame)
        }
        self.encoder = encoder
        log.info("Encoder \(settings.width)x\(settings.height) \(encoder.encoderID, privacy: .public)")

        let capture = ScreenCapture(
            onFrame: { [weak self] buffer, time in self?.handle(buffer, time) },
            onStop: { [weak self] _ in self?.log.notice("Capture ended") })
        try await capture.start(.init(
            contentWidth: contentWidth, contentHeight: contentHeight,
            codedWidth: codedWidth, codedHeight: codedHeight, frameRate: frameRate,
            displaySize: target.bounds.size), displayID: target.displayID)
        self.capture = capture
    }

    func stop() async {
        await capture?.stop()
        capture = nil
        encoder?.flush()
        encoder = nil
        rawTimer?.cancel()
        rawTimer = nil
        lock.withLock { pendingRaw = nil }
    }

    private func startRaw() async throws {
        coreBytesAtStart = server.videoStats.bytes_sent
        log.info("Raw video \(self.contentWidth)x\(self.contentHeight)@\(self.frameRate) (client has no H.264)")
        let timer = DispatchSource.makeTimerSource(queue: rawQueue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.drainRaw() }
        timer.resume()
        rawTimer = timer

        let capture = ScreenCapture(
            onFrame: { [weak self] buffer, _ in self?.handleRaw(buffer) },
            onStop: { [weak self] _ in self?.log.notice("Capture ended") })
        try await capture.start(.init(
            contentWidth: contentWidth, contentHeight: contentHeight,
            codedWidth: codedWidth, codedHeight: codedHeight, frameRate: frameRate,
            displaySize: target.bounds.size, pixelFormat: kCVPixelFormatType_32BGRA),
            displayID: target.displayID)
        self.capture = capture
    }

    private func handleRaw(_ buffer: CVPixelBuffer) {
        let text = lock.withLock { () -> String in
            counters.capturedFrames += 1
            return overlayText
        }
        var frame = buffer
        if overlayEnabled(), let drawn = overlay.render(text, onto: buffer) {
            frame = drawn
        }
        let replaced = lock.withLock { () -> Bool in
            defer { pendingRaw = frame }
            return pendingRaw != nil
        }
        if replaced { lock.withLock { counters.skippedFrames += 1 } }
        rawQueue.async { [weak self] in self?.drainRaw() }
    }

    /// Runs on `rawQueue`: offers the newest pending frame to the core, keeping it for the
    /// next try if the core can't take it yet (unless a newer frame arrived meanwhile).
    private func drainRaw() {
        guard let frame = lock.withLock({ () -> CVPixelBuffer? in
            defer { pendingRaw = nil }
            return pendingRaw
        }) else { return }
        guard server.canAcceptVideo else {
            lock.withLock { if pendingRaw == nil { pendingRaw = frame } }
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        let result = submitRaw(frame)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let coreBytes = server.videoStats.bytes_sent
        lock.withLock {
            switch result {
            case .sent:
                counters.encodedFrames += 1
                counters.encodeSeconds += elapsed
                counters.sentBytes = Int(coreBytes &- coreBytesAtStart)
            case .notReady, .needKeyframe:
                if pendingRaw == nil { pendingRaw = frame }
            }
        }
    }

    private func submitRaw(_ buffer: CVPixelBuffer) -> RdpServer.SubmitResult {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return .notReady }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return .notReady }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let rows = CVPixelBufferGetHeight(buffer)
        guard CVPixelBufferGetWidth(buffer) >= contentWidth, rows >= contentHeight else { return .notReady }
        return server.submitBGRA(UnsafeRawPointer(base), length: stride * rows,
                                 width: contentWidth, height: contentHeight, stride: stride)
    }

    private func handle(_ buffer: CVPixelBuffer, _ time: CMTime) {
        guard let encoder else { return }
        lock.withLock { counters.capturedFrames += 1 }
        guard server.canAcceptVideo else {
            lock.withLock { counters.skippedFrames += 1 }
            return
        }
        let (forceKeyframe, text) = lock.withLock { () -> (Bool, String) in
            let force = needKeyframe
            needKeyframe = false
            return (force, overlayText)
        }
        var frame = buffer
        if overlayEnabled(), let drawn = overlay.render(text, onto: buffer) {
            frame = drawn
        }
        encoder.encode(frame, presentationTime: time, forceKeyframe: forceKeyframe)
    }

    private func deliver(_ frame: EncodedFrame) {
        let result = server.submitH264(frame.data, keyframe: frame.isKeyframe,
                                       width: contentWidth, height: contentHeight)
        lock.withLock {
            counters.encodedFrames += 1
            counters.encodeSeconds += frame.encodeDuration
            switch result {
            case .sent:
                counters.sentBytes += frame.data.count
                if frame.isKeyframe { counters.keyframes += 1 }
            case .needKeyframe:
                needKeyframe = true
            case .notReady:
                break
            }
        }
    }
}
