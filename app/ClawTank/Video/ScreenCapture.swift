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
        /// Off when the client draws the cursor itself from shapes we send (Phase 3).
        var showsCursor = false
        /// Display size in points; content is fitted (aspect preserved, centred) into the session.
        var displaySize = CGSize(width: 1, height: 1)

        /// Where the display lands inside the session rectangle. Matches `CoordinateMapper`.
        var contentRect: CGRect {
            let scale = min(Double(contentWidth) / displaySize.width, Double(contentHeight) / displaySize.height)
            let size = CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
            return CGRect(x: (Double(contentWidth) - size.width) / 2, y: (Double(contentHeight) - size.height) / 2,
                          width: size.width, height: size.height)
        }
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
        // We compute the aspect-fit rect ourselves so input mapping matches it exactly.
        cfg.destinationRect = config.contentRect
        cfg.scalesToFit = true
        cfg.preservesAspectRatio = false
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.frameRate))
        cfg.queueDepth = 4
        cfg.showsCursor = config.showsCursor
        cfg.capturesAudio = false
        return cfg
    }

    /// Captures `displayID`. A just-created virtual display can take a moment to show up in
    /// ScreenCaptureKit, so look for it for up to two seconds.
    func start(_ config: Configuration, displayID: CGDirectDisplayID) async throws {
        var found: SCDisplay?
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            found = content.displays.first { $0.displayID == displayID }
            if found != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let display = found else { throw CaptureError.noDisplay }
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
