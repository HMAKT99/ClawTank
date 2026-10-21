// Captures the Mac's system audio (not ClawTank's own) with ScreenCaptureKit while a client has
// audio on, converts it to 16-bit PCM and hands ~10 ms chunks to the core. A separate,
// audio-only stream keeps audio independent of video restarts (resizes).

import CoreMedia
import Foundation
import os
import ScreenCaptureKit

final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.clawtank.audio", qos: .userInteractive)
    private let onPCM: @Sendable (Data) -> Void
    private var stream: SCStream?
    private var channels = 2
    private let log = Logger(subsystem: "dev.clawtank.ClawTank", category: "audio")

    init(onPCM: @escaping @Sendable (Data) -> Void) {
        self.onPCM = onPCM
    }

    func start(sampleRate: Int, channels: Int) async throws {
        self.channels = channels
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw ScreenCapture.CaptureError.noDisplay }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = sampleRate
        config.channelCount = channels
        // Audio-only: keep the (unused) video side as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                              configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        log.info("Audio capture \(sampleRate) Hz × \(channels)")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let pcm = PCMConverter.int16Interleaved(sampleBuffer, channels: channels) else { return }
        onPCM(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("Audio capture stopped: \(error.localizedDescription, privacy: .public)")
    }
}
