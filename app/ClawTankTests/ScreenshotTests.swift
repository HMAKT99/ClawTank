// Renders real app views offscreen to PNGs for the README (docs/media). Opt-in, because it writes
// files: `TEST_RUNNER_CLAWTANK_SCREENSHOTS=/path/to/docs/media make test-app`.
// Uses sample values (no real host name, username or secrets) and in-memory stores.

import AppKit
import SwiftUI
import XCTest
@testable import ClawTank

@MainActor
final class ScreenshotTests: XCTestCase {
    private func outputDirectory() throws -> URL {
        let path = ProcessInfo.processInfo.environment["CLAWTANK_SCREENSHOTS"] ?? ""
        try XCTSkipIf(path.isEmpty, "set CLAWTANK_SCREENSHOTS=<dir>")
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Draws `view` in an offscreen window at 2x and writes it as a PNG.
    private func render<V: View>(_ view: V, size: CGSize, to url: URL, dark: Bool = false) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                                 pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    func testRenderReadmeScreenshots() throws {
        let dir = try outputDirectory()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "screenshots-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("screenshots-\(UUID().uuidString)")
        let server = ServerController(settings: settings, security: SecurityService(store: InMemoryStore()),
                                      audit: AuditLog(url: tmp.appendingPathComponent("audit.log")))
        let agents = AgentService(settings: settings, audit: server.audit, human: server.humanActivity,
                                  store: AgentTokenStore(url: tmp.appendingPathComponent("agents.json")))

        // Cut off above the General tab's "Connect" section, which shows the real host name.
        try render(SettingsView(server: server, settings: settings, agents: agents)
                    .background(Color(nsColor: .windowBackgroundColor)),
                   size: CGSize(width: 620, height: 436), to: dir.appendingPathComponent("settings.png"))
        try render(ConnectGuide(address: "studio.local", username: "alex", remoteAddress: "studio.tail1234.ts.net")
                    .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(nsColor: .windowBackgroundColor)),
                   size: CGSize(width: 620, height: 170), to: dir.appendingPathComponent("connect-guide.png"))
    }
}
