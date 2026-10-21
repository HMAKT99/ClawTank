// Optional on-video stats readout (fps, bitrate, encode time), drawn with Core Image into a
// pooled copy of the frame on the GPU. Only used while the overlay is switched on, so the
// normal path stays zero-copy.

import CoreImage
import CoreVideo
import Foundation

final class StatsOverlay: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var cachedText = ""
    private var cachedImage: CIImage?

    /// Returns a new buffer with `text` drawn top-left, or nil if a buffer couldn't be made.
    func render(_ text: String, onto source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard let output = makeBuffer(width: width, height: height, format: CVPixelBufferGetPixelFormatType(source))
        else { return nil }

        if text != cachedText || cachedImage == nil {
            let filter = CIFilter(name: "CITextImageGenerator")
            filter?.setValue(text, forKey: "inputText")
            filter?.setValue("Menlo-Bold", forKey: "inputFontName")
            filter?.setValue(28, forKey: "inputFontSize")
            filter?.setValue(8, forKey: "inputPadding")
            cachedImage = filter?.outputImage
            cachedText = text
        }
        let frame = CIImage(cvPixelBuffer: source)
        guard let label = cachedImage else { return nil }
        // Core Image's origin is bottom-left: lift the label to the top edge.
        let backdrop = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.6))
            .cropped(to: label.extent)
        let badge = label.composited(over: backdrop)
            .transformed(by: CGAffineTransform(translationX: 16, y: CGFloat(height) - label.extent.height - 16))
        context.render(badge.composited(over: frame), to: output)
        return output
    }

    private func makeBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
            pool = created
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }
}
