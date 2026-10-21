// Hardware H.264 encoder (VideoToolbox) tuned for remote-desktop latency: real-time, low-latency
// rate control, no frame reordering (no B-frames), long GOP with on-demand IDR. Output is the
// Annex-B byte stream MS-RDPEGFX requires (RFX_AVC420_BITMAP_STREAM), with SPS/PPS prepended to
// every keyframe so a client can join or recover at any IDR.

import CoreMedia
import Foundation
import os
import VideoToolbox

struct EncodedFrame: Sendable {
    /// Annex-B access unit.
    let data: Data
    let isKeyframe: Bool
    /// Wall time from `encode` to the output callback.
    let encodeDuration: TimeInterval
}

enum EncoderError: Error, Equatable {
    case sessionCreation(OSStatus)
    case property(String, OSStatus)
}

final class H264Encoder: @unchecked Sendable {
    struct Settings: Equatable {
        /// Coded size. MS-RDPEGFX requires multiples of 16.
        var width: Int
        var height: Int
        var frameRate: Int = 60
        var averageBitRate: Int
        /// Seconds between unsolicited IDRs (recovery for clients that missed one).
        var keyframeIntervalSeconds: Double = 10
        /// Production requires the hardware encoder; tests on VMs may allow software.
        var requireHardware = true
        /// Apple's low-latency rate control (selects the real-time "rtvc" encoder).
        var lowLatencyRateControl = false

        static func aligned(_ value: Int) -> Int { (value + 15) / 16 * 16 }

        /// Bit rate scaled from a 2560×1600 @ 60 fps baseline.
        static func defaultBitRate(width: Int, height: Int, frameRate: Int) -> Int {
            let pixelsPerSecond = Double(width * height * frameRate)
            let baseline = Double(2560 * 1600 * 60)
            return max(2_000_000, Int(20_000_000 * pixelsPerSecond / baseline))
        }
    }

    let settings: Settings
    private let session: VTCompressionSession
    private let output: @Sendable (EncodedFrame) -> Void
    private let log = Logger(subsystem: "dev.clawtank.ClawTank", category: "encode")

