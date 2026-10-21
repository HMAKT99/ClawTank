// Virtual displays via CoreGraphics' private CGVirtualDisplay API (ADR-004).
//
// Everything private lives here, behind `VirtualDisplayProvider`, so the rest of the app can
// fall back to the physical display when the API is missing or fails. A virtual display exists
// only while its object is alive and dies with the process, so a crash cannot leave one behind.

import CoreGraphics
import Foundation
import os

protocol VirtualDisplay: AnyObject {
    var displayID: CGDirectDisplayID { get }
    /// Reconfigures in place (live resize). Returns false if the system rejected the mode.
    func resize(widthPixels: Int, heightPixels: Int, hiDPI: Bool) -> Bool
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
        // The window server announces the display asynchronously.
        for _ in 0..<40 {
            if Self.onlineDisplays().contains(handle.displayID) { return handle }
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

final class CGVirtualDisplayHandle: VirtualDisplay {
    /// Identifies our displays (e.g. to exclude them when looking for physical ones).
    static let vendorID: UInt32 = 0x434C   // "CL"
    static let productID: UInt32 = 0x5441  // "TA"

    private var display: CGVirtualDisplay?
    let displayID: CGDirectDisplayID
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
        log.info("Virtual display \(id) \(widthPixels)x\(heightPixels) hiDPI=\(hiDPI)")
    }

    deinit { invalidate() }

    func resize(widthPixels: Int, heightPixels: Int, hiDPI: Bool) -> Bool {
        guard let display else { return false }
        let applied = autoreleasepool {
            display.apply(Self.settings(widthPixels: widthPixels, heightPixels: heightPixels, hiDPI: hiDPI))
        }
        log.info("Virtual display \(self.displayID) → \(widthPixels)x\(heightPixels) hiDPI=\(hiDPI) applied=\(applied)")
        return applied
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
