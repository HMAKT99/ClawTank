// Chooses and manages the display a session shows.
//
// - automatic (default): a virtual display matched to the client when the Mac is headless (no
//   physical display online), otherwise the physical main display scaled to the client.
// - virtual: always a matched virtual display (on a Mac with a screen, it extends the desktop).
// - physical: always the physical main display.
//
// If the virtual display can't be created, it falls back to the physical display.

import CoreGraphics
import Foundation
import os

enum DisplayMode: String, CaseIterable, Identifiable, Sendable {
    case automatic, virtual, physical
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic (virtual when headless)"
        case .virtual: "Virtual display (matched to client)"
        case .physical: "Physical display (scaled)"
        }
    }
}

struct DisplayTarget: Equatable, Sendable {
    let displayID: CGDirectDisplayID
    /// Global bounds in points.
    let bounds: CGRect
    let isVirtual: Bool
}

@MainActor
final class DisplayService {
    private let provider: VirtualDisplayProvider
    private let physicalDisplays: () -> [CGDirectDisplayID]
    private let boundsOf: (CGDirectDisplayID) -> CGRect
    private(set) var virtualDisplay: VirtualDisplay?
    private let log = Logger(subsystem: "dev.clawtank.ClawTank", category: "display")

    init(provider: VirtualDisplayProvider,
         physicalDisplays: @escaping () -> [CGDirectDisplayID] = DisplayService.onlinePhysicalDisplays,
         boundsOf: @escaping (CGDirectDisplayID) -> CGRect = { CGDisplayBounds($0) }) {
        self.provider = provider
        self.physicalDisplays = physicalDisplays
        self.boundsOf = boundsOf
    }

    convenience init() {
        self.init(provider: CGVirtualDisplayProvider())
    }

    /// Retina when the client says it is scaled ≥150%, or (scale unknown) when the requested
    /// size is so large it can only be a Retina panel's native resolution.
    nonisolated static func wantsHiDPI(width: Int, height: Int, scalePercent: Int?) -> Bool {
        if let scalePercent { return scalePercent >= 150 }
        return width >= 2400 || height >= 1500
    }

    /// Returns the display to capture for a `width`×`height` session, creating or resizing the
    /// virtual display as needed.
    func prepare(width: Int, height: Int, scalePercent: Int?, mode: DisplayMode) async -> DisplayTarget? {
        let physical = physicalDisplays()
        let useVirtual = switch mode {
        case .virtual: true
        case .physical: false
        case .automatic: physical.isEmpty
        }
        if useVirtual, provider.isAvailable {
            let hiDPI = Self.wantsHiDPI(width: width, height: height, scalePercent: scalePercent)
            if let existing = virtualDisplay {
                if existing.resize(widthPixels: width, heightPixels: height, hiDPI: hiDPI) {
                    return target(for: existing)
                }
                release()
            }
            do {
                let display = try await provider.create(widthPixels: width, heightPixels: height, hiDPI: hiDPI)
                virtualDisplay = display
                return target(for: display)
            } catch {
                log.error("Virtual display failed (\(String(describing: error), privacy: .public)); using physical")
            }
        } else {
            release()
        }
        guard let main = physical.first(where: { $0 == CGMainDisplayID() }) ?? physical.first else {
            log.error("No display to capture")
            return nil
        }
        return DisplayTarget(displayID: main, bounds: boundsOf(main), isVirtual: false)
    }

    /// Removes the virtual display, if any (session ended).
    func release() {
        virtualDisplay?.invalidate()
        virtualDisplay = nil
    }

    private func target(for display: VirtualDisplay) -> DisplayTarget {
        DisplayTarget(displayID: display.displayID, bounds: boundsOf(display.displayID), isVirtual: true)
    }

    /// Online displays that aren't ClawTank virtual displays.
    nonisolated static func onlinePhysicalDisplays() -> [CGDirectDisplayID] {
        CGVirtualDisplayProvider.onlineDisplays().filter {
            !(CGDisplayVendorNumber($0) == CGVirtualDisplayHandle.vendorID
                && CGDisplayModelNumber($0) == CGVirtualDisplayHandle.productID)
        }
    }
}
