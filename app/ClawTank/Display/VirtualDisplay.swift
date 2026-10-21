// Virtual displays via CoreGraphics' private CGVirtualDisplay API (ADR-004).
//
// Everything private lives here, behind `VirtualDisplayProvider`, so the rest of the app can
// fall back to the physical display when the API is missing or fails. A virtual display exists
// only while its object is alive and dies with the process, so a crash cannot leave one behind.

import CoreGraphics
import Foundation
import os

protocol VirtualDisplay: AnyObject, Sendable {
    var displayID: CGDirectDisplayID { get }
    /// Reconfigures in place (live resize). Returns false if that isn't possible (e.g. Retina →
    /// 1x, which the window server applies wrongly) or didn't take effect; then recreate.
    func resize(widthPixels: Int, heightPixels: Int, hiDPI: Bool) async -> Bool
    /// Removes the display. Idempotent.
    func invalidate()
}

/// Used only from the main actor (DisplayService).
@MainActor
protocol VirtualDisplayProvider {
    var isAvailable: Bool { get }
    /// Creates a display whose framebuffer is `widthPixels`×`heightPixels`. With `hiDPI` the
    /// desktop is half that in points (Retina), so text is rendered at 2×.
    func create(widthPixels: Int, heightPixels: Int, hiDPI: Bool) async throws -> VirtualDisplay
}

enum VirtualDisplayError: Error, Equatable {
    case unavailable
    case applyFailed
    case didNotAppear
}

struct CGVirtualDisplayProvider: VirtualDisplayProvider {
    nonisolated init() {}

    var isAvailable: Bool { NSClassFromString("CGVirtualDisplay") != nil }

    func create(widthPixels: Int, heightPixels: Int, hiDPI: Bool) async throws -> VirtualDisplay {
        guard isAvailable else { throw VirtualDisplayError.unavailable }
        let handle = try CGVirtualDisplayHandle(widthPixels: widthPixels, heightPixels: heightPixels, hiDPI: hiDPI)
        // The window server brings the display up asynchronously: wait until it is online *and*
        // has the requested size, so capture never starts against a half-configured display.
        for _ in 0..<60 {
            if Self.onlineDisplays().contains(handle.displayID), handle.hasSize(widthPixels, heightPixels) {
                return handle
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        handle.invalidate()
        throw VirtualDisplayError.didNotAppear
    }

    nonisolated static func onlineDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(32, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }
}

/// Only created and used from the main actor (DisplayService); `@unchecked` because the
/// private ObjC object isn't annotated.
final class CGVirtualDisplayHandle: VirtualDisplay, @unchecked Sendable {
    /// Identifies our displays (e.g. to exclude them when looking for physical ones).
    static let vendorID: UInt32 = 0x434C   // "CL"
    static let productID: UInt32 = 0x5441  // "TA"

    private var display: CGVirtualDisplay?
    let displayID: CGDirectDisplayID
    private var hiDPI: Bool
    private let log = Logger(subsystem: "dev.clawtank.ClawTank", category: "display")

    /// Largest framebuffer we allow (Display Control caps the client at 3840×2400).
    static let maxPixels = (width: 3840, height: 2400)

    init(widthPixels: Int, heightPixels: Int, hiDPI: Bool) throws {
        let created: (CGVirtualDisplay, CGDirectDisplayID)? = autoreleasepool {
            let descriptor = CGVirtualDisplayDescriptor()
            descriptor.queue = DispatchQueue(label: "dev.clawtank.virtual-display")
            descriptor.name = "ClawTank"
            descriptor.maxPixelsWide = UInt32(max(Self.maxPixels.width, widthPixels))
            descriptor.maxPixelsHigh = UInt32(max(Self.maxPixels.height, heightPixels))
            descriptor.sizeInMillimeters = Self.physicalSize(widthPixels: widthPixels, heightPixels: heightPixels,
                                                             hiDPI: hiDPI)
            descriptor.vendorID = Self.vendorID
            descriptor.productID = Self.productID
            descriptor.serialNum = 1
            guard let display = CGVirtualDisplay(descriptor: descriptor),
                  display.apply(Self.settings(widthPixels: widthPixels, heightPixels: heightPixels, hiDPI: hiDPI))
            else { return nil }
            return (display, display.displayID)
        }
        guard let (display, id) = created else { throw VirtualDisplayError.applyFailed }
        self.display = display
        self.displayID = id
        self.hiDPI = hiDPI
        log.info("Virtual display \(id) \(widthPixels)x\(heightPixels) hiDPI=\(hiDPI)")
    }

    deinit { invalidate() }

    func resize(widthPixels: Int, heightPixels: Int, hiDPI: Bool) async -> Bool {
        // Measured on macOS 15.6: Retina→Retina, 1x→1x and 1x→Retina apply in place, but
        // Retina→1x keeps Retina semantics (2560×1600@2x → "1920×1200" became 960×600).
        guard let display, !(self.hiDPI && !hiDPI) else { return false }
        let applied = autoreleasepool {
            display.apply(Self.settings(widthPixels: widthPixels, heightPixels: heightPixels, hiDPI: hiDPI))
        }
        guard applied else { return false }
        self.hiDPI = hiDPI
        for _ in 0..<20 {
            if hasSize(widthPixels, heightPixels) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let done = hasSize(widthPixels, heightPixels)
        log.info("Virtual display \(self.displayID) → \(widthPixels)x\(heightPixels) hiDPI=\(hiDPI) done=\(done)")
        return done
    }

    /// Whether the display currently has this framebuffer size. Uses the bounds (points):
    /// CGDisplayCopyDisplayMode is unreliable for virtual displays (often returns nil).
    func hasSize(_ widthPixels: Int, _ heightPixels: Int) -> Bool {
        let divisor = hiDPI ? 2 : 1
        let size = CGDisplayBounds(displayID).size
        return Int(size.width) == widthPixels / divisor && Int(size.height) == heightPixels / divisor
    }

    func invalidate() {
        // Releasing the last reference removes the display; the pool drains autoreleased refs.
        autoreleasepool { display = nil }
    }

    /// One mode: with HiDPI the mode is in points (half the pixels), as the window server expects.
    static func settings(widthPixels: Int, heightPixels: Int, hiDPI: Bool) -> CGVirtualDisplaySettings {
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        let divisor = hiDPI ? 2 : 1
        settings.modes = [CGVirtualDisplayMode(width: UInt32(widthPixels / divisor),
                                               height: UInt32(heightPixels / divisor), refreshRate: 60)]
        return settings
    }

    /// A plausible panel size (≈220 ppi Retina, ≈110 ppi otherwise) so macOS picks sane defaults.
    static func physicalSize(widthPixels: Int, heightPixels: Int, hiDPI: Bool) -> CGSize {
        let ppi = hiDPI ? 220.0 : 110.0
        return CGSize(width: Double(widthPixels) / ppi * 25.4, height: Double(heightPixels) / ppi * 25.4)
    }
}
