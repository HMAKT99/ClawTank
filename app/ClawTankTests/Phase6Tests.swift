import AppKit
import CoreMedia
import XCTest
@testable import ClawTank

final class ClipboardFormatsTests: XCTestCase {
    func testUnicodeTextRoundTripUsesCRLFAndNul() throws {
        let data = ClipboardFormats.encodeUnicodeText("a\nb ✓")
        XCTAssertEqual(Array(data.suffix(2)), [0, 0], "NUL-terminated")
        XCTAssertEqual(data.count, ("a\r\nb ✓".utf16.count + 1) * 2, "LF became CRLF")
        XCTAssertEqual(ClipboardFormats.decodeUnicodeText(data), "a\nb ✓")
        XCTAssertEqual(ClipboardFormats.decodeUnicodeText(Data([0x68, 0, 0x69, 0])), "hi", "no terminator")
    }

    func testHTMLOffsetsPointAtTheFragment() throws {
        let fragment = "<b>bold ✓</b>"
        let data = ClipboardFormats.encodeHTML(fragment)
        let text = try XCTUnwrap(String(bytes: data.prefix { $0 != 0 }, encoding: .utf8))
        func offset(_ key: String) -> Int {
            let range = text.range(of: key + ":")!
            return Int(text[range.upperBound...].prefix { $0.isNumber })!
        }
        let bytes = Array(data)
        let between = bytes[offset("StartFragment")..<offset("EndFragment")]
        XCTAssertEqual(String(bytes: between, encoding: .utf8), fragment)
        XCTAssertEqual(String(bytes: bytes[offset("StartHTML")...].prefix(6), encoding: .utf8), "<html>")
        XCTAssertEqual(ClipboardFormats.decodeHTML(data), fragment)
    }

    private func makeImage() -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 12, bitsPerPixel: 32)!
        let colors: [NSColor] = [.red, .green, .blue, .white, .black, NSColor(red: 1, green: 1, blue: 0, alpha: 1)]
        for (index, color) in colors.enumerated() {
            rep.setColor(color.usingColorSpace(.deviceRGB)!, atX: index % 3, y: index / 3)
        }
        return rep
    }

    func testDIBRoundTrip() throws {
        let original = makeImage()
        let dib = try XCTUnwrap(ClipboardFormats.encodeDIB(original))
        XCTAssertEqual(dib.count, 40 + 3 * 2 * 4)
        let decoded = try XCTUnwrap(ClipboardFormats.decodeDIB(dib))
        XCTAssertEqual(decoded.pixelsWide, 3)
        XCTAssertEqual(decoded.pixelsHigh, 2)
        for y in 0..<2 {
            for x in 0..<3 {
                let want = original.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                let got = decoded.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                XCTAssertEqual(want.redComponent, got.redComponent, accuracy: 0.02, "(\(x),\(y)) red")
                XCTAssertEqual(want.blueComponent, got.blueComponent, accuracy: 0.02, "(\(x),\(y)) blue")
            }
        }
    }

    func testDecodes24BitAndZeroAlpha32BitDIBs() throws {
        // 2x1 24-bit bottom-up: blue, red (BGR), rows padded to 4 bytes.
        var dib24 = Data(count: 40)
        dib24.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(40).littleEndian, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: Int32(2).littleEndian, toByteOffset: 4, as: Int32.self)
            raw.storeBytes(of: Int32(1).littleEndian, toByteOffset: 8, as: Int32.self)
            raw.storeBytes(of: UInt16(1).littleEndian, toByteOffset: 12, as: UInt16.self)
            raw.storeBytes(of: UInt16(24).littleEndian, toByteOffset: 14, as: UInt16.self)
        }
        dib24.append(contentsOf: [255, 0, 0, 0, 0, 255, 0, 0])
        let rep = try XCTUnwrap(ClipboardFormats.decodeDIB(dib24))
        XCTAssertEqual(rep.bitmapData.map { Array(UnsafeBufferPointer(start: $0, count: 8)) },
                       [0, 0, 255, 255, 255, 0, 0, 255], "RGBA: blue then red, opaque")

        var dib32 = dib24.prefix(40)
        dib32.withUnsafeMutableBytes { $0.storeBytes(of: UInt16(32).littleEndian, toByteOffset: 14, as: UInt16.self) }
        dib32.append(contentsOf: [10, 20, 30, 0, 40, 50, 60, 0])
        let rep32 = try XCTUnwrap(ClipboardFormats.decodeDIB(Data(dib32)))
        XCTAssertEqual(rep32.bitmapData?[3], 255, "all-zero alpha treated as opaque")
    }
}

final class PCMConverterTests: XCTestCase {
    /// A 2-channel non-interleaved float32 sample buffer, like ScreenCaptureKit produces.
    private func makeFloatBuffer(left: [Float], right: [Float]) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let frames = left.count
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format!, sampleCount: frames, presentationTimeStamp: .zero, packetDescriptions: nil,
            sampleBufferOut: &buffer)
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        let leftData = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let rightData = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { leftData.deallocate(); rightData.deallocate() }
        leftData.initialize(from: left, count: frames)
        rightData.initialize(from: right, count: frames)
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: leftData)
        list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: rightData)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(
            buffer!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
            bufferList: list.unsafePointer), noErr)
        return buffer!
    }

    func testSilenceDetection() {
        XCTAssertTrue(PCMConverter.isSilent(Data(count: 1920)))
        XCTAssertFalse(PCMConverter.isSilent(Data([0, 0, 1, 0])))
    }

    func testNonInterleavedFloatBecomesInterleavedInt16() throws {
        let buffer = try makeFloatBuffer(left: [0, 0.5, -1, 2], right: [1, -0.5, 0, -2])
        let pcm = try XCTUnwrap(PCMConverter.int16Interleaved(buffer, channels: 2))
        let samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Int16(littleEndian: $0) }
        XCTAssertEqual(samples, [0, 32767, 16383, -16383, -32767, 0, 32767, -32767], "L,R interleaved, clamped")
    }
}

@MainActor
final class ClipboardServiceTests: XCTestCase {
    func testServesLocalFormatsFromThePasteboard() throws {
        let identity = try SecurityService(store: InMemoryStore()).loadOrCreateIdentity(commonName: "t.local")
        let server = try RdpServer(configuration: .init(bindIP: "127.0.0.1", port: 0, username: "u",
                                                        password: "p", identity: identity)) { _ in }
        defer { server.stop() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("clawtank-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("hi\nthere", forType: .string)
        pasteboard.setString("<i>x</i>", forType: .html)
        let service = ClipboardService(server: server, pasteboard: pasteboard)

        XCTAssertEqual(service.localData(for: ClipboardFormats.unicodeText),
                       ClipboardFormats.encodeUnicodeText("hi\nthere"))
        let html = try XCTUnwrap(service.localData(for: ClipboardFormats.htmlID))
        XCTAssertEqual(ClipboardFormats.decodeHTML(html), "<i>x</i>")
        XCTAssertNil(service.localData(for: ClipboardFormats.dib), "no image on the pasteboard")
        XCTAssertNil(service.localData(for: 0x1234), "unknown format")
    }
}
