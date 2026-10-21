// Runs the InputInjector on its own serial queue: input arrives on the core's network thread
// and must never wait on anything; ordering is preserved by the serial queue.

import ApplicationServices
import Foundation

final class InputPipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.clawtank.input", qos: .userInteractive)
    private let injector: InputInjector
    private var trusted = false
    private var lastTrustCheck = 0.0

    init(swapControlCommand: Bool, poster: EventPoster = SystemEventPoster()) {
        let (_, bounds) = ScreenCapture.capturedDisplay()
        injector = InputInjector(
            mapper: CoordinateMapper(sessionWidth: bounds.width, sessionHeight: bounds.height, displayBounds: bounds),
            swapControlCommand: swapControlCommand, poster: poster)
    }

    func handle(_ input: ClientInput) {
        queue.async { [self] in
            // CGEvent posting silently does nothing without Accessibility; re-check now and then
            // so a grant made mid-session starts working without a reconnect.
            let now = ProcessInfo.processInfo.systemUptime
            if !trusted, now - lastTrustCheck > 2 {
                trusted = AXIsProcessTrusted()
                lastTrustCheck = now
            }
            if trusted { injector.handle(input) }
        }
    }

    /// Session size changed (video start): map client coordinates onto the captured display.
    func setSession(width: Int, height: Int) {
        queue.async { [self] in
            let (_, bounds) = ScreenCapture.capturedDisplay()
            injector.mapper = CoordinateMapper(sessionWidth: Double(width), sessionHeight: Double(height),
                                               displayBounds: bounds)
        }
    }

    func setSwapControlCommand(_ swap: Bool) {
        queue.async { [self] in injector.swapControlCommand = swap }
    }

    /// Lifts all held keys and buttons (session ended).
    func releaseAll() {
        queue.async { [self] in injector.releaseAll() }
    }

    /// Session pixels per display point, for cursor scaling.
    func currentScale() -> Double {
        queue.sync { injector.mapper.scale }
    }
}
