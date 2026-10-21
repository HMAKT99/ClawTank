// Conversions between NSPasteboard contents and the Windows clipboard formats RDP uses.
// Pure functions, unit-tested:
// - CF_UNICODETEXT (13): UTF-16LE, CRLF line endings, NUL-terminated.
// - "Rich Text Format": raw RTF bytes.
// - "HTML Format" (CF_HTML): UTF-8 with a header of byte offsets to the fragment.
// - CF_DIB (8): BITMAPINFOHEADER + pixels (we write 32-bit BGRA bottom-up; we read 24/32-bit).
// - "PNG": PNG bytes (preferred for images when the client offers it).

import AppKit

enum ClipboardFormats {
    static let unicodeText: UInt32 = 13
    static let dib: UInt32 = 8
    static let rtfName = "Rich Text Format"
    static let htmlName = "HTML Format"
    static let pngName = "PNG"
    /// IDs we use when announcing registered formats (the client maps them by name).
    static let rtfID: UInt32 = 0xC0A0
    static let htmlID: UInt32 = 0xC0A1
    static let pngID: UInt32 = 0xC0A2

    // MARK: Text

    static func encodeUnicodeText(_ text: String) -> Data {
        let crlf = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        var data = Data()
        for unit in crlf.utf16 { withUnsafeBytes(of: unit.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: [0, 0])
        return data
    }

    static func decodeUnicodeText(_ data: Data) -> String? {
        var units: [UInt16] = []
        units.reserveCapacity(data.count / 2)
        var index = data.startIndex
        while index + 1 < data.endIndex {
            let unit = UInt16(data[index]) | UInt16(data[index + 1]) << 8
            if unit == 0 { break }
            units.append(unit)
            index += 2
        }
        return String(utf16CodeUnits: units, count: units.count).replacingOccurrences(of: "\r\n", with: "\n")
    }

    // MARK: HTML (CF_HTML)

    static func encodeHTML(_ html: String) -> Data {
        let start = "<html><body><!--StartFragment-->"
        let end = "<!--EndFragment--></body></html>"
        let template = "Version:0.9\r\nStartHTML:%010d\r\nEndHTML:%010d\r\nStartFragment:%010d\r\nEndFragment:%010d\r\n"
        let headerLength = String(format: template, 0, 0, 0, 0).utf8.count
        let body = Data((start + html + end).utf8)
        let startHTML = headerLength
        let startFragment = startHTML + start.utf8.count
        let endFragment = startFragment + html.utf8.count
        let endHTML = startHTML + body.count
        var data = Data(String(format: template, startHTML, endHTML, startFragment, endFragment).utf8)
        data.append(body)
        data.append(0)
        return data
    }

    /// Returns the fragment (or the whole HTML if offsets are missing).
    static func decodeHTML(_ data: Data) -> String? {
        let bytes = data.prefix { $0 != 0 }
        guard let text = String(data: bytes, encoding: .utf8) else { return nil }
        func offset(_ key: String) -> Int? {
            guard let range = text.range(of: key + ":") else { return nil }
            return Int(text[range.upperBound...].prefix { $0.isNumber })
        }
        if let start = offset("StartFragment"), let end = offset("EndFragment"), start <= end, end <= bytes.count {
            let fragment = bytes[bytes.startIndex + start..<bytes.startIndex + end]
            return String(data: Data(fragment), encoding: .utf8)
        }
        if let start = offset("StartHTML"), start < bytes.count {
            return String(data: Data(bytes[(bytes.startIndex + start)...]), encoding: .utf8)
        }
        return text
    }

    // MARK: Images (CF_DIB)

    static func encodeDIB(_ image: NSBitmapImageRep) -> Data? {
        let width = image.pixelsWide
        let height = image.pixelsHigh
        guard width > 0, height > 0 else { return nil }
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        put(UInt32(40)); put(Int32(width)); put(Int32(height))   // bottom-up
        put(UInt16(1)); put(UInt16(32)); put(UInt32(0))          // planes, bpp, BI_RGB
        put(UInt32(width * height * 4)); put(Int32(2835)); put(Int32(2835)); put(UInt32(0)); put(UInt32(0))
        for row in (0..<height).reversed() {
            for col in 0..<width {
                guard let color = image.colorAt(x: col, y: row)?.usingColorSpace(.sRGB) else {
                    data.append(contentsOf: [0, 0, 0, 0])
                    continue
                }
                let rgba = [color.blueComponent, color.greenComponent, color.redComponent, color.alphaComponent]
                data.append(contentsOf: rgba.map { UInt8(max(0, min(255, ($0 * 255).rounded()))) })
            }
        }
        return data
    }

    static func decodeDIB(_ data: Data) -> NSBitmapImageRep? {
        guard data.count >= 40 else { return nil }
        func read<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
            data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
        }
        let headerSize = Int(read(0, UInt32.self))
        let width = Int(read(4, Int32.self))
        let rawHeight = Int(read(8, Int32.self))
        let bpp = Int(read(14, UInt16.self))
        let compression = read(16, UInt32.self)
        let colorsUsed = Int(read(32, UInt32.self))
        guard width > 0, rawHeight != 0, bpp == 24 || bpp == 32, compression == 0 || compression == 3 else {
            return nil
        }
        let height = abs(rawHeight)
        let bottomUp = rawHeight > 0
        // BI_BITFIELDS with a 40-byte header has three DWORD masks after it.
        var pixelOffset = headerSize + colorsUsed * 4
        if compression == 3 && headerSize == 40 { pixelOffset += 12 }
        let stride = (width * bpp / 8 + 3) & ~3
        guard data.count >= pixelOffset + stride * height,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
              let out = rep.bitmapData else { return nil }
        // Many apps write 32-bit DIBs with alpha all zero; treat that as opaque.
        var anyAlpha = false
        if bpp == 32 {
            for row in 0..<height {
                let base = pixelOffset + row * stride
                for col in 0..<width where data[data.startIndex + base + col * 4 + 3] != 0 {
                    anyAlpha = true
                    break
                }
                if anyAlpha { break }
            }
        }
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: UInt8.self)
            for row in 0..<height {
                let srcRow = bottomUp ? height - 1 - row : row
                let base = pixelOffset + srcRow * stride
                for col in 0..<width {
                    let pixel = base + col * bpp / 8
                    let dst = out + row * width * 4 + col * 4
                    dst[0] = src[pixel + 2]
                    dst[1] = src[pixel + 1]
                    dst[2] = src[pixel]
                    dst[3] = bpp == 32 && anyAlpha ? src[pixel + 3] : 255
                }
            }
        }
        return rep
    }
}
