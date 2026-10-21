// One client's video stream: ScreenCapture → (optional StatsOverlay) → H264Encoder → core.
//
// Backpressure is applied *before* encoding: if the core says a frame would not be sent, the
// captured frame is skipped (nothing was encoded, so the reference chain is intact). If the
// core ever refuses an encoded frame, the next frame is forced to be an IDR.

import CoreMedia
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
    private let log = Logger(subsystem: "dev.clawtank.ClawTank", category: "video")

    let target: DisplayTarget

    init(server: RdpServer, width: Int, height: Int, target: DisplayTarget,
         overlayEnabled: @escaping @Sendable () -> Bool) {
        self.server = server
        self.target = target
        self.contentWidth = width
        self.contentHeight = height
        self.overlayEnabled = overlayEnabled
    }

    var codedWidth: Int { H264Encoder.Settings.aligned(contentWidth) }
    var codedHeight: Int { H264Encoder.Settings.aligned(contentHeight) }

    var isHardwareAccelerated: Bool { encoder?.isHardwareAccelerated ?? false }

    func snapshot() -> Counters {
        lock.withLock { counters }
    }

    /// Text drawn by the overlay (set by the controller once per second).
    func setOverlayText(_ text: String) {
        lock.withLock { overlayText = text }
    }

    func start() async throws {
        let settings = H264Encoder.Settings(
            width: codedWidth, height: codedHeight,
            averageBitRate: H264Encoder.Settings.defaultBitRate(width: codedWidth, height: codedHeight, frameRate: 60),
            lowLatencyRateControl: true)  // ADR-016: tighter p95 encode latency
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
            codedWidth: codedWidth, codedHeight: codedHeight,
            displaySize: target.bounds.size), displayID: target.displayID)
        self.capture = capture
    }

    func stop() async {
        await capture?.stop()
        capture = nil
        encoder?.flush()
        encoder = nil
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
