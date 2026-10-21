// Phase 0 spike: create a 2560×1600-pixel HiDPI virtual display (1280×800 points @2x),
// capture it with ScreenCaptureKit, save a PNG, destroy the display, and report timings.
import Foundation
import CoreGraphics
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

func onlineDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n); return Array(ids.prefix(Int(n)))
}

func ms(_ start: Date) -> String { String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000) }

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "virtual-display.png"

guard NSClassFromString("CGVirtualDisplay") != nil else {
    print("FAIL: CGVirtualDisplay class not present on this macOS"); exit(1)
}

let t0 = Date()
let desc = CGVirtualDisplayDescriptor()
desc.queue = DispatchQueue(label: "clawtank.spike.vd")
desc.name = "ClawTank Spike"
desc.maxPixelsWide = 2560
desc.maxPixelsHigh = 1600
desc.sizeInMillimeters = CGSize(width: 302, height: 189) // ~215 ppi, similar to a 14" MacBook
desc.vendorID = 0x3456
desc.productID = 0x1234
desc.serialNum = 0x0001
desc.terminationHandler = { _, _ in print("virtual display terminated") }

// Autorelease pools matter here: an autoreleased reference would keep the display alive.
var display: CGVirtualDisplay?
let id: CGDirectDisplayID = autoreleasepool {
    display = CGVirtualDisplay(descriptor: desc)
    guard let d = display else { print("FAIL: CGVirtualDisplay init returned nil"); exit(1) }
    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = 1
    settings.modes = [CGVirtualDisplayMode(width: 1280, height: 800, refreshRate: 60)]
    guard d.apply(settings) else { print("FAIL: applySettings returned false"); exit(1) }
    return d.displayID
}
print("created displayID=\(id) in \(ms(t0)); online: \(onlineDisplays())")

// Wait for the window server to report the display.
var mode: CGDisplayMode?
for _ in 0..<50 {
    mode = CGDisplayCopyDisplayMode(id)
    if mode != nil { break }
    Thread.sleep(forTimeInterval: 0.05)
}
if let m = mode {
    print("CG mode: \(m.width)x\(m.height) points, \(m.pixelWidth)x\(m.pixelHeight) pixels, \(m.refreshRate) Hz (after \(ms(t0)))")
} else {
    print("WARN: CGDisplayCopyDisplayMode returned nil")
}

let sem = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0
Task {
    do {
        let tc = Date()
        var scDisplay: SCDisplay?
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            scDisplay = content.displays.first { $0.displayID == id }
            if scDisplay != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let scd = scDisplay else { print("FAIL: display not visible to ScreenCaptureKit"); exitCode = 1; sem.signal(); return }
        print("SCDisplay: \(scd.width)x\(scd.height) points, found after \(ms(tc))")

        let filter = SCContentFilter(display: scd, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = 2560
        cfg.height = 1600
        cfg.showsCursor = true
        let tcap = Date()
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        print("captured \(image.width)x\(image.height) in \(ms(tcap))")

        let url = URL(fileURLWithPath: outPath) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
            print("FAIL: cannot create PNG"); exitCode = 1; sem.signal(); return
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        print("wrote \(outPath)")
    } catch {
        print("FAIL: \(error.localizedDescription)  (Screen Recording permission granted?)")
        exitCode = 2
    }
    sem.signal()
}
// Spin the main run loop (not a blocking wait) so CoreGraphics can deliver display events.
while sem.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }

// Destroy: releasing the last reference removes the display. Verify it disappears.
let td = Date()
autoreleasepool { display = nil }
var gone = false
for _ in 0..<250 {
    if !onlineDisplays().contains(id) { gone = true; break }
    RunLoop.current.run(until: Date().addingTimeInterval(0.02)) // let CG process reconfiguration
}
print(gone ? "destroyed in \(ms(td)); online now: \(onlineDisplays())" : "WARN: display \(id) still online after 5 s: \(onlineDisplays())")
exit(exitCode)
