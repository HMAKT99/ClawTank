// Captures the main display with ScreenCaptureKit as IOSurface-backed NV12 pixel buffers,
// ready for VideoToolbox without any CPU copy. Frames are delivered only when the screen
// changed (`SCFrameStatus.complete`), so a static screen costs nothing downstream.

import CoreMedia
import CoreVideo
import Foundation
import os
import ScreenCaptureKit

final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Configuration: Equatable {
        /// Size of the desktop the client sees (content is scaled into this, aspect preserved).
        var contentWidth: Int
        var contentHeight: Int
        /// Size of the delivered buffers (16-aligned for H.264); content sits at the top-left.
        var codedWidth: Int
        var codedHeight: Int
        var frameRate: Int = 60
        var showsCursor = true
    }

    enum CaptureError: Error {
        case noDisplay
    }

    private let queue = DispatchQueue(label: "dev.clawtank.capture", qos: .userInteractive)
    private let onFrame: @Sendable (CVPixelBuffer, CMTime) -> Void
    private let onStop: @Sendable (Error?) -> Void
    private var stream: SCStream?
    private let log = Logger(subsystem: "dev.clawtank.ClawTank", category: "capture")

    init(onFrame: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void,
         onStop: @escaping @Sendable (Error?) -> Void) {
        self.onFrame = onFrame
        self.onStop = onStop
    }

    static func streamConfiguration(_ config: Configuration) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        cfg.width = config.codedWidth
        cfg.height = config.codedHeight
        cfg.destinationRect = CGRect(x: 0, y: 0, width: config.contentWidth, height: config.contentHeight)
        cfg.scalesToFit = true
        cfg.preservesAspectRatio = true
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.frameRate))
        cfg.queueDepth = 4
        cfg.showsCursor = config.showsCursor
        cfg.capturesAudio = false
        return cfg
    }

    func start(_ config: Configuration) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: Self.streamConfiguration(config), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        log.info("Capturing display \(display.displayID) → \(config.codedWidth)x\(config.codedHeight)")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        do {
            try await stream.stopCapture()
        } catch {
            log.notice("stopCapture: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isComplete(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        onFrame(pixelBuffer, sampleBuffer.presentationTimeStamp)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("Capture stopped: \(error.localizedDescription, privacy: .public)")
        onStop(error)
    }

    /// Only `.complete` frames carry new content; `.idle` means nothing changed.
    static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }
}
