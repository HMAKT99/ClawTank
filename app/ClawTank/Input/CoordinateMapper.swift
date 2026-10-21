// Session (client desktop) pixels ↔ global display points.
//
// ScreenCaptureKit scales the display into the session rectangle with its aspect ratio
// preserved and the content centred (see ScreenCapture), so a client coordinate maps back
// through the same scale and letterbox offset.

import CoreGraphics

struct CoordinateMapper: Equatable {
    /// Session size in pixels (what the client sees).
    let sessionWidth: Double
    let sessionHeight: Double
    /// The captured display in global points (CGDisplayBounds).
    let displayBounds: CGRect

    /// Session pixels per display point.
    var scale: Double {
        min(sessionWidth / displayBounds.width, sessionHeight / displayBounds.height)
    }

    private var offset: (x: Double, y: Double) {
        ((sessionWidth - displayBounds.width * scale) / 2, (sessionHeight - displayBounds.height * scale) / 2)
    }

    /// Client position → global point, clamped onto the display.
    func displayPoint(sessionX: Double, sessionY: Double) -> CGPoint {
        let (offsetX, offsetY) = offset
        let x = (sessionX - offsetX) / scale
        let y = (sessionY - offsetY) / scale
        return CGPoint(
            x: displayBounds.minX + min(max(x, 0), displayBounds.width - 1),
            y: displayBounds.minY + min(max(y, 0), displayBounds.height - 1))
    }

    /// Clamps any global point onto the display (for relative motion).
    func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, displayBounds.minX), displayBounds.maxX - 1),
                y: min(max(point.y, displayBounds.minY), displayBounds.maxY - 1))
    }
}
