// Sends the Mac's current cursor shape to the client so the client draws the pointer locally
// (instant response, crisp at any scale, and no cursor baked into the video).
//
// Polls `NSCursor.currentSystem` (the cursor of whatever app is in front) and only sends when
// the rendered pixels change, so an unchanging cursor costs nothing on the wire.

import AppKit

@MainActor
final class CursorPublisher {
    struct Shape: Equatable {
        /// BGRA, straight alpha, rows bottom-up (RDP pointer order).
        let bgra: Data
        let width: Int
        let height: Int
        let hotX: Int
        let hotY: Int
    }

    /// Largest side every client accepts without the Large Pointer capability.
    nonisolated static let maxSide = 32

    private let send: (Shape) -> Void
    private let scale: () -> Double
    private var timer: Timer?
    private var lastSent: Shape?

    /// `scale`: session pixels per display point; `send` publishes a shape to the core.
    init(scale: @escaping () -> Double, send: @escaping (Shape) -> Void) {
        self.scale = scale
        self.send = send
    }

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastSent = nil
    }

    private func tick() {
        guard let cursor = NSCursor.currentSystem,
              let shape = Self.render(cursor.image, hotSpot: cursor.hotSpot, scale: scale()),
              shape != lastSent else { return }
        lastSent = shape
        send(shape)
    }

    /// Rasterizes a cursor image at `scale` pixels per point, capped at `maxSide`.
    nonisolated static func render(_ image: NSImage, hotSpot: NSPoint, scale: Double,
                                   maxSide: Int = maxSide) -> Shape? {
        let points = image.size
        guard points.width > 0, points.height > 0 else { return nil }
        var factor = max(scale, 0.25)
        let longest = max(points.width, points.height) * factor
        if longest > Double(maxSide) { factor *= Double(maxSide) / longest }
        let width = max(1, Int((points.width * factor).rounded()))
        let height = max(1, Int((points.height * factor).rounded()))

        let bytesPerRow = width * 4
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let base = context.data else { return nil }

        // Memory is top-down premultiplied BGRA; RDP wants bottom-up straight alpha.
        let source = base.assumingMemoryBound(to: UInt8.self)
        var out = Data(count: bytesPerRow * height)
        out.withUnsafeMutableBytes { raw in
            let dest = raw.bindMemory(to: UInt8.self).baseAddress!
            for row in 0..<height {
                let src = source + row * bytesPerRow
                let dst = dest + (height - 1 - row) * bytesPerRow
                for col in 0..<width {
                    let i = col * 4
                    let alpha = src[i + 3]
                    dst[i + 3] = alpha
                    for channel in 0..<3 {
                        dst[i + channel] = alpha == 0 ? 0 : UInt8(min(255, Int(src[i + channel]) * 255 / Int(alpha)))
                    }
                }
            }
        }
        let hotX = min(width - 1, max(0, Int((hotSpot.x * factor).rounded(.down))))
        let hotY = min(height - 1, max(0, Int((hotSpot.y * factor).rounded(.down))))
        return Shape(bgra: out, width: width, height: height, hotX: hotX, hotY: hotY)
    }
}
