// What the Agent API can do on this Mac, behind a protocol so the router is testable with a
// fake. The real host uses ScreenCaptureKit (screenshots), CGEvent (input, needs
// Accessibility), NSWorkspace (apps) and CGVirtualDisplay (headless desktops).

import AppKit
import ApplicationServices
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct DisplayInfo: Equatable, Sendable {
    let id: UInt32
    let widthPoints: Int
    let heightPoints: Int
    let scale: Double
    let isMain: Bool
    let isVirtual: Bool

    var json: [String: Any] {
        ["id": id, "width": widthPoints, "height": heightPoints, "scale": scale, "main": isMain, "virtual": isVirtual]
    }
}

struct Screenshot: Sendable {
    let data: Data
    let mimeType: String
    let display: UInt32
    let width: Int
    let height: Int
    /// Display points per image pixel (1 unless `max_width` shrank the image).
    let pointsPerPixel: Double
}

struct CursorPosition: Equatable, Sendable {
    let display: UInt32
    let x: Double
    let y: Double
}

struct HostState: Sendable {
    var cursor: CursorPosition?
    var appName: String?
    var bundleID: String?
    var pid: Int32?
    var windowTitle: String?
    var screenLocked: Bool

    var json: [String: Any] {
        var result: [String: Any] = ["screen_locked": screenLocked]
        if let cursor { result["cursor"] = ["display": cursor.display, "x": Int(cursor.x), "y": Int(cursor.y)] }
        var app: [String: Any] = [:]
        if let appName { app["name"] = appName }
        if let bundleID { app["bundle_id"] = bundleID }
        if let pid { app["pid"] = pid }
        if let windowTitle { app["window_title"] = windowTitle }
        if !app.isEmpty { result["frontmost_app"] = app }
        return result
    }
}

enum AgentHostError: Error, Equatable, CustomStringConvertible {
    case noSuchDisplay(UInt32)
    case notPermitted(String)
    case notFound(String)
    case failed(String)

    var description: String {
        switch self {
        case .noSuchDisplay(let id): "no display \(id); see /v1/displays"
        case .notPermitted(let what): what
        case .notFound(let what): what
        case .failed(let what): what
        }
    }
}

protocol AgentHost: Sendable {
    func displays() async -> [DisplayInfo]
    func screenshot(display: UInt32?, maxWidth: Int?, jpeg: Bool) async throws -> Screenshot
    func perform(_ action: AgentAction) async throws
    func state() async -> HostState
    /// Opens (or activates) an app by name or bundle id; returns its name.
    func openApp(_ nameOrBundleID: String) async throws -> String
    func createVirtualDisplay(width: Int, height: Int, hiDPI: Bool) async throws -> UInt32
    func removeVirtualDisplay(_ id: UInt32) async -> Bool
}

final class MacAgentHost: AgentHost, @unchecked Sendable {
    private let lock = NSLock()
    private var virtualDisplays: [UInt32: VirtualDisplay] = [:]
    static let maxVirtualDisplays = 2

    func displays() async -> [DisplayInfo] {
        let virtual = lock.withLock { Set(virtualDisplays.keys) }
        return CGVirtualDisplayProvider.onlineDisplays().map { id in
            let bounds = CGDisplayBounds(id)
            let pixels = CGDisplayCopyDisplayMode(id).map { Double($0.pixelWidth) } ?? bounds.width
            return DisplayInfo(id: id, widthPoints: Int(bounds.width), heightPoints: Int(bounds.height),
                               scale: bounds.width > 0 ? pixels / bounds.width : 1,
                               isMain: CGDisplayIsMain(id) != 0, isVirtual: virtual.contains(id))
        }
    }

    private func resolve(_ display: UInt32?) throws -> UInt32 {
        let id = display ?? CGMainDisplayID()
        guard CGVirtualDisplayProvider.onlineDisplays().contains(id) else { throw AgentHostError.noSuchDisplay(id) }
        return id
    }

