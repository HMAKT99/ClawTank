import CoreVideo
import VideoToolbox
import XCTest
@testable import ClawTank

/// Builds IOSurface-backed NV12 frames with a moving bar so successive frames differ.
enum SyntheticFrames {
    static func make(width: Int, height: Int, index: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            attributes as CFDictionary, &buffer)
        guard let buffer else { fatalError("CVPixelBufferCreate failed") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let barX = (index * 24) % width
        for row in 0..<height {
            let line = luma + row * lumaStride
            for col in 0..<width {
                let inBar = col >= barX && col < barX + 64
                line[col] = inBar ? 235 : UInt8(16 + (col + row) % 200)
            }
        }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<(height / 2) {
            memset(chroma + row * chromaStride, 128, width)
        }
        return buffer
    }
}

/// Collects encoder output thread-safely.
final class FrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [EncodedFrame] = []
    func append(_ frame: EncodedFrame) { lock.withLock { frames.append(frame) } }
    var all: [EncodedFrame] { lock.withLock { frames } }
}

/// NAL unit types in an Annex-B access unit (4-byte start codes, as the encoder emits).
func nalTypes(_ data: Data) -> [UInt8] {
    let bytes = [UInt8](data)
    var types: [UInt8] = []
    var index = 0
    while index + 4 < bytes.count {
        if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1 {
            types.append(bytes[index + 4] & 0x1f)
            index += 4
        } else {
            index += 1
        }
    }
    return types
}

final class H264EncoderTests: XCTestCase {
    private func makeEncoder(width: Int = 640, height: Int = 368, sink: FrameSink) throws -> H264Encoder {
        let settings = H264Encoder.Settings(width: width, height: height, averageBitRate: 4_000_000,
                                            requireHardware: false)
        return try H264Encoder(settings: settings) { sink.append($0) }
    }

    func testAlignment() {
        XCTAssertEqual(H264Encoder.Settings.aligned(1512), 1520)
        XCTAssertEqual(H264Encoder.Settings.aligned(982), 992)
        XCTAssertEqual(H264Encoder.Settings.aligned(1600), 1600)
    }

    func testOutputIsAnnexBWithParameterSetsOnKeyframes() throws {
        let sink = FrameSink()
        let encoder = try makeEncoder(sink: sink)
        for index in 0..<10 {
            encoder.encode(SyntheticFrames.make(width: 640, height: 368, index: index),
                           presentationTime: CMTime(value: CMTimeValue(index), timescale: 60),
                           forceKeyframe: index == 6)
        }
        encoder.flush()
        let frames = sink.all
        XCTAssertEqual(frames.count, 10)

        let first = try XCTUnwrap(frames.first)
        XCTAssertTrue(first.isKeyframe, "stream must start with an IDR")
        XCTAssertEqual(Array(first.data.prefix(4)), [0, 0, 0, 1], "Annex-B start code")
        let firstTypes = nalTypes(first.data)
        XCTAssertEqual(Array(firstTypes.prefix(2)), [7, 8], "SPS then PPS before the IDR")
        XCTAssertTrue(firstTypes.contains(5), "IDR slice present")

        XCTAssertFalse(frames[1].isKeyframe, "no unsolicited IDR right after the first")
        XCTAssertFalse(nalTypes(frames[1].data).contains(7), "P-frames carry no SPS")

        XCTAssertTrue(frames[6].isKeyframe, "forced keyframe honoured")
        XCTAssertEqual(Array(nalTypes(frames[6].data).prefix(2)), [7, 8])
        XCTAssertTrue(frames.allSatisfy { $0.encodeDuration >= 0 })
    }

    func testRejectsUnalignedSizeAtTheBoundary() {
        XCTAssertEqual(H264Encoder.Settings.aligned(1) % 16, 0)
        XCTAssertGreaterThanOrEqual(
            H264Encoder.Settings.defaultBitRate(width: 640, height: 368, frameRate: 60), 2_000_000)
    }

    func testVideoStatsFormatting() {
        let text = ServerController.formatVideoStats(fps: 60, bytesPerSecond: 1_500_000, encodeMs: 3.14, skipped: 0)
        XCTAssertEqual(text, "60 fps · 12.0 Mbit/s · enc 3.1 ms")
        XCTAssertTrue(ServerController.formatVideoStats(fps: 1, bytesPerSecond: 0, encodeMs: 0, skipped: 2)
                        .hasSuffix("2 skipped"))
    }
}

/// `make bench`: encode 2560×1600 frames with motion at 60 fps and report latency, bitrate
/// and fps for each encoder configuration. Skipped unless CLAWTANK_BENCH=1.
final class EncoderBenchmarkTests: XCTestCase {
    func testEncode2560x1600() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAWTANK_BENCH"] == "1", "set CLAWTANK_BENCH=1")
        let (width, height) = (2560, 1600)
        let frames = (0..<30).map { SyntheticFrames.make(width: width, height: height, index: $0 * 7) }
        var lines: [String] = []
        for lowLatency in [false, true] {
            let settings = H264Encoder.Settings(
                width: width, height: height,
                averageBitRate: H264Encoder.Settings.defaultBitRate(width: width, height: height, frameRate: 60),
                requireHardware: true, lowLatencyRateControl: lowLatency)
            lines.append(try Self.run(settings, frames: frames, count: 300))
        }
        let report = lines.joined(separator: "\n")
        print(report)
        try report.write(toFile: NSTemporaryDirectory() + "clawtank-bench.txt", atomically: true, encoding: .utf8)
    }

    private static func run(_ settings: H264Encoder.Settings, frames: [CVPixelBuffer], count: Int) throws -> String {
        let sink = FrameSink()
        let encoder = try H264Encoder(settings: settings) { sink.append($0) }
        let started = CFAbsoluteTimeGetCurrent()
        for index in 0..<count {
            encoder.encode(frames[index % frames.count],
                           presentationTime: CMTime(value: CMTimeValue(index), timescale: 60),
                           forceKeyframe: false)
            // Pace at 60 fps like real capture, so latency is per-frame, not queueing.
            let wait = started + Double(index + 1) / 60 - CFAbsoluteTimeGetCurrent()
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
        encoder.flush()
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let out = sink.all
        XCTAssertEqual(out.count, count)
        let latencies = out.map { $0.encodeDuration * 1000 }.sorted()
        let bytes = out.reduce(0) { $0 + $1.data.count }
        return String(
            format: "BENCH %dx%d lowLatency=%@ encoder=%@ frames=%d fps=%.1f p50=%.2fms p95=%.2fms %.1fMbit/s",
            settings.width, settings.height, settings.lowLatencyRateControl ? "yes" : "no",
            encoder.encoderID.replacingOccurrences(of: "com.apple.videotoolbox.videoencoder.", with: ""),
            out.count, Double(out.count) / elapsed, latencies[latencies.count / 2],
            latencies[Int(Double(latencies.count) * 0.95)], Double(bytes * 8) / elapsed / 1_000_000)
    }
}