    init(settings: Settings, output: @escaping @Sendable (EncodedFrame) -> Void) throws {
        precondition(settings.width % 16 == 0 && settings.height % 16 == 0, "coded size must be 16-aligned")
        self.settings = settings
        self.output = output

        var spec: [CFString: Any] = [:]
        if settings.lowLatencyRateControl {
            spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true
        }
        if settings.requireHardware {
            spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = true
        }
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(settings.width), height: Int32(settings.height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
            refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let created else { throw EncoderError.sessionCreation(status) }
        session = created

        let keyframeFrames = Int(Double(settings.frameRate) * settings.keyframeIntervalSeconds)
        let properties: [(CFString, Any)] = [
            (kVTCompressionPropertyKey_RealTime, true),
            (kVTCompressionPropertyKey_AllowFrameReordering, false),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel),
            (kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC),
            (kVTCompressionPropertyKey_ExpectedFrameRate, settings.frameRate),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, keyframeFrames),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, settings.keyframeIntervalSeconds),
            (kVTCompressionPropertyKey_AverageBitRate, settings.averageBitRate),
            // Cap bursts at 1.5× the average over one second (bytes per second, seconds).
            (kVTCompressionPropertyKey_DataRateLimits, [settings.averageBitRate * 3 / 16, 1] as CFArray),
            (kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, true),
            (kVTCompressionPropertyKey_MaximizePowerEfficiency, false)
        ]
        for (key, value) in properties {
            let status = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            // Some encoders reject optional tuning keys; only core ones are fatal.
            if status != noErr {
                let fatal = [kVTCompressionPropertyKey_RealTime, kVTCompressionPropertyKey_AllowFrameReordering,
                             kVTCompressionPropertyKey_ProfileLevel, kVTCompressionPropertyKey_AverageBitRate]
                if fatal.contains(where: { $0 == key }) {
                    VTCompressionSessionInvalidate(session)
                    throw EncoderError.property(key as String, status)
                }
                log.notice("Encoder ignored \(key as String, privacy: .public): \(status)")
            }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// VideoToolbox's identifier for the chosen encoder, e.g. "com.apple.videotoolbox.videoencoder.ave.avc".
    var encoderID: String {
        copyProperty(kVTCompressionPropertyKey_EncoderID) as? String ?? "unknown"
    }

    /// True if VideoToolbox reports a hardware encoder, or hardware was required and the
    /// session was created (the low-latency "rtvc" encoder doesn't answer the query).
    var isHardwareAccelerated: Bool {
        if let value = copyProperty(kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder) as? Bool {
            return value
        }
        return settings.requireHardware
    }

    private func copyProperty(_ key: CFString) -> CFTypeRef? {
        let value = UnsafeMutablePointer<CFTypeRef?>.allocate(capacity: 1)
        value.initialize(to: nil)
        defer {
            value.deinitialize(count: 1)
            value.deallocate()
        }
        let status = VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: value)
        return status == noErr ? value.pointee : nil
    }

    /// Encodes one frame asynchronously; `output` is called on a VideoToolbox thread.
    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, forceKeyframe: Bool) {
        let started = CFAbsoluteTimeGetCurrent()
        let options: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTime,
            duration: .invalid, frameProperties: options, infoFlagsOut: nil
        ) { [output, log] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else {
                log.error("Encode failed: \(status)")
                return
            }
            guard let frame = Self.annexB(from: sampleBuffer) else { return }
            output(EncodedFrame(data: frame.data, isKeyframe: frame.isKeyframe,
                                encodeDuration: CFAbsoluteTimeGetCurrent() - started))
        }
        if status != noErr {
            log.error("VTCompressionSessionEncodeFrame failed: \(status)")
        }
    }

    /// Blocks until all submitted frames have been emitted.
    func flush() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    // MARK: - AVCC → Annex-B

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[CFString: Any]], let first = attachments.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    /// Converts a VideoToolbox sample (AVCC, length-prefixed NAL units) to Annex-B, prepending
    /// SPS/PPS from the format description on keyframes.
    static func annexB(from sampleBuffer: CMSampleBuffer) -> (data: Data, isKeyframe: Bool)? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let keyframe = isKeyframe(sampleBuffer)
        var out = Data()

        let nalHeaderLength = appendParameterSets(of: format, to: &out, include: keyframe)

        // VideoToolbox output is normally one contiguous block; copy (compressed bytes, small)
        // only if it isn't.
        var contiguous = block
        if !CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: 0) {
            var copy: CMBlockBuffer?
            guard CMBlockBufferCreateContiguous(
                allocator: nil, sourceBuffer: block, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: 0, flags: 0, blockBufferOut: &copy) == kCMBlockBufferNoErr,
                let copy else { return nil }
            contiguous = copy
        }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(
            contiguous, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer) == kCMBlockBufferNoErr, let dataPointer else { return nil }
        let headerLength = nalHeaderLength
        dataPointer.withMemoryRebound(to: UInt8.self, capacity: totalLength) { bytes in
            var offset = 0
            while offset + headerLength <= totalLength {
                var nalLength = 0
                for index in 0..<headerLength {
                    nalLength = (nalLength << 8) | Int(bytes[offset + index])
                }
                offset += headerLength
                guard nalLength > 0, offset + nalLength <= totalLength else { break }
                out.append(contentsOf: startCode)
                out.append(bytes + offset, count: nalLength)
                offset += nalLength
            }
        }
        return (out, keyframe)
    }

    /// Appends SPS/PPS (with start codes) when `include` is set; returns the AVCC NAL length size.
    private static func appendParameterSets(of format: CMFormatDescription, to out: inout Data,
                                            include: Bool) -> Int {
        var count = 0
        var headerLength: Int32 = 4
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
        guard include else { return Int(headerLength) }
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if status == noErr, let pointer {
                out.append(contentsOf: startCode)
                out.append(pointer, count: size)
            }
        }
        return Int(headerLength)
    }
}