    /// Display-local points → global CoreGraphics coordinates, clamped to the display.
    private func globalPoint(_ display: UInt32?, _ x: Double, _ y: Double) throws -> CGPoint {
        let bounds = CGDisplayBounds(try resolve(display))
        return CGPoint(x: bounds.minX + min(max(x, 0), bounds.width - 1),
                       y: bounds.minY + min(max(y, 0), bounds.height - 1))
    }

    // MARK: Screenshots

    func screenshot(display: UInt32?, maxWidth: Int?, jpeg: Bool) async throws -> Screenshot {
        guard CGPreflightScreenCaptureAccess() else {
            throw AgentHostError.notPermitted("Screen Recording permission isn't granted to ClawTank")
        }
        let id = try resolve(display)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scDisplay = content.displays.first(where: { $0.displayID == id }) else {
            throw AgentHostError.noSuchDisplay(id)
        }
        let points = CGDisplayBounds(id).size
        let width = min(Int(points.width), max(maxWidth ?? Int.max, 64))
        let height = Int((Double(width) * points.height / points.width).rounded())
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.showsCursor = true
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let output = NSMutableData()
        let type = jpeg ? UTType.jpeg : UTType.png
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw AgentHostError.failed("image encoder unavailable")
        }
        CGImageDestinationAddImage(destination, image, jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.8]
                                   as CFDictionary : nil)
        guard CGImageDestinationFinalize(destination) else { throw AgentHostError.failed("encoding failed") }
        return Screenshot(data: output as Data, mimeType: type.preferredMIMEType ?? "image/png", display: id,
                          width: image.width, height: image.height, pointsPerPixel: points.width / Double(image.width))
    }

    // MARK: Input

    func perform(_ action: AgentAction) async throws {
        guard AXIsProcessTrusted() else {
            throw AgentHostError.notPermitted("Accessibility permission isn't granted to ClawTank")
        }
        let source = CGEventSource(stateID: .hidSystemState)
        switch action {
        case .move(let display, let x, let y):
            mouse(source, .mouseMoved, try globalPoint(display, x, y))
        case .click(let display, let x, let y, let button, let count):
            try await click(source, at: try globalPoint(display, x, y), button: button, count: count)
        case .drag(let display, let fromX, let fromY, let toX, let toY):
            try await drag(source, from: try globalPoint(display, fromX, fromY), to: try globalPoint(display, toX, toY))
        case .scroll(let display, let x, let y, let dx, let dy):
            if let x, let y { mouse(source, .mouseMoved, try globalPoint(display, x, y)) }
            CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: Int32(-dy),
                    wheel2: Int32(-dx), wheel3: 0)?.post(tap: .cghidEventTap)
        case .key(let combo):
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: down)
                event?.flags = combo.flags
                event?.post(tap: .cghidEventTap)
            }
        case .type(let text):
            try await type(text, source: source)
        }
    }

    private func mouse(_ source: CGEventSource?, _ type: CGEventType, _ point: CGPoint,
                       _ button: CGMouseButton = .left, clicks: Int = 1) {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        event?.post(tap: .cghidEventTap)
    }

    private func click(_ source: CGEventSource?, at point: CGPoint, button: MouseButton, count: Int) async throws {
        let events: (down: CGEventType, release: CGEventType)
        let cgButton: CGMouseButton
        switch button {
        case .left: (events, cgButton) = ((.leftMouseDown, .leftMouseUp), .left)
        case .right: (events, cgButton) = ((.rightMouseDown, .rightMouseUp), .right)
        case .middle: (events, cgButton) = ((.otherMouseDown, .otherMouseUp), .center)
        }
        mouse(source, .mouseMoved, point)
        try await Task.sleep(for: .milliseconds(30))
        for click in 1...count {
            mouse(source, events.down, point, cgButton, clicks: click)
            mouse(source, events.release, point, cgButton, clicks: click)
        }
    }

    private func drag(_ source: CGEventSource?, from start: CGPoint, to end: CGPoint) async throws {
        mouse(source, .mouseMoved, start)
        mouse(source, .leftMouseDown, start)
        for step in 1...10 {
            let fraction = Double(step) / 10
            try await Task.sleep(for: .milliseconds(15))
            mouse(source, .leftMouseDragged,
                  CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction))
        }
        mouse(source, .leftMouseUp, end)
    }

    /// Types Unicode text (layout-independent); newlines become Return.
    private func type(_ text: String, source: CGEventSource?) async throws {
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if index > 0, let enter = KeyCombo("return") { try await perform(.key(enter)) }
            let units = Array(line.utf16)
            for start in stride(from: 0, to: units.count, by: 16) {
                let chunk = Array(units[start..<min(start + 16, units.count)])
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    event?.post(tap: .cghidEventTap)
                }
                try await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    // MARK: State

    func state() async -> HostState {
        var state = HostState(screenLocked: Self.isScreenLocked())
        if let location = CGEvent(source: nil)?.location {
            var id: CGDirectDisplayID = 0
            var count: UInt32 = 0
            if CGGetDisplaysWithPoint(location, 1, &id, &count) == .success, count > 0 {
                let bounds = CGDisplayBounds(id)
                state.cursor = CursorPosition(display: id, x: location.x - bounds.minX, y: location.y - bounds.minY)
            }
        }
        let app = await MainActor.run { NSWorkspace.shared.frontmostApplication }
        if let app {
            state.appName = app.localizedName
            state.bundleID = app.bundleIdentifier
            state.pid = app.processIdentifier
            state.windowTitle = Self.focusedWindowTitle(pid: app.processIdentifier)
        }
        return state
    }

    private static func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        // swiftlint:disable:next force_cast
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        return title as? String
    }

    static func isScreenLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // MARK: Apps

    func openApp(_ nameOrBundleID: String) async throws -> String {
        guard let url = Self.findApp(nameOrBundleID) else {
            throw AgentHostError.notFound("no app named \(nameOrBundleID)")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return app.localizedName ?? url.deletingPathExtension().lastPathComponent
    }

    /// Only installed .app bundles, found by bundle id or by name in the standard folders.
    static func findApp(_ query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.hasPrefix(".") else { return nil }
        if trimmed.contains("."), !trimmed.hasSuffix(".app"),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) {
            return url
        }
        let name = trimmed.hasSuffix(".app") ? trimmed : trimmed + ".app"
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                       "/System/Applications/Utilities", "/System/Library/CoreServices",
                       NSHomeDirectory() + "/Applications"]
        let files = FileManager.default
        for folder in folders {
            // Matched against the listing so the result has the real name ("textedit" → TextEdit.app).
            if let match = (try? files.contentsOfDirectory(atPath: folder))?
                .first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                return URL(fileURLWithPath: folder).appendingPathComponent(match)
            }
        }
        return nil
    }

    // MARK: Virtual displays

    func createVirtualDisplay(width: Int, height: Int, hiDPI: Bool) async throws -> UInt32 {
        guard (640...7680).contains(width), (480...4320).contains(height) else {
            throw AgentHostError.failed("size must be 640×480 to 7680×4320 pixels")
        }
        guard lock.withLock({ virtualDisplays.count }) < Self.maxVirtualDisplays else {
            throw AgentHostError.failed("at most \(Self.maxVirtualDisplays) agent virtual displays")
        }
        let display = try await Task { @MainActor in
            let provider = CGVirtualDisplayProvider()
            guard provider.isAvailable else { throw VirtualDisplayError.unavailable }
            return try await provider.create(widthPixels: width, heightPixels: height, hiDPI: hiDPI)
        }.value
        lock.withLock { virtualDisplays[display.displayID] = display }
        return display.displayID
    }

    func removeVirtualDisplay(_ id: UInt32) async -> Bool {
        guard let display = lock.withLock({ virtualDisplays.removeValue(forKey: id) }) else { return false }
        display.invalidate()
        return true
    }

    /// Agent API turned off: remove everything agents created.
    func removeAllVirtualDisplays() {
        let all = lock.withLock {
            defer { virtualDisplays.removeAll() }
            return Array(virtualDisplays.values)
        }
        all.forEach { $0.invalidate() }
    }
}
